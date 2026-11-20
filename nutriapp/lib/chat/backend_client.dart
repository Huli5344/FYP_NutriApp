/// NutriBot through the Flask backend, which holds the key.
///
/// The other implementation of [AiClient], [GeminiClient], calls Gemini
/// directly with a key compiled in by `--dart-define`. That key can be pulled
/// back out of the APK by anyone who has it, and an app built without the
/// flag had no assistant at all. This one sends the conversation to
/// `/api/chat` and lets the server add the key.
///
/// What the server adds, and this therefore does not send:
///
///   * the API key;
///   * the system prompt, safety instructions included. The app cannot
///     replace the rules the model is given, because it never sends them;
///   * the limits on how much one request may carry.
///
/// The wire format is server-sent events, the same shape the direct client
/// reads, but carrying this server's own small protocol rather than Gemini's:
/// `{"text": "..."}` for a piece of the reply, `{"error": "..."}` for a
/// failure that happened after the reply had already started, and a final
/// `[DONE]`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../session.dart';
import 'ai_client.dart';
import 'chat_message.dart';

class BackendClient implements AiClient {
  BackendClient({
    String? baseUrl,
    http.Client Function()? clientFactory,
    Session? Function()? sessionLookup,
  })  : baseUrl = baseUrl ?? ApiConfig.baseUrl,
        _clientFactory = clientFactory ?? http.Client.new,
        _session = sessionLookup ?? _currentSession;

  final String baseUrl;
  final http.Client Function() _clientFactory;
  final Session? Function() _session;

  static Session? _currentSession() => SessionStore.instance.current;

  @override
  Stream<String> streamReply({
    required List<ChatMessage> history,
    required String systemPrompt,
  }) async* {
    // systemPrompt is deliberately ignored. The server has its own copy and
    // uses that one; sending this would be sending something the server is
    // right to distrust.
    final session = _session();
    if (session == null) {
      throw AiException('Sign in to ask NutriBot a question.');
    }

    final request = http.Request('POST', Uri.parse('$baseUrl/api/chat'))
      ..headers.addAll(session.authHeader)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'messages': [
          for (final m in history)
            {
              'role': m.role == ChatRole.user ? 'user' : 'model',
              'text': m.text,
            },
        ],
      });

    // One client per request; closing it in `finally` aborts the connection
    // when the user taps Stop, which stops the server streaming too.
    final client = _clientFactory();
    try {
      final http.StreamedResponse response;
      try {
        // Long, because the free host sleeps after fifteen idle minutes and
        // takes about a minute to wake. At a few seconds the first question
        // of the evening would always fail, and the message would blame the
        // assistant for what is really a cold start.
        response = await client.send(request).timeout(
              const Duration(seconds: 90),
            );
      } on TimeoutException {
        throw AiException('The request timed out. Please try again.');
      } on Exception {
        throw AiException('Network error. Check your connection.');
      }

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw AiException(_errorFrom(response.statusCode, body));
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;

        final Object? decoded;
        try {
          decoded = jsonDecode(payload);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;

        final error = decoded['error'];
        if (error is String && error.isNotEmpty) throw AiException(error);

        final text = decoded['text'];
        if (text is String && text.isNotEmpty) yield text;
      }
    } finally {
      client.close();
    }
  }

  /// The server writes messages meant to be read, so use them when they are
  /// there. The status-based fallbacks are for the cases where something
  /// between here and the server answered instead -- a proxy, a cold start,
  /// a 502 from the host itself.
  String _errorFrom(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['error'];
        if (message is String && message.isNotEmpty) return message;
      }
    } on FormatException {
      // Not JSON: the host answered, not the app. Fall through.
    }
    switch (status) {
      case 401:
        return 'Your session has expired. Sign in again.';
      case 429:
        return 'You have asked a lot of questions today. Try again tomorrow.';
      case 503:
        return 'The assistant is not set up on the server yet.';
      default:
        return 'The assistant could not answer just now (error $status).';
    }
  }
}
