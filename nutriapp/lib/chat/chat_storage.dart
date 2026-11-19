import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'chat_message.dart';

abstract class ChatStorage {
  Future<List<ChatMessage>> load();
  Future<void> save(List<ChatMessage> messages);
  Future<void> clear();
}

class SharedPrefsChatStorage implements ChatStorage {
  static const _key = 'chat_history_v1';
  static const _maxStored = 200;

  @override
  Future<List<ChatMessage>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          ChatMessage.fromJson(item as Map<String, dynamic>),
      ];
    } catch (_) {
      return []; // corrupted data: start fresh rather than crash
    }
  }

  @override
  Future<void> save(List<ChatMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = messages.length > _maxStored
        ? messages.sublist(messages.length - _maxStored)
        : messages;
    await prefs.setString(
      _key,
      jsonEncode([for (final m in recent) m.toJson()]),
    );
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
