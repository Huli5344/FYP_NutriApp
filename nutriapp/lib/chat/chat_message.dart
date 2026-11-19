enum ChatRole { user, model }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.isError = false,
  });

  factory ChatMessage.user(String text) => ChatMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        role: ChatRole.user,
        text: text,
        createdAt: DateTime.now(),
      );

  factory ChatMessage.model(String text) => ChatMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        role: ChatRole.model,
        text: text,
        createdAt: DateTime.now(),
      );

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        role: json['role'] == 'user' ? ChatRole.user : ChatRole.model,
        text: json['text'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        isError: (json['isError'] as bool?) ?? false,
      );

  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;
  final bool isError;

  ChatMessage copyWith({String? text, bool? isError}) => ChatMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        createdAt: createdAt,
        isError: isError ?? this.isError,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role == ChatRole.user ? 'user' : 'model',
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'isError': isError,
      };
}
