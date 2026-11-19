import 'dart:async';

import 'package:flutter/foundation.dart';

import 'system_prompt.dart';
import 'chat_message.dart';
import 'ai_client.dart';
import 'chat_storage.dart';

class ChatController extends ChangeNotifier {
  ChatController({required AiClient client, required ChatStorage storage})
      : _client = client,
        _storage = storage;

  /// Only the most recent messages are sent, to limit token use on the free tier.
  static const int maxHistoryMessages = 20;

  final AiClient _client;
  final ChatStorage _storage;

  final List<ChatMessage> _messages = [];
  bool _isStreaming = false;
  StreamSubscription<String>? _sub;
  Completer<void>? _done;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isStreaming => _isStreaming;

  /// True once the stored conversation has been read.
  ///
  /// The controller used to be built per screen and loaded once. It now
  /// belongs to the Shell and outlives the sheet, which can be opened and
  /// closed repeatedly -- so without this, every reopen cleared the message
  /// list and refilled it from storage.
  ///
  /// That is worse than wasteful. `send` holds the index of the reply it is
  /// streaming into, and clearing the list underneath it means the arriving
  /// chunks land on the wrong message or on no message at all. Closing the
  /// sheet while NutriBot was still answering and opening it again was
  /// enough to do it.
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded || _isStreaming) return;
    final stored = await _storage.load();
    // Checked again: `await` above means a reply may have started in the
    // meantime, and the stored history is older than it.
    if (_isStreaming) return;
    _messages
      ..clear()
      ..addAll(stored);
    _loaded = true;
    notifyListeners();
  }

  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _isStreaming) return;

    final userMessage = ChatMessage.user(text);
    final history = _buildHistory([..._messages, userMessage]);

    _messages
      ..add(userMessage)
      ..add(ChatMessage.model(''));
    final replyIndex = _messages.length - 1;
    _isStreaming = true;
    notifyListeners();

    final done = Completer<void>();
    _done = done;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _sub = _client
        .streamReply(history: history, systemPrompt: nutritionSystemPrompt)
        .listen(
      (chunk) {
        final current = _messages[replyIndex];
        _messages[replyIndex] = current.copyWith(text: current.text + chunk);
        notifyListeners();
      },
      onError: (Object error) {
        final partial = _messages[replyIndex].text;
        final message = error is AiException
            ? error.message
            : 'Something went wrong. Please try again.';
        _messages[replyIndex] = _messages[replyIndex].copyWith(
          text: partial.isEmpty ? message : '$partial\n\n_($message)_',
          isError: true,
        );
        finish();
      },
      onDone: finish,
      cancelOnError: true,
    );

    await done.future;
    _sub = null;
    _done = null;

    if (_messages[replyIndex].text.isEmpty) {
      _messages[replyIndex] = _messages[replyIndex].copyWith(
        text: 'I could not generate a reply. Please try again.',
        isError: true,
      );
    }
    _isStreaming = false;
    notifyListeners();
    await _storage.save(_messages);
  }

  /// Stops the reply currently streaming, keeping what has arrived so far.
  void stop() {
    _sub?.cancel();
    _sub = null;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> clear() async {
    stop();
    _messages.clear();
    // Still loaded: the conversation is empty because it was emptied, not
    // because it has not been read yet. Without this the next reopen would
    // read storage again and, if the clear had not finished writing, bring
    // the conversation back.
    _loaded = true;
    notifyListeners();
    await _storage.clear();
  }

  /// Last N messages, excluding errors/empty placeholders, and starting with
  /// a user turn (the API requires that).
  List<ChatMessage> _buildHistory(List<ChatMessage> all) {
    final usable =
        all.where((m) => !m.isError && m.text.trim().isNotEmpty).toList();
    final recent = usable.length > maxHistoryMessages
        ? usable.sublist(usable.length - maxHistoryMessages)
        : usable;
    final firstUser = recent.indexWhere((m) => m.role == ChatRole.user);
    return firstUser <= 0 ? recent : recent.sublist(firstUser);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
