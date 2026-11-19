import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_message.dart';
import 'ai_client.dart';

/// Streams replies from the Gemini API over server-sent events.
/// The key is sent in the x-goog-api-key header, never in the URL, so it does
/// not end up in logs or proxies.
class GeminiClient implements AiClient {
  GeminiClient({
    required this.apiKey,
    required this.model,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final String apiKey;
  final String model;
  final http.Client Function() _clientFactory;

  @override
  Stream<String> streamReply({
    required List<ChatMessage> history,
    required String systemPrompt,
  }) async* {
    if (apiKey.isEmpty) {
      throw AiException(
        'No API key found. Run the app with --dart-define-from-file=env.json.',
      );
    }

    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:streamGenerateContent',
      {'alt': 'sse'},
    );

    final request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['x-goog-api-key'] = apiKey
      ..body = jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'contents': [
          for (final m in history)
            {
              'role': m.role == ChatRole.user ? 'user' : 'model',
              'parts': [
                {'text': m.text},
              ],
            },
        ],
        'generationConfig': {'temperature': 0.6, 'maxOutputTokens': 1024},
      });

    // One client per request; closing it in `finally` aborts the connection
    // if the user taps Stop.
    final client = _clientFactory();
    try {
      final http.StreamedResponse response;
      try {
        response = await client.send(request).timeout(
              const Duration(seconds: 30),
            );
      } on TimeoutException {
        throw AiException('The request timed out. Please try again.');
      } on Exception {
        throw AiException('Network error. Check your connection.');
      }

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw AiException(_friendlyError(response.statusCode, body));
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;

        final Object? decoded;
        try {
          decoded = jsonDecode(payload);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;

        final blocked = (decoded['promptFeedback'] as Map?)?['blockReason'];
        if (blocked != null) {
          throw AiException('That message was blocked by the safety filter.');
        }

        final candidates = decoded['candidates'];
        if (candidates is! List || candidates.isEmpty) continue;
        final candidate = candidates.first as Map<String, dynamic>;

        final parts = (candidate['content'] as Map?)?['parts'];
        if (parts is List) {
          for (final part in parts) {
            final text = (part as Map)['text'];
            if (text is String && text.isNotEmpty) yield text;
          }
        }

        if (candidate['finishReason'] == 'SAFETY') {
          throw AiException('The reply was stopped by the safety filter.');
        }
      }
    } finally {
      client.close();
    }
  }

  String _friendlyError(int status, String body) {
    switch (status) {
      case 400:
        return 'The request was rejected. Check the model name and API key.';
      case 401:
      case 403:
        return 'The API key was rejected. Check it in env.json.';
      case 404:
        return 'Model "$model" was not found. Check GEMINI_MODEL.';
      case 429:
        return 'Rate limit reached (free tier). Wait a minute and try again.';
      case 500:
      case 503:
        return 'The AI service is busy. Please try again shortly.';
      default:
        return 'Something went wrong (error $status).';
    }
  }
}
