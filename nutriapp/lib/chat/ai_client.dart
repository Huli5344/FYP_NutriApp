import 'chat_message.dart';

/// Thrown with a message that is safe to show to the user.
class AiException implements Exception {
  AiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Abstraction over the AI backend. Today: GeminiClient (direct, dev only).
/// Later: a ProxyClient that talks to your own server which holds the key.
abstract class AiClient {
  Stream<String> streamReply({
    required List<ChatMessage> history,
    required String systemPrompt,
  });
}
