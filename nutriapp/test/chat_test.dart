/// NutriBot's tests, as written by the chatbot's author.
///
/// Carried over with the import paths and one widget name changed. They are
/// worth keeping as they are: they exercise the controller against a fake
/// client, so they cover streaming, error handling and what gets sent as
/// history without touching the network or a real API key.
///
/// Run with: flutter test
library;

import 'package:nutriapp_diary/chat/chat_controller.dart';
import 'package:nutriapp_diary/chat/chat_sheet.dart';
import 'package:nutriapp_diary/chat/chat_message.dart';
import 'package:nutriapp_diary/chat/ai_client.dart';
import 'package:nutriapp_diary/chat/chat_storage.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClient implements AiClient {
  FakeClient(this.chunks, {this.error});
  final List<String> chunks;
  final AiException? error;
  List<ChatMessage>? lastHistory;

  @override
  Stream<String> streamReply({
    required List<ChatMessage> history,
    required String systemPrompt,
  }) async* {
    lastHistory = history;
    for (final c in chunks) {
      yield c;
    }
    if (error != null) throw error!;
  }
}

class MemoryStorage implements ChatStorage {
  List<ChatMessage> saved = [];
  @override
  Future<List<ChatMessage>> load() async => saved;
  @override
  Future<void> save(List<ChatMessage> messages) async => saved = [...messages];
  @override
  Future<void> clear() async => saved = [];
}


/// Streams its first chunk, then waits for `gate` before the rest. Lets a
/// test hold a reply open while something else happens.
class GatedClient implements AiClient {
  GatedClient(this.chunks, this.gate);
  final List<String> chunks;
  final Completer<void> gate;

  @override
  Stream<String> streamReply({
    required List<ChatMessage> history,
    required String systemPrompt,
  }) async* {
    if (chunks.isNotEmpty) yield chunks.first;
    await gate.future;
    for (final c in chunks.skip(1)) {
      yield c;
    }
  }
}

void main() {
  test('streams chunks into one reply and saves history', () async {
    final storage = MemoryStorage();
    final client = FakeClient(['Eat ', 'more ', 'fibre.']);
    final c = ChatController(client: client, storage: storage);

    await c.send('Tips?');

    expect(c.messages.length, 2);
    expect(c.messages.last.text, 'Eat more fibre.');
    expect(c.isStreaming, false);
    expect(storage.saved.length, 2);
    expect(client.lastHistory!.single.text, 'Tips?');
  });

  test('shows a friendly error and excludes it from later history', () async {
    final client = FakeClient([], error: AiException('Rate limit reached'));
    final c = ChatController(client: client, storage: MemoryStorage());

    await c.send('Hello');
    expect(c.messages.last.isError, true);
    expect(c.messages.last.text, 'Rate limit reached');

    await c.send('Again');
    // history = both user turns only; the error reply is dropped
    expect(client.lastHistory!.every((m) => m.role == ChatRole.user), true);
  });

  testWidgets('the chat sheet shows starter chips and sends a prompt',
      (tester) async {
    final c = ChatController(
      client: FakeClient(['Sure!']),
      storage: MemoryStorage(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatSheet(controller: c, showKeyWarning: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ask me about food and nutrition'), findsOneWidget);
    await tester.tap(find.text('Healthy snacks under 200 calories'));
    await tester.pumpAndSettle();

    expect(find.text('Healthy snacks under 200 calories'), findsOneWidget);
    expect(find.text('Sure!'), findsOneWidget);
  });

  // --- added when the chatbot was moved into the app -----------------------
  //
  // The controller used to be built once in main() beside a permanent screen.
  // It now lives on the Shell and the sheet opens and closes over it, so
  // load() can be called many times and can be called while a reply is still
  // arriving. Neither was possible before.

  test('reopening the sheet does not re-read storage over the conversation',
      () async {
    final storage = MemoryStorage();
    final c = ChatController(client: FakeClient(['Hi']), storage: storage);

    await c.load();
    await c.send('First');
    expect(c.messages.length, 2);

    // Closing and reopening the sheet calls load() again.
    await c.load();
    expect(c.messages.length, 2,
        reason: 'the conversation was replaced by what was on disk');
    expect(c.messages.last.text, 'Hi');
  });

  test('loading while a reply is streaming leaves the reply alone', () async {
    final storage = MemoryStorage();
    // Storage holds an older conversation than the one in memory.
    storage.saved = [ChatMessage.user('old'), ChatMessage.model('older')];

    final gate = Completer<void>();
    final client = GatedClient(['part one ', 'part two'], gate);
    final c = ChatController(client: client, storage: storage);

    final sending = c.send('Tell me something');
    await Future<void>.delayed(Duration.zero);
    expect(c.isStreaming, true);

    // The sheet is reopened mid-reply.
    await c.load();

    gate.complete();
    await sending;

    expect(c.messages.last.text, 'part one part two',
        reason: 'the streaming reply was clobbered by the stored history');
    expect(c.messages.any((m) => m.text == 'older'), false);
  });

  test('clearing does not let the old conversation come back', () async {
    final storage = MemoryStorage();
    final c = ChatController(client: FakeClient(['Hi']), storage: storage);
    await c.send('Something');
    await c.clear();
    expect(c.messages, isEmpty);

    await c.load();
    expect(c.messages, isEmpty,
        reason: 'a cleared conversation reappeared on reopen');
  });
}
