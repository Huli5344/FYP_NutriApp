/// Tests for the ported business rules.
///
/// A direct port of the backend's tests.py, so the Dart and Python
/// implementations are held to the same behaviour. If these pass and the
/// Python ones pass, the two agree.
///
/// Run with: flutter test
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nutriapp_diary/logic.dart';
import 'package:nutriapp_diary/models.dart';
import 'package:nutriapp_diary/seed_data.dart';

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

  // -------------------------------------------------------------------------
  // Goals: turning a profile into a calorie target
  // -------------------------------------------------------------------------
  group('Basal metabolic rate', () {
    test('male matches the published equation', () {
      // 10(80) + 6.25(180) - 5(30) + 5
      expect(
          basalMetabolicRate(
              age: 30, heightCm: 180, weightKg: 80, gender: 'Male'),
          1780);
    });

    test('female matches the published equation', () {
      // 10(58) + 6.25(163) - 5(23) - 161
      expect(
          basalMetabolicRate(
              age: 23, heightCm: 163, weightKg: 58, gender: 'Female'),
          1323);
    });

    test('unstated sex lands between the two', () {
      final male = basalMetabolicRate(
          age: 30, heightCm: 170, weightKg: 70, gender: 'Male');
      final female = basalMetabolicRate(
          age: 30, heightCm: 170, weightKg: 70, gender: 'Female');
      final either =
          basalMetabolicRate(age: 30, heightCm: 170, weightKg: 70);
      expect(female, lessThan(either));
      expect(either, lessThan(male));
    });

    test('an unrecognised gender is treated as unstated', () {
      expect(
          basalMetabolicRate(
              age: 30, heightCm: 170, weightKg: 70, gender: 'Non-binary'),
          basalMetabolicRate(age: 30, heightCm: 170, weightKg: 70));
    });
  });

  group('Daily target', () {
    int target(
            {String activity = 'Moderately Active',
            String goal = 'Maintain Weight',
            int age = 30,
            double height = 175,
            double weight = 75,
            String? gender}) =>
        dailyTargetFor(
            age: age,
            heightCm: height,
            weightKg: weight,
            activityLevel: activity,
            goal: goal,
            gender: gender);

    test('activity level raises the target', () {
      expect(target(activity: 'Very Active'),
          greaterThan(target(activity: 'Sedentary')));
    });

    test('losing lowers it and gaining raises it', () {
      expect(target(goal: 'Lose Weight'), lessThan(target()));
      expect(target(goal: 'Gain Weight'), greaterThan(target()));
    });

    test('eat healthier is a maintenance target', () {
      expect(target(goal: 'Eat Healthier'), target(goal: 'Maintain Weight'));
    });

    test('a deficit never drops below resting burn', () {
      // The rule that matters most. A small, sedentary person on a 500 kcal
      // deficit comes out below what their body uses at rest.
      final bmr = basalMetabolicRate(
          age: 25, heightCm: 155, weightKg: 48, gender: 'Female');
      final result = target(
          age: 25,
          height: 155,
          weight: 48,
          gender: 'Female',
          activity: 'Sedentary',
          goal: 'Lose Weight');
      expect(result, greaterThanOrEqualTo(bmr));
    });

    test('the floor applies even to a tiny resting burn', () {
      expect(
          target(
              age: 90,
              height: 140,
              weight: 35,
              gender: 'Female',
              activity: 'Sedentary',
              goal: 'Lose Weight'),
          greaterThanOrEqualTo(minDailyTarget));
    });

    test('a very large input is capped', () {
      expect(
          target(
              age: 20,
              height: 220,
              weight: 250,
              gender: 'Male',
              activity: 'Very Active',
              goal: 'Gain Weight'),
          lessThanOrEqualTo(maxDailyTarget));
    });

    test('rounded to ten', () {
      expect(target() % 10, 0);
    });

    test('an unknown activity level uses the default', () {
      expect(target(activity: 'Olympian'),
          target(activity: 'Moderately Active'));
    });
  });

  // -------------------------------------------------------------------------
  // The translation this whole layer exists for
  // -------------------------------------------------------------------------
  group('Label normalisation', () {
    test('dairy becomes milk', () {
      expect(normaliseAllergens(['Dairy']), ['milk']);
    });

    test('plurals become the singular token', () {
      expect(normaliseAllergens(['Peanuts']), ['peanut']);
      expect(normaliseAllergens(['Eggs']), ['egg']);
    });

    test('tree nuts becomes the token the data uses', () {
      expect(normaliseAllergens(['Tree Nuts']), ['nuts']);
    });

    test('normalised allergens actually filter', () {
      const r = Recipe(
          id: 'r1', name: 'Cheese toast', kcal: 500, carbsG: 40,
          proteinG: 20, fatG: 25, allergens: ['milk']);
      expect(isSafeFor(r, normaliseAllergens(['Dairy'])), isFalse);
      // And the failure mode it replaces: the raw label matches nothing, so
      // the recipe is wrongly reported as safe.
      expect(isSafeFor(r, ['Dairy']), isTrue);
    });

    test('an unknown label is passed through lowercased', () {
      expect(normaliseAllergens(['Lupin']), ['lupin']);
    });

    test('results are sorted and deduplicated', () {
      expect(normaliseAllergens(['Soy', 'Dairy', 'Soy']), ['milk', 'soy']);
    });

    test('every chip maps onto a token the seed data could carry', () {
      const known = {
        'peanut', 'nuts', 'milk', 'egg', 'gluten', 'soy', 'fish',
        'shellfish', 'sesame'
      };
      for (final token in allergenTokens.values) {
        expect(known, contains(token));
      }
    });
  });

  group('Primary diet type', () {
    test('no preference is balanced', () {
      expect(primaryDietType([]), 'balanced');
    });

    test('the most restrictive preference wins', () {
      expect(primaryDietType(['High protein', 'Vegan']), 'vegan');
      expect(primaryDietType(['Low carb', 'Vegetarian']), 'vegetarian');
    });

    test('every diet token appears in the precedence list', () {
      // Otherwise a preference could be chosen and never requested.
      for (final token in dietTokens.values) {
        expect(dietPrecedence, contains(token));
      }
    });
  });

  group('Build profile', () {
    UserProfile make({int? manual}) => buildProfile(
          name: 'Wei Ling',
          email: 'guest@test.com',
          age: 23,
          gender: 'Female',
          heightCm: 163,
          weightKg: 58,
          activityLevel: 'Lightly Active',
          goal: 'Lose Weight',
          preferences: const ['Pescatarian'],
          restrictions: const ['Dairy'],
          manualTargetKcal: manual,
        );

    test('raw answers are kept alongside the tokens', () {
      final p = make();
      expect(p.restrictions, ['Dairy']);
      expect(p.allergens, ['milk']);
    });

    test('the target is calculated', () {
      final p = make();
      expect(p.targetKcal, p.computedTargetKcal);
      expect(p.targetIsManual, isFalse);
    });

    test('a manual target overrides the calculation without losing it', () {
      final p = make(manual: 1600);
      expect(p.targetKcal, 1600);
      expect(p.targetIsManual, isTrue);
      expect(p.computedTargetKcal, isNot(1600));
    });

    test('the diet type is derived from the preferences', () {
      expect(make().dietType, 'pescatarian');
    });

    test('a profile survives a round trip through a database row', () {
      final p = make(manual: 1600);
      final back = UserProfile.fromRow(p.toRow());
      expect(back.name, p.name);
      expect(back.allergens, p.allergens);
      expect(back.restrictions, p.restrictions);
      expect(back.targetKcal, p.targetKcal);
      expect(back.targetIsManual, isTrue);
      expect(back.heightCm, p.heightCm);
    });
  });

  // -------------------------------------------------------------------------
  // Insights
  // -------------------------------------------------------------------------
  group('Insights', () {
    final today = DateTime(2026, 10, 31, 12);

    Entry on(int daysAgo, int kcal, [String category = 'lunch']) => Entry(
          id: 'e$daysAgo-$kcal',
          foodName: 'Test',
          quantity: 1,
          serving: '1',
          kcal: kcal,
          carbsG: 10,
          proteinG: 5,
          fatG: 2,
          category: category,
          tags: const [],
          eatenAt: today.subtract(Duration(days: daysAgo)),
          updatedAt: today,
        );

    test('unlogged days are present with zero totals', () {
      // A gap in a chart and a day at zero must not look identical.
      final totals = dailyTotals([on(0, 500)], endDay: today, days: 7);
      expect(totals.length, 7);
      expect(totals.take(6).map((d) => d.entryCount), everyElement(0));
      expect(totals.last.kcal, 500);
    });

    test('entries outside the window are ignored', () {
      final totals = dailyTotals([on(30, 900)], endDay: today, days: 7);
      expect(totals.fold<int>(0, (a, d) => a + d.kcal), 0);
    });

    test('the average is over logged days not the whole window', () {
      final totals = dailyTotals(
          [on(0, 2000), on(1, 2000), on(2, 2000)], endDay: today, days: 7);
      final trend = summariseTrend(totals, 2000);
      expect(trend.daysLogged, 3);
      expect(trend.averageKcal, 2000);
    });

    test('an empty window does not divide by zero', () {
      final trend = summariseTrend(dailyTotals([], endDay: today), 2000);
      expect(trend.averageKcal, 0);
      expect(trend.adherencePercent, 0);
    });

    test('a day within tolerance counts as on target', () {
      final trend = summariseTrend(
          dailyTotals([on(0, 2050)], endDay: today), 2000);
      expect(trend.daysOnTarget, 1);
      expect(trend.daysOver, 0);
    });

    test('the three buckets always sum to the logged days', () {
      final trend = summariseTrend(
          dailyTotals([on(0, 1200), on(1, 2000), on(2, 3000)],
              endDay: today),
          2000);
      expect(trend.daysOnTarget + trend.daysOver + trend.daysUnder,
          trend.daysLogged);
    });

    test('a streak counts back from the last logged day', () {
      final totals = dailyTotals([on(0, 500), on(1, 500), on(2, 500)],
          endDay: today);
      expect(loggingStreak(totals), 3);
    });

    test('an unlogged today does not break the streak', () {
      // Otherwise the streak collapses every morning before breakfast.
      final totals = dailyTotals([on(1, 500), on(2, 500)], endDay: today);
      expect(loggingStreak(totals), 2);
    });

    test('a gap does break the streak', () {
      final totals =
          dailyTotals([on(0, 500), on(2, 500), on(3, 500)], endDay: today);
      expect(loggingStreak(totals), 1);
    });

    test('category totals sum to the window total', () {
      final totals = dailyTotals(
          [on(0, 400, 'breakfast'), on(0, 600, 'lunch'), on(1, 500, 'dinner')],
          endDay: today);
      expect(categoryTotals(totals).values.fold<int>(0, (a, b) => a + b), 1500);
    });
  });

  group('Weight trend', () {
    final today = DateTime(2026, 10, 31, 12);

    WeightEntry w(int daysAgo, double kg, {bool deleted = false}) =>
        WeightEntry(
          id: 'w$daysAgo',
          kg: kg,
          recordedAt: today.subtract(Duration(days: daysAgo)),
          deleted: deleted,
          updatedAt: today,
        );

    test('one measurement is not a trend', () {
      expect(weightChange([w(0, 70)]), isNull);
    });

    test('change is measured oldest to newest', () {
      expect(weightChange([w(0, 68), w(10, 70)]), -2.0);
    });

    test('deleted measurements are ignored', () {
      expect(weightChange([w(10, 90, deleted: true), w(1, 70), w(0, 69)]),
          -1.0);
    });

    test('progress is a share of the distance to the target', () {
      expect(progressTowardsTarget([w(10, 70), w(0, 68)], 66), 50);
    });

    test('moving the wrong way reports zero rather than a negative', () {
      expect(progressTowardsTarget([w(10, 70), w(0, 72)], 66), 0);
    });

    test('overshooting the target caps at a hundred', () {
      expect(progressTowardsTarget([w(10, 70), w(0, 64)], 66), 100);
    });

    test('no target means no progress figure', () {
      expect(progressTowardsTarget([w(10, 70), w(0, 68)], null), isNull);
    });
  });

  group('Seed data consistency', () {
    test('every offered preference has offline recipes', () {
      for (final token in dietTokens.values) {
        expect(seedRecipes.where((r) => matchesDiet(r, token)), isNotEmpty,
            reason: 'no offline recipe is tagged $token');
      }
    });

    test('every offered preference survives a common allergy', () {
      // A vegan avoiding gluten must still be offered something.
      for (final token in dietTokens.values) {
        expect(recommend(seedRecipes, const ['gluten'], token, 600), isNotEmpty,
            reason: '$token plus a gluten allergy returns nothing');
      }
    });

    test('no vegan recipe lists an animal allergen', () {
      for (final r in seedRecipes) {
        if (r.dietTypes.contains('vegan')) {
          expect(
              r.allergens
                  .where((a) => const ['egg', 'milk', 'fish', 'shellfish']
                      .contains(a)),
              isEmpty,
              reason: '${r.name} is vegan but lists an animal allergen');
        }
      }
    });
  });
}
