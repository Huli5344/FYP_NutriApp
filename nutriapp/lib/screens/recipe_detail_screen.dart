/// Recommendation detail.
library;

import 'package:flutter/material.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'saved_screen.dart';

class RecipeDetailScreen extends StatefulWidget {
  final Recipe recipe;
  final String slot;

  /// Passed in rather than read here, so the allergen check in [build] and the
  /// one in [_save] cannot be looking at different versions of the profile.
  final UserProfile profile;

  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    required this.slot,
    required this.profile,
  });

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen> {
  late String _category = widget.slot;

  Future<void> _save() async {
    // Re-read at the moment of saving. A screen left open while an allergy was
    // added on another tab must not be able to write an unsafe entry.
    final current =
        await LocalDb.instance.loadProfile() ?? widget.profile;
    if (!isSafeFor(widget.recipe, current.allergens)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That meal lists an ingredient you are allergic to. '
            'Not saved.'),
      ));
      return;
    }
    final entry = await LocalDb.instance
        .addRecipeEntry(recipe: widget.recipe, category: _category);
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => SavedScreen(entry: entry, profile: current)));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recipe;
    final profile = widget.profile;
    final clear = isSafeFor(r, profile.allergens);

    return Scaffold(
      appBar: AppBar(title: Text(r.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const WireBox(height: 110),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text('${r.kcal}', style: tBig)),
              WireChip(
                clear ? 'No recorded allergens listed' : 'Lists an allergen you recorded',
                filled: clear,
                warning: !clear,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            r.estimated
                ? 'Estimated from the ingredient list. Assumes 4 servings.'
                : 'kcal per serving'
                    '${r.minutes != null ? ', about ${r.minutes} minutes to prepare' : ''}.',
            style: tMute,
          ),
          const SizedBox(height: 10),
          WireCard(
            child: Row(
              children: [
                Stat(value: '${r.carbsG} g', label: 'Carbs'),
                Stat(value: '${r.proteinG} g', label: 'Protein'),
                Stat(value: '${r.fatG} g', label: 'Fat'),
              ],
            ),
          ),
          // A single food has no ingredient list. An empty card under an
          // "Ingredients" heading would read as a recipe whose ingredients
          // failed to load.
          if (r.ingredients.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Ingredients', style: tHead),
            const SizedBox(height: 6),
            WireCard(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                children: [
                  for (final i in r.ingredients)
                    WireRow(title: i, last: i == r.ingredients.last),
                ],
              ),
            ),
          ],
          if (r.allergens.isNotEmpty) ...[
            const SizedBox(height: 10),
            WireNote(
                r.source == 'hpb'
                    ? 'May contain ${r.allergens.join(', ')}.'
                    : 'Ingredients list: ${r.allergens.join(', ')}.',
                warning: true),
          ],
          if (clear && profile.restrictions.isNotEmpty) ...[
            const SizedBox(height: 10),
            WireNote('Checked against your recorded restrictions: '
                'no ${profile.restrictions.join(', no ').toLowerCase()}.'),
          ],
          if (profile.restrictions.isEmpty) ...[
            const SizedBox(height: 10),
            const WireNote('You have no dietary restrictions recorded, so '
                'nothing was checked. Add them on the Profile tab.'),
          ],
          if (r.source == 'hpb') ...[
            const SizedBox(height: 10),
            const WireNote(
                'Allergens for single foods are worked out from the food\'s '
                'name, not from an ingredient list -- the Health Promotion '
                'Board publishes nutrients, not allergens. A dish can contain '
                'something its name does not mention.',
                warning: true),
          ],
          if (r.estimated) ...[
            const SizedBox(height: 10),
            const WireNote(
                'Allergens are worked out by matching ingredient names. '
                'TheMealDB is a recipe database, not an allergen certification '
                'service, and cannot account for substitutions, undeclared '
                'ingredients or cross-contamination. Check the full recipe.',
                warning: true),
          ],
          const SizedBox(height: 12),
          WireCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Save as', style: tLabel),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(value: c, child: Text(capitalise(c)))
                  ],
                  onChanged: (value) =>
                      setState(() => _category = value ?? _category),
                ),
                const SizedBox(height: 12),
                WireButton(label: 'Save to diary', onPressed: _save),
              ],
            ),
          ),
          const SizedBox(height: 10),
          WireButton(
            label: 'Not for me',
            outlined: true,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
