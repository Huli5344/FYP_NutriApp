/// Home dashboard.
///
/// Answers one question: how much can I still eat today?

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'add_food_screen.dart';
import 'discover_screen.dart';
import 'recipe_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int tab)? onNavigate;
  const HomeScreen({super.key, this.onNavigate});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Entry> _entries = [];
  DaySummary? _summary;
  Recipe? _teaser;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await LocalDb.instance.entriesForDay(DateTime.now());
    final summary = summariseDay(entries, Profile.dailyTarget);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _summary = summary;
      _loading = false;
    });

    // The suggestion is best-effort: failing to reach the service must not
    // take the dashboard down with it.
    final meal = categoriseByTime(DateTime.now());
    final left = remainingForMeal(summary, meal);
    final result = await Api.instance.recommendations(Profile.dietType);
    final picks = recommend(
      result.recipes,
      Profile.allergens,
      Profile.dietType,
      left == 0 ? 600 : left,
      limit: 1,
    );
    if (!mounted) return;
    setState(() => _teaser = picks.isEmpty ? null : picks.first);
  }

  Future<void> _reset() async {
    await LocalDb.instance.reset();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _summary == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = _summary!;
    final meal = categoriseByTime(DateTime.now());
    final left = remainingForMeal(s, meal);

    return Scaffold(
      appBar: AppBar(
        title: Text('Today, ${DateFormat('d MMM').format(DateTime.now())}'),
        actions: [
          TextButton(
            onPressed: _reset,
            child: const Text('Reset', style: TextStyle(color: AppColors.mute)),
          ),
        ],
      ),
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
                                ? 'over your target of ${s.target}'
                                : 'left of ${s.target}',
                            style: tMute,
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Eaten ${s.eaten}', style: tMute),
                        Text('Target ${s.target}', style: tMute),
                        Text(
                            '${s.entryCount} ${s.entryCount == 1 ? 'entry' : 'entries'}',
                            style: tMute),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                WireBar(percent: s.percent, over: s.over),
                const SizedBox(height: 8),
                Text(
                  'Protein ${s.macros.proteinG.round()} / ${s.macroTargets.proteinG.round()} g'
                  '  ·  Carbs ${s.macros.carbsG.round()} / ${s.macroTargets.carbsG.round()} g'
                  '  ·  Fat ${s.macros.fatG.round()} / ${s.macroTargets.fatG.round()} g',
                  style: tMute,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Today's meals", style: tHead),
              GestureDetector(
                onTap: () => widget.onNavigate?.call(1),
                child: const Text('See diary',
                    style: TextStyle(fontSize: 12, color: AppColors.mute)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          WireCard(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                for (final name in categories)
                  WireRow(
                    title: capitalise(name),
                    subtitle: _mealSummary(name),
                    trailing: (s.byCategory[name] ?? 0) > 0
                        ? '${s.byCategory[name]}'
                        : '${s.allowances[name]} left',
                    last: name == categories.last,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          WireCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Recommended for $meal', style: tHead),
                    Chip_('about $left kcal'),
                  ],
                ),
                const SizedBox(height: 8),
                if (_teaser != null)
                  WireRow(
                    title: _teaser!.name,
                    subtitle:
                        '${_teaser!.kcal} kcal${_teaser!.estimated ? '*' : ''}, '
                        '${_teaser!.proteinG} g protein',
                    last: true,
                    onTap: () async {
                      await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => RecipeDetailScreen(
                                  recipe: _teaser!, slot: meal)));
                      _load();
                    },
                  )
                else
                  const Text('No suggestion available right now.', style: tMute),
                const SizedBox(height: 8),
                WireButton(
                  label: 'See all suggestions',
                  outlined: true,
                  small: true,
                  onPressed: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => DiscoverScreen(slot: meal)));
                    _load();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  String _mealSummary(String meal) {
    final items =
        _entries.where((e) => e.category == meal).map((e) => e.foodName).toList();
    return items.isEmpty ? 'Not logged yet' : items.join(', ');
  }
}
