/// NutriBot, as a sheet that slides up over whichever tab you are on.
///
/// Adapted from the standalone chatbot's `chat_screen.dart`. The bubbles, the
/// input bar, the welcome prompts and the missing-key banner are as written;
/// what changed is the container. A full screen with its own AppBar would
/// have replaced the tab you were looking at, and the point of a button on
/// every screen is that you can ask a question without leaving what you were
/// doing and losing your place.
///
/// Two things a chat in a sheet has to get right and a chat in a page does
/// not:
///
///   * The keyboard. A modal sheet does not move out of its way by itself,
///     so the view insets are added as bottom padding -- without that the
///     input bar is behind the keyboard, which is where it is needed most.
///   * Scroll ownership. The sheet is a fixed fraction of the screen rather
///     than a draggable one, so a drag inside the message list scrolls the
///     list instead of dismissing the sheet mid-sentence.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../ui.dart';
import 'chat_controller.dart';
import 'chat_message.dart';

const _starterPrompts = [
  'Plan a high-protein vegetarian day',
  'Healthy snacks under 200 calories',
  'How much protein do I need to build muscle?',
  'Pros and cons of intermittent fasting',
];

/// Open the chat over the current screen.
///
/// The controller is owned by the caller, not created here: it holds the
/// conversation and may still be streaming a reply when the sheet is closed.
/// Creating one per open would abandon that reply and reload the history from
/// storage every time.
Future<void> showChatSheet(BuildContext context, ChatController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => ChatSheet(controller: controller),
  );
}

class ChatSheet extends StatefulWidget {
  const ChatSheet({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<ChatSheet> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  ChatController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_scrollToBottom);
    _c.load();
  }

  @override
  void dispose() {
    _c.removeListener(_scrollToBottom);
    _input.dispose();
    _scroll.dispose();
    // The controller is not disposed here. It belongs to the Shell and
    // outlives this sheet, which is what lets a reply keep streaming while
    // the sheet is closed.
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _send([String? text]) {
    final value = text ?? _input.text;
    if (value.trim().isEmpty) return;
    _input.clear();
    _c.send(value);
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: const Text('This deletes your chat history from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.bad),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    // Nine tenths of the screen: tall enough to hold a conversation, short
    // enough that the tab underneath is still visible and the sheet reads as
    // something covering the app rather than as a new page.
    final height = MediaQuery.sizeOf(context).height * 0.9;

    return Padding(
      // The keyboard. Without this the input bar sits behind it.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final messages = _c.messages;
            return Column(
              children: [
                _Handle(onClear: messages.isEmpty ? null : _confirmClear),
                Expanded(
                  child: messages.isEmpty
                      ? _Welcome(onPrompt: _send)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: messages.length,
                          itemBuilder: (context, i) => _Bubble(
                            message: messages[i],
                            waiting: _c.isStreaming &&
                                i == messages.length - 1 &&
                                messages[i].text.isEmpty,
                          ),
                        ),
                ),
                _InputBar(
                  controller: _input,
                  streaming: _c.isStreaming,
                  onSend: _send,
                  onStop: _c.stop,
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'General information only, not medical advice.',
                    style: tMute,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The grab bar, the name, and the way out.
///
/// A sheet with no visible dismiss is a sheet somebody taps around looking
/// for one. The drag handle says it can be pulled down; the close button
/// says so to anyone who does not read drag handles.
class _Handle extends StatelessWidget {
  const _Handle({this.onClear});
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.wire2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Clear conversation',
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppColors.mute,
              ),
              const Expanded(
                child: Text('NutriBot',
                    textAlign: TextAlign.center, style: tHead),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 20),
                color: AppColors.mute,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onPrompt});
  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        const Icon(Icons.eco_outlined, size: 48, color: AppColors.accent),
        const SizedBox(height: 12),
        const Text('Ask me about food and nutrition',
            textAlign: TextAlign.center, style: tHead),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _starterPrompts)
              ActionChip(
                label: Text(p, style: const TextStyle(fontSize: 13)),
                onPressed: () => onPrompt(p),
              ),
          ],
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.waiting});
  final ChatMessage message;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final background = message.isError
        ? const Color(0xFFFBF4EA)
        : isUser
            ? AppColors.accent
            : AppColors.tint;
    final foreground = message.isError
        ? AppColors.warn
        : isUser
            ? AppColors.surface
            : AppColors.ink;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: waiting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.mute),
              )
            : isUser
                ? Text(message.text,
                    style: TextStyle(color: foreground, fontSize: 15))
                : MarkdownBody(
                    data: message.text,
                    styleSheet:
                        MarkdownStyleSheet.fromTheme(Theme.of(context))
                            .copyWith(
                      p: TextStyle(
                          color: foreground, fontSize: 15, height: 1.35),
                    ),
                  ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.streaming,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool streaming;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: 'Ask about diet or nutrition...',
                filled: true,
                fillColor: AppColors.paper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Stop replaces Send while a reply is arriving, rather than sitting
          // beside it: a second send during a stream is ignored by the
          // controller anyway, so a live Send button would do nothing.
          streaming
              ? IconButton.filledTonal(
                  tooltip: 'Stop',
                  onPressed: onStop,
                  icon: const Icon(Icons.stop),
                )
              : IconButton.filled(
                  tooltip: 'Send',
                  onPressed: onSend,
                  icon: const Icon(Icons.send),
                ),
        ],
      ),
    );
  }
}
