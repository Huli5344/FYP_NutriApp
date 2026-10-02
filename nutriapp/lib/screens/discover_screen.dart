/// Recommendations.
///
/// Opens with three and reveals five more on request. The reveal appends
/// rather than reshuffles: ranking is deterministic for the same inputs, so
/// the first three stay where they were and the next five appear below.

import 'package:flutter/material.dart';

import '../api.dart';
import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'recipe_detail_screen.dart';

class DiscoverScreen extends StatefulWidget {
  final String? slot;
  const DiscoverScreen({super.key, this.slot});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<Recipe> _pool = [];
  List<Recipe> _ranked = [];
  RecipeOrigin _origin = RecipeOrigin.local;
  String? _warning;
  bool _expanded = false;
  bool _loading = true;
  int _slotLeft = 0;
  late String _slot;

  @override
  void initState() {
    super.initState();
    _slot = widget.slot ?? categoriseByTime(DateTime.now());
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() => _loading = true);

    final entries = await LocalDb.instance.entriesForDay(DateTime.now());
    final summary = summariseDay(entries, Profile.dailyTarget);
    final left = remainingForMeal(summary, _slot);

    final result = await Api.instance.recommendations(Profile.dietType);
    final recent =
        refresh ? await LocalDb.instance.recentlyShown() : <String>{};

    final ranked = recommend(
      result.recipes,
      Profile.allergens,
      Profile.dietType,
      left == 0 ? 600 : left,
      recentIds: recent,
      limit: shownExpanded,
    );

    if (refresh) {
      await LocalDb.instance.recordShown(ranked.map((r) => r.id));
    }

    if (!mounted) return;
    setState(() {
      _pool = result.recipes;
      _ranked = ranked;
      _origin = result.origin;
      _warning = result.warning;
      _slotLeft = left;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final visible =
        _ranked.take(_expanded ? shownExpanded : shownInitially).toList();
    final moreAvailable = _ranked.length - visible.length;
    final hidden =
        _pool.where((r) => !isSafeFor(r, Profile.allergens)).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Discover')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text('For $_slot, about $_slotLeft kcal', style: tHead),
              ),
              Chip_('${visible.length} shown'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Chip_(
                _origin == RecipeOrigin.api
                    ? 'Live from the recipe service'
                    : 'Offline meals',
                filled: _origin == RecipeOrigin.api,
              ),
            ],
          ),
          if (_warning != null) ...[
            const SizedBox(height: 8),
            WireNote(_warning!, warning: true),
          ],
          const SizedBox(height: 8),
          WireNote(
            '${capitalise(Profile.allergens.join(' and '))} are excluded from '
            'everything you see here. $hidden '
            '${hidden == 1 ? 'meal' : 'meals'} hidden.',
            warning: true,
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < visible.length; i++) ...[
            if (i == shownInitially) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('More suggestions', style: tHead),
                  Text('${visible.length - shownInitially} more', style: tMute),
                ],
              ),
              const SizedBox(height: 6),
            ],
            _recipeCard(visible[i]),
            const SizedBox(height: 10),
          ],
          if (moreAvailable > 0)
            WireButton(
              label: 'Show me more ($moreAvailable more)',
              onPressed: () => setState(() => _expanded = true),
            )
          else if (_expanded)
            Text(
                'That is all ${visible.length} suggestions for $_slot. '
                'Refresh for a different set.',
                style: tMute),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: WireButton(
                  label: 'Refresh',
                  outlined: true,
                  onPressed: () => _load(refresh: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
              'Ranked by how close each meal lands to the calories left for '
              '$_slot, with recently shown meals pushed down after a refresh.',
              style: tMute),
          if (visible.isNotEmpty && visible.first.estimated) ...[
            const SizedBox(height: 6),
            const Text(
                '* Calories are estimated from the ingredient list. '
                'TheMealDB publishes no nutrition data.',
                style: tMute),
          ],
          const SizedBox(height: 6),
          const Text(
              'Recipe data and imagery: TheMealDB (https://www.themealdb.com/)',
              style: tMute),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _recipeCard(Recipe r) {
    return WireCard(
      onTap: () async {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => RecipeDetailScreen(recipe: r, slot: _slot)));
        if (mounted) _load();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const WireBox(height: 78),
          const SizedBox(height: 8),
          Text(r.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            '${r.kcal} kcal${r.estimated ? '*' : ''}, ${r.proteinG} g protein'
            '${r.minutes != null ? ', ${r.minutes} min' : ''}'
            '${r.area != null ? ', ${r.area}' : ''}',
            style: tMute,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in r.dietTypes) Chip_(capitalise(d)),
              for (final a in r.allergens) Chip_('Lists $a', warning: true),
            ],
          ),
        ],
      ),
    );
  }
}
