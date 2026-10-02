/// Business rules for the Diary and Recommendations module.
///
/// A direct port of the backend's logic.py. These run on the device because
/// the diary has to work without a connection, so the calculations cannot sit
/// behind an API call.
///
/// Pure functions only: no database, no HTTP, no Flutter imports. That keeps
/// them testable without a device (see test/logic_test.dart) and makes it
/// obvious that nothing here can block on I/O.

import 'models.dart';

// ---------------------------------------------------------------------------
// Configuration. Set by an administrator in the full product; constants here
// because the admin console is a different module.
// ---------------------------------------------------------------------------

/// Share of the daily target allotted to each meal. Must sum to 1.0.
const Map<String, double> mealSplit = {
  'breakfast': 0.25,
  'lunch': 0.30,
  'dinner': 0.35,
  'snacks': 0.10,
};

/// Start hour inclusive, end hour exclusive.
const List<CategoryWindow> categoryWindows = [
  CategoryWindow('breakfast', 4, 11),
  CategoryWindow('lunch', 11, 16),
  CategoryWindow('dinner', 16, 22),
];

const String fallbackCategory = 'snacks';

const List<String> categories = ['breakfast', 'lunch', 'dinner', 'snacks'];

/// Carbohydrate, protein, fat as a share of total calories.
const List<double> macroSplit = [0.45, 0.30, 0.25];

/// Discover opens with a short list and reveals the rest on request.
const int shownInitially = 3;
const int moreStep = 5;
const int shownExpanded = shownInitially + moreStep;

class CategoryWindow {
  final String name;
  final int startHour;
  final int endHour;
  const CategoryWindow(this.name, this.startHour, this.endHour);
}

// ---------------------------------------------------------------------------
// Calorie calculation
// ---------------------------------------------------------------------------

/// Scale a food's per-serving values by a quantity.
///
/// Foods are stored per serving rather than per 100 g, so a hawker plate and a
/// 40 g scoop of oats share one table without a unit column half the rows
/// would ignore.
Nutrition scaleNutrition(Nutrition perServing, double quantity) {
  return Nutrition(
    kcal: (perServing.kcal * quantity).round(),
    carbsG: _round1(perServing.carbsG * quantity),
    proteinG: _round1(perServing.proteinG * quantity),
    fatG: _round1(perServing.fatG * quantity),
  );
}

double _round1(double value) => (value * 10).round() / 10;

// ---------------------------------------------------------------------------
// Automatic meal categorisation
// ---------------------------------------------------------------------------

/// Derive a meal category from when the food was eaten.
///
/// Uses the time of the meal, not the time of logging, so recording yesterday's
/// dinner at midnight still files it under dinner.
String categoriseByTime(DateTime eatenAt) {
  final hour = eatenAt.hour;
  for (final window in categoryWindows) {
    if (hour >= window.startHour && hour < window.endHour) {
      return window.name;
    }
  }
  return fallbackCategory;
}

// ---------------------------------------------------------------------------
// Dietary tagging
// ---------------------------------------------------------------------------

/// Tags a serving earns from the threshold rules.
///
/// Returns an empty list when nothing applies, rather than a placeholder. The
/// interface uses an empty result to offer manual tagging, so it has to be
/// distinguishable from "not yet evaluated".
List<String> autoTags(Nutrition n) {
  final tags = <String>[];
  if (n.proteinG >= 25) tags.add('high-protein');
  if (n.proteinG < 8) tags.add('low-protein');
  if (n.carbsG >= 60) tags.add('high-carb');
  if (n.carbsG <= 20) tags.add('low-carb');
  if (n.fatG >= 25) tags.add('high-fat');
  if (n.fatG <= 5) tags.add('low-fat');
  return tags;
}

// ---------------------------------------------------------------------------
// Daily summary and dashboard
// ---------------------------------------------------------------------------

/// Divide the daily target across meals, absorbing rounding drift.
///
/// Rounding each share independently can leave the parts a few calories off the
/// total, which reads as a bug on screen. The largest slice takes the
/// remainder.
Map<String, int> splitTarget(int targetKcal) {
  final parts = <String, int>{};
  mealSplit.forEach((meal, share) {
    parts[meal] = (targetKcal * share).round();
  });

  final sum = parts.values.fold<int>(0, (a, b) => a + b);
  final drift = targetKcal - sum;
  if (drift != 0) {
    var biggest = parts.keys.first;
    parts.forEach((meal, value) {
      if (value > parts[biggest]!) biggest = meal;
    });
    parts[biggest] = parts[biggest]! + drift;
  }
  return parts;
}

/// Grams of carbohydrate, protein and fat implied by a calorie target.
Nutrition macroTargets(int targetKcal) {
  return Nutrition(
    kcal: targetKcal,
    carbsG: (targetKcal * macroSplit[0] / 4).roundToDouble(),
    proteinG: (targetKcal * macroSplit[1] / 4).roundToDouble(),
    fatG: (targetKcal * macroSplit[2] / 9).roundToDouble(),
  );
}

/// Roll a day's entries into the figures the dashboard and diary show.
DaySummary summariseDay(List<Entry> entries, int targetKcal) {
  var eaten = 0;
  var carbs = 0.0;
  var protein = 0.0;
  var fat = 0.0;
  final byCategory = <String, int>{for (final c in categories) c: 0};

  for (final e in entries) {
    eaten += e.kcal;
    carbs += e.carbsG;
    protein += e.proteinG;
    fat += e.fatG;
    byCategory[e.category] = (byCategory[e.category] ?? 0) + e.kcal;
  }

  return DaySummary(
    eaten: eaten,
    target: targetKcal,
    // Allowed to go negative. Clamping at zero would hide an overshoot, which
    // is the one figure the user needs in order to decide what to do next.
    remaining: targetKcal - eaten,
    over: eaten > targetKcal,
    percent: targetKcal == 0 ? 0 : ((eaten / targetKcal) * 100).round().clamp(0, 100),
    macros: Nutrition(
      kcal: eaten,
      carbsG: _round1(carbs),
      proteinG: _round1(protein),
      fatG: _round1(fat),
    ),
    macroTargets: macroTargets(targetKcal),
    byCategory: byCategory,
    allowances: splitTarget(targetKcal),
    entryCount: entries.length,
  );
}

/// Calories still available for one meal. Never negative: "minus 40 left for
/// lunch" is not useful, unlike the day total where the overshoot matters.
int remainingForMeal(DaySummary summary, String category) {
  final allowance = summary.allowances[category] ?? 0;
  final used = summary.byCategory[category] ?? 0;
  final left = allowance - used;
  return left < 0 ? 0 : left;
}

// ---------------------------------------------------------------------------
// Recommendation filtering and retrieval
// ---------------------------------------------------------------------------

/// True when a recipe lists none of the user's recorded allergens.
///
/// A hard exclusion applied before any ranking. A recipe that fails is removed
/// from the pool, never merely pushed down the list.
bool isSafeFor(Recipe recipe, List<String> allergens) {
  final recorded = allergens.map((a) => a.toLowerCase()).toSet();
  final listed = recipe.allergens.map((a) => a.toLowerCase()).toSet();
  return recorded.intersection(listed).isEmpty;
}

/// True when a recipe fits the chosen diet type.
bool matchesDiet(Recipe recipe, String? dietType) {
  if (dietType == null || dietType.isEmpty || dietType == 'balanced') return true;
  return recipe.dietTypes.contains(dietType);
}

/// Rank a safe recipe. Higher is better.
///
/// Two factors only: how close it lands to the calories left for the meal, and
/// whether it was suggested recently. More factors would make the ranking
/// harder to explain than it is useful.
double scoreRecipe(Recipe recipe, int slotTargetKcal, Set<String> recentIds) {
  double fit;
  if (slotTargetKcal <= 0) {
    fit = 0.0;
  } else {
    final miss = (recipe.kcal - slotTargetKcal).abs() / slotTargetKcal;
    fit = (1.0 - miss).clamp(0.0, 1.0);
  }
  final variety = recentIds.contains(recipe.id) ? 0.0 : 1.0;
  return (fit * 0.7) + (variety * 0.3);
}

/// Filter, then rank, then take the top few.
///
/// Order matters: unsafe recipes are dropped first, so someone with a peanut
/// allergy cannot be shown a peanut dish however well it fits their calories.
List<Recipe> recommend(
  List<Recipe> recipes,
  List<String> allergens,
  String dietType,
  int slotTargetKcal, {
  Set<String> recentIds = const {},
  int limit = shownExpanded,
}) {
  final safe = recipes.where((r) => isSafeFor(r, allergens)).toList();
  final onDiet = safe.where((r) => matchesDiet(r, dietType)).toList();
  // Fall back to everything safe rather than returning nothing.
  final pool = onDiet.isNotEmpty ? onDiet : safe;

  pool.sort((a, b) => scoreRecipe(b, slotTargetKcal, recentIds)
      .compareTo(scoreRecipe(a, slotTargetKcal, recentIds)));

  return pool.take(limit).toList();
}
