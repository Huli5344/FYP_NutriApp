/// Recommendation detail.

import 'package:flutter/material.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'saved_screen.dart';

class RecipeDetailScreen extends StatefulWidget {
  final Recipe recipe;
  final String slot;
  const RecipeDetailScreen({super.key, required this.recipe, required this.slot});

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen> {
  late String _category = widget.slot;

  Future<void> _save() async {
    // Re-check at the moment of saving. A screen opened before an allergy was
    // recorded must not be able to write an unsafe entry.
    if (!isSafeFor(widget.recipe, Profile.allergens)) {
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
        context, MaterialPageRoute(builder: (_) => SavedScreen(entry: entry)));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recipe;
    final clear = isSafeFor(r, Profile.allergens);

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
              Chip_(
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
          if (r.allergens.isNotEmpty) ...[
            const SizedBox(height: 10),
            WireNote('Ingredients list: ${r.allergens.join(', ')}.', warning: true),
          ],
          if (clear) ...[
            const SizedBox(height: 10),
            WireNote('Checked against your recorded allergens: '
                'no ${Profile.allergens.join(', no ')}.'),
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
                  value: _category,
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
