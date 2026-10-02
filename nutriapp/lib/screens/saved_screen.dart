/// Saved to diary.
///
/// A screen rather than a toast, because the point is that the user can see
/// the day's figures change without opening the diary.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'edit_entry_screen.dart';

class SavedScreen extends StatefulWidget {
  final Entry entry;
  const SavedScreen({super.key, required this.entry});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  DaySummary? _summary;
  List<Entry> _sameMeal = [];
  bool _loading = true;
  bool _undone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Summarise the day the entry belongs to, not today. A backdated meal
    // compared against today's totals produces a meaningless before and after.
    final day = widget.entry.eatenAt;
    final entries = await LocalDb.instance.entriesForDay(day);
    if (!mounted) return;
    setState(() {
      _summary = summariseDay(entries, Profile.dailyTarget);
      _sameMeal =
          entries.where((e) => e.category == widget.entry.category).toList();
      _loading = false;
    });
  }

  Future<void> _undo() async {
    await LocalDb.instance.deleteEntry(widget.entry.id);
    if (!mounted) return;
    setState(() => _undone = true);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _summary == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = _summary!;
    final e = widget.entry;
    final before = s.remaining + e.kcal;
    final today = DateUtils.isSameDay(e.eatenAt, DateTime.now());

    return Scaffold(
      appBar: AppBar(title: const Text('Saved to diary')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: AppColors.tint,
              border: Border(left: BorderSide(color: AppColors.ink, width: 3)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('${e.foodName} added to ${e.category}.',
                      style: tBody),
                ),
                if (!_undone)
                  GestureDetector(
                    onTap: _undo,
                    child: const Text('Undo',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline)),
                  ),
              ],
            ),
          ),
          if (!today) ...[
            const SizedBox(height: 10),
            WireNote(
                'This entry is dated ${DateFormat('d MMMM').format(e.eatenAt)}, '
                "so it does not affect today's totals. The figures below are "
                'for that day.',
                warning: true),
          ],
          const SizedBox(height: 10),
          WireCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${s.remaining}', style: tBig),
                          Text(
                              s.over
                                  ? 'over target of ${s.target}'
                                  : 'left of ${s.target}',
                              style: tMute),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Was $before left', style: tMute),
                        Text(
                            'Now ${s.remaining} ${s.over ? 'over' : 'left'}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        Text(
                            '${capitalise(e.category)} '
                            '${s.byCategory[e.category]} of '
                            '${s.allowances[e.category]} kcal',
                            style: tMute),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                WireBar(percent: s.percent, over: s.over),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(capitalise(e.category), style: tHead),
              Text('${s.byCategory[e.category]} / ${s.allowances[e.category]}',
                  style: tMute),
            ],
          ),
          const SizedBox(height: 6),
          WireCard(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                for (final item in _sameMeal)
                  WireRow(
                    title: item.foodName,
                    subtitle: item.note.isNotEmpty
                        ? item.note
                        : '${item.quantity} × ${item.serving}',
                    trailing: '${item.kcal}',
                    last: item == _sameMeal.last,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: WireButton(
                  label: 'Adjust the serving',
                  outlined: true,
                  onPressed: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => EditEntryScreen(entry: e)));
                    if (mounted) Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: WireButton(
                  label: 'Done',
                  outlined: true,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
