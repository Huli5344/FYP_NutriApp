/// Today's diary. Entries grouped by meal, with per-meal allowances.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'add_food_screen.dart';
import 'edit_entry_screen.dart';

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  List<Entry> _entries = [];
  DaySummary? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await LocalDb.instance.entriesForDay(DateTime.now());
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _summary = summariseDay(entries, Profile.dailyTarget);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _summary == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = _summary!;

    return Scaffold(
      appBar: AppBar(title: const Text("Today's diary")),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.ink,
        foregroundColor: Colors.white,
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AddFoodScreen()));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('<', style: tMute),
              Text(DateFormat('EEEE d MMMM').format(DateTime.now()),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const Text('>', style: tMute),
            ],
          ),
          const SizedBox(height: 10),
          WireCard(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${s.eaten} of ${s.target} kcal', style: tBody),
                    Text('${s.remaining} ${s.over ? 'over' : 'left'}', style: tMute),
                  ],
                ),
                const SizedBox(height: 8),
                WireBar(percent: s.percent, over: s.over),
              ],
            ),
          ),
          for (final meal in categories) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(capitalise(meal), style: tHead),
                Text('${s.byCategory[meal]} / ${s.allowances[meal]}', style: tMute),
              ],
            ),
            const SizedBox(height: 6),
            WireCard(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: _mealSection(meal),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Select any entry to change the amount, move it to another meal, '
            'or delete it.',
            style: tMute,
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _mealSection(String meal) {
    final items = _entries.where((e) => e.category == meal).toList();
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 9),
        child: Text('Nothing logged.', style: tMute),
      );
    }
    return Column(
      children: [
        for (final e in items)
          WireRow(
            title: e.foodName,
            subtitle: '${e.quantity} × ${e.serving}'
                '${e.note.isNotEmpty ? ' · ${e.note}' : ''}',
            trailing: '${e.kcal}',
            tags: e.tags,
            last: e == items.last,
            onTap: () async {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => EditEntryScreen(entry: e)));
              _load();
            },
          ),
      ],
    );
  }
}
