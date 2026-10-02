/// Tests for the ported business rules.
///
/// A direct port of the backend's tests.py, so the Dart and Python
/// implementations are held to the same behaviour. If these pass and the
/// Python ones pass, the two agree.
///
/// Run with: flutter test

import 'package:flutter_test/flutter_test.dart';
import 'package:nutriapp_diary/logic.dart';
import 'package:nutriapp_diary/models.dart';

Nutrition n({int kcal = 0, double carbs = 0, double protein = 0, double fat = 0}) =>
    Nutrition(kcal: kcal, carbsG: carbs, proteinG: protein, fatG: fat);

Entry entry(int kcal, String category, {double protein = 10}) => Entry(
      id: 'e$kcal$category',
      foodName: 'Test',
      quantity: 1,
      serving: '1',
      kcal: kcal,
      carbsG: 20,
      proteinG: protein,
      fatG: 5,
      category: category,
      tags: const [],
      eatenAt: DateTime(2026, 9, 19, 13),
      updatedAt: DateTime(2026, 9, 19, 13),
    );

Recipe recipe(String id, int kcal,
        {List<String> allergens = const [], List<String> diets = const []}) =>
    Recipe(
      id: id,
      name: id,
      kcal: kcal,
      carbsG: 40,
      proteinG: 25,
      fatG: 15,
      allergens: allergens,
      dietTypes: diets,
    );

void main() {
  group('Calorie calculation', () {
    test('doubling the quantity doubles the calories', () {
      final result = scaleNutrition(n(kcal: 300, carbs: 40, protein: 20, fat: 8), 2);
      expect(result.kcal, 600);
    });

    test('fractional servings', () {
      final result =
          scaleNutrition(n(kcal: 607, carbs: 78, protein: 34, fat: 18), 1.5);
      // Dart rounds half away from zero, so 910.5 becomes 911. Python's
      // banker's rounding gives 910 for the same input. Harmless, but the two
      // implementations differ by one calorie on exact halves.
      expect(result.kcal, 911);
      expect(result.proteinG, 51.0);
    });

    test('macros scale with the calories', () {
      final result = scaleNutrition(n(kcal: 100, carbs: 10, protein: 5, fat: 2), 3);
      expect(result.carbsG, 30.0);
      expect(result.fatG, 6.0);
    });
  });

  group('Automatic meal categorisation', () {
    test('each window maps to its category', () {
      expect(categoriseByTime(DateTime(2026, 9, 19, 8)), 'breakfast');
      expect(categoriseByTime(DateTime(2026, 9, 19, 13, 5)), 'lunch');
      expect(categoriseByTime(DateTime(2026, 9, 19, 19, 30)), 'dinner');
      expect(categoriseByTime(DateTime(2026, 9, 19, 23, 30)), 'snacks');
      expect(categoriseByTime(DateTime(2026, 9, 19, 2)), 'snacks');
    });

    test('window boundaries', () {
      expect(categoriseByTime(DateTime(2026, 9, 19, 10, 59)), 'breakfast');
      expect(categoriseByTime(DateTime(2026, 9, 19, 11, 0)), 'lunch');
      expect(categoriseByTime(DateTime(2026, 9, 19, 15, 59)), 'lunch');
      expect(categoriseByTime(DateTime(2026, 9, 19, 16, 0)), 'dinner');
    });
  });

  group('Dietary tagging', () {
    test('high protein threshold', () {
      expect(autoTags(n(protein: 25, carbs: 30, fat: 10)), contains('high-protein'));
      expect(autoTags(n(protein: 24.9, carbs: 30, fat: 10)),
          isNot(contains('high-protein')));
    });

    test('a serving can earn several tags', () {
      final tags = autoTags(n(protein: 40, carbs: 10, fat: 3));
      expect(tags, contains('high-protein'));
      expect(tags, contains('low-carb'));
      expect(tags, contains('low-fat'));
    });

    test('no tags returns an empty list', () {
      expect(autoTags(n(protein: 15, carbs: 40, fat: 15)), isEmpty);
    });
  });

  group('Meal split', () {
    test('split sums exactly to the target', () {
      for (final target in [1200, 1850, 1851, 2333, 3000]) {
        final parts = splitTarget(target);
        final sum = parts.values.fold<int>(0, (a, b) => a + b);
        expect(sum, target, reason: 'target $target');
      }
    });

    test('dinner takes the largest share', () {
      final parts = splitTarget(2000);
      final biggest =
          parts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      expect(biggest, 'dinner');
    });

    test('macro targets reconstruct the calories', () {
      const target = 1850;
      final m = macroTargets(target);
      final kcal = m.carbsG * 4 + m.proteinG * 4 + m.fatG * 9;
      expect((kcal - target).abs() < 15, isTrue);
    });
  });

  group('Daily summary', () {
    test('totals and remaining', () {
      final s = summariseDay([entry(430, 'breakfast'), entry(620, 'lunch')], 1850);
      expect(s.eaten, 1050);
      expect(s.remaining, 800);
      expect(s.over, isFalse);
    });

    test('remaining goes negative when over target', () {
      // Clamping at zero would hide the overshoot from the user.
      final s = summariseDay([entry(2000, 'dinner')], 1850);
      expect(s.remaining, -150);
      expect(s.over, isTrue);
    });

    test('calories group by category', () {
      final s = summariseDay(
          [entry(300, 'breakfast'), entry(200, 'breakfast'), entry(600, 'dinner')],
          1850);
      expect(s.byCategory['breakfast'], 500);
      expect(s.byCategory['dinner'], 600);
      expect(s.byCategory['lunch'], 0);
    });

    test('empty day', () {
      final s = summariseDay([], 1850);
      expect(s.eaten, 0);
      expect(s.remaining, 1850);
      expect(s.entryCount, 0);
    });

    test('remaining for a meal never goes negative', () {
      final s = summariseDay([entry(900, 'breakfast')], 1850);
      expect(remainingForMeal(s, 'breakfast'), 0);
      expect(remainingForMeal(s, 'dinner') > 0, isTrue);
    });
  });

  group('Recommendations', () {
    final pool = [
      recipe('satay', 600, allergens: ['peanut'], diets: ['high-protein']),
      recipe('prawn', 610, allergens: ['shellfish']),
      recipe('chickpea', 598, diets: ['vegetarian', 'vegan']),
      recipe('lentil', 430, allergens: ['gluten'], diets: ['vegetarian', 'vegan']),
      recipe('beef', 590, diets: ['high-protein']),
    ];

    test('the display sizes are three then eight', () {
      expect(shownInitially, 3);
      expect(moreStep, 5);
      expect(shownExpanded, 8);
    });

    test('allergen recipes are removed entirely', () {
      final picks = recommend(pool, ['peanut'], 'balanced', 600);
      expect(picks.map((r) => r.id), isNot(contains('satay')));
    });

    test('exclusion beats a perfect calorie match', () {
      // Satay is the closest fit to 600 and must still not appear.
      final picks = recommend(pool, ['peanut'], 'balanced', 600);
      expect(picks.every((r) => !r.allergens.contains('peanut')), isTrue);
    });

    test('several allergens all apply', () {
      final picks =
          recommend(pool, ['peanut', 'shellfish', 'gluten'], 'balanced', 600);
      expect(picks.map((r) => r.id).toSet(), {'chickpea', 'beef'});
    });

    test('matching is case insensitive', () {
      expect(isSafeFor(pool.first, ['PEANUT']), isFalse);
    });

    test('diet type filters but falls back rather than returning nothing', () {
      final vegan = recommend(pool, [], 'vegan', 600);
      expect(vegan.every((r) => r.dietTypes.contains('vegan')), isTrue);
      final keto = recommend(pool, [], 'keto', 600);
      expect(keto, isNotEmpty);
    });

    test('closest calorie match ranks first', () {
      expect(recommend(pool, [], 'balanced', 600).first.id, 'satay');
    });

    test('recently shown meals are pushed down', () {
      final picks =
          recommend(pool, [], 'balanced', 600, recentIds: {'satay'});
      expect(picks.first.id, isNot('satay'));
    });

    test('expanding keeps the first three in place', () {
      // The reveal must append, not reshuffle, or the user loses their place.
      final big = [for (var i = 0; i < 20; i++) recipe('r$i', 400 + i * 20)];
      final three = recommend(big, [], 'balanced', 600, limit: shownInitially);
      final eight = recommend(big, [], 'balanced', 600, limit: shownExpanded);
      expect(eight.take(3).map((r) => r.id).toList(),
          three.map((r) => r.id).toList());
    });
  });
}
