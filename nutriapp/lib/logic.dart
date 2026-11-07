/// Business rules for the Diary and Recommendations module.
///
/// A direct port of the backend's logic.py. These run on the device because
/// the diary has to work without a connection, so the calculations cannot sit
/// behind an API call.
///
/// Pure functions only: no database, no HTTP, no Flutter imports. That keeps
/// them testable without a device (see test/logic_test.dart) and makes it
/// obvious that nothing here can block on I/O.
library;

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

/// Days of history the Insights screen summarises.
const int insightsWindowDays = 7;

/// How far from the target a day still counts as having hit it.
const double onTargetTolerance = 0.10;

class CategoryWindow {
  final String name;
  final int startHour;
  final int endHour;
  const CategoryWindow(this.name, this.startHour, this.endHour);
}

// ---------------------------------------------------------------------------
// Goals: turning a profile into a calorie target
// ---------------------------------------------------------------------------

/// Multiplier applied to resting burn for each activity level.
///
/// Keyed by the label the onboarding dropdown offers, so there is one spelling
/// of each level in the codebase rather than a UI set and a logic set that can
/// drift apart.
const Map<String, double> activityMultipliers = {
  'Sedentary': 1.20,
  'Lightly Active': 1.375,
  'Moderately Active': 1.55,
  'Very Active': 1.725,
};

const double defaultActivityMultiplier = 1.55;

/// Daily calorie change each goal implies.
///
/// A 500 kcal deficit is about 0.45 kg a week, the rate normally considered
/// sustainable. Surpluses are smaller because excess beyond roughly 300-400
/// kcal tends to be stored as fat rather than used for muscle.
const Map<String, int> goalAdjustments = {
  'Lose Weight': -500,
  'Maintain Weight': 0,
  'Gain Weight': 400,
  'Build Muscle': 300,
  'Eat Healthier': 0,
};

/// Macro shares per goal, as carbohydrate / protein / fat.
///
/// Protein rises for muscle gain and for weight loss, where it protects lean
/// mass. Anything not listed uses the default split.
const Map<String, List<double>> goalMacroSplits = {
  'Build Muscle': [0.40, 0.35, 0.25],
  'Lose Weight': [0.35, 0.35, 0.30],
  'Gain Weight': [0.50, 0.25, 0.25],
};

/// Bounds on a generated target. The floor exists because the formula can
/// produce an unsafely low number for a small, sedentary person on a deficit.
const int minDailyTarget = 1200;
const int maxDailyTarget = 4500;

/// Resting energy expenditure, by Mifflin-St Jeor.
///
/// Chosen over Harris-Benedict because it is the more accurate of the two for
/// contemporary populations. The equation is defined for male and female only;
/// anyone who did not state a sex, or stated something else, gets the midpoint
/// of the two constants rather than being pushed into one of them.
int basalMetabolicRate({
  required int age,
  required double heightCm,
  required double weightKg,
  String? gender,
}) {
  final base = (10 * weightKg) + (6.25 * heightCm) - (5 * age);
  final constant = switch (gender) {
    'Male' => 5.0,
    'Female' => -161.0,
    _ => -78.0,
  };
  final bmr = base + constant;
  return bmr < 0 ? 0 : bmr.round();
}

/// The daily calorie target implied by a profile's measurements and goal.
///
/// Resting burn, scaled for activity, then adjusted for the goal. The result is
/// never below resting burn: a deficit that takes someone under what their body
/// uses at rest is the one outcome this must not produce, however the numbers
/// come out.
int dailyTargetFor({
  required int age,
  required double heightCm,
  required double weightKg,
  required String activityLevel,
  required String goal,
  String? gender,
}) {
  final bmr = basalMetabolicRate(
      age: age, heightCm: heightCm, weightKg: weightKg, gender: gender);
  final multiplier =
      activityMultipliers[activityLevel] ?? defaultActivityMultiplier;
  final maintenance = bmr * multiplier;
  final adjusted = maintenance + (goalAdjustments[goal] ?? 0);

  final floor = bmr > minDailyTarget ? bmr : minDailyTarget;
  final clamped = adjusted < floor
      ? floor
      : (adjusted > maxDailyTarget ? maxDailyTarget : adjusted.round());

  // Rounded to ten, because a target presented as 1,847 implies a precision
  // the estimate does not have.
  return (clamped / 10).round() * 10;
}

/// Macro shares for a goal, falling back to the default split.
List<double> macroSplitFor(String goal) => goalMacroSplits[goal] ?? macroSplit;

// ---------------------------------------------------------------------------
// Translating what onboarding collects into what the recipe data uses
// ---------------------------------------------------------------------------

/// Onboarding chip label to the allergen token recipes are tagged with.
///
/// The two vocabularies are not the same: the screen says "Dairy" because that
/// is what people call it, the data says "milk" because that is the allergen.
/// Without this map the comparison in [isSafeFor] silently finds nothing, and
/// someone who declared a dairy allergy is shown cheese.
const Map<String, String> allergenTokens = {
  'Peanuts': 'peanut',
  'Tree Nuts': 'nuts',
  'Dairy': 'milk',
  'Eggs': 'egg',
  'Gluten': 'gluten',
  'Soy': 'soy',
  'Fish': 'fish',
  'Shellfish': 'shellfish',
  'Sesame': 'sesame',
};

/// Onboarding preference label to the diet token recipes are tagged with.
const Map<String, String> dietTokens = {
  'Vegetarian': 'vegetarian',
  'Vegan': 'vegan',
  'Pescatarian': 'pescatarian',
  'Halal': 'halal',
  'High protein': 'high-protein',
  'High fibre': 'high-fibre',
  'Low carb': 'low-carb',
};

/// Which preference is used to ask the backend for meals.
///
/// The request takes one diet type, so a list has to be narrowed to one. The
/// most restrictive wins, because a vegan who also wants high protein is
/// poorly served by a chicken breast, while the reverse costs only variety.
const List<String> dietPrecedence = [
  'vegan',
  'vegetarian',
  'pescatarian',
  'halal',
  'high-protein',
  'high-fibre',
  'low-carb',
];

/// Allergen tokens for a set of chosen restriction labels.
///
/// Unknown labels are lowercased and passed through rather than dropped, so a
/// restriction added to the screen later still reaches the filter.
List<String> normaliseAllergens(List<String> restrictions) {
  final out = <String>{};
  for (final label in restrictions) {
    final token = allergenTokens[label] ?? label.trim().toLowerCase();
    if (token.isNotEmpty) out.add(token);
  }
  final list = out.toList()..sort();
  return list;
}

/// Diet tokens for a set of chosen preference labels.
List<String> normalisePreferences(List<String> preferences) {
  final out = <String>{};
  for (final label in preferences) {
    final token = dietTokens[label] ?? label.trim().toLowerCase();
    if (token.isNotEmpty) out.add(token);
  }
  final list = out.toList()..sort();
  return list;
}

/// The single diet type to request meals for, from a list of preferences.
String primaryDietType(List<String> preferences) {
  final tokens = normalisePreferences(preferences).toSet();
  for (final candidate in dietPrecedence) {
    if (tokens.contains(candidate)) return candidate;
  }
  return 'balanced';
}

/// Assemble a stored profile from what the onboarding screens collected.
///
/// The one place raw answers become the normalised values the rest of the app
/// reads, so a screen can never filter on an untranslated label.
UserProfile buildProfile({
  required String name,
  required String email,
  required int age,
  required double heightCm,
  required double weightKg,
  required String activityLevel,
  required String goal,
  String? gender,
  double? targetWeightKg,
  List<String> preferences = const [],
  List<String> restrictions = const [],
  int? manualTargetKcal,
  DateTime? updatedAt,
}) {
  final computed = dailyTargetFor(
    age: age,
    heightCm: heightCm,
    weightKg: weightKg,
    activityLevel: activityLevel,
    goal: goal,
    gender: gender,
  );
  return UserProfile(
    name: name,
    email: email,
    age: age,
    gender: gender,
    heightCm: heightCm,
    weightKg: weightKg,
    activityLevel: activityLevel,
    goal: goal,
    targetWeightKg: targetWeightKg,
    preferences: List<String>.of(preferences),
    restrictions: List<String>.of(restrictions),
    allergens: normaliseAllergens(restrictions),
    dietTypes: normalisePreferences(preferences),
    dietType: primaryDietType(preferences),
    computedTargetKcal: computed,
    targetKcal: manualTargetKcal ?? computed,
    targetIsManual: manualTargetKcal != null,
    updatedAt: updatedAt ?? DateTime.now().toUtc(),
  );
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
///
/// The split varies by goal, so it is a parameter rather than a constant read
/// from inside.
Nutrition macroTargets(int targetKcal, {List<double>? split}) {
  final s = split ?? macroSplit;
  return Nutrition(
    kcal: targetKcal,
    carbsG: (targetKcal * s[0] / 4).roundToDouble(),
    proteinG: (targetKcal * s[1] / 4).roundToDouble(),
    fatG: (targetKcal * s[2] / 9).roundToDouble(),
  );
}

/// Roll a day's entries into the figures the dashboard and diary show.
DaySummary summariseDay(List<Entry> entries, int targetKcal,
    {List<double>? split}) {
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
    macroTargets: macroTargets(targetKcal, split: split),
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

// ---------------------------------------------------------------------------
// Insights: summarising a run of days
// ---------------------------------------------------------------------------

/// Calendar day as a sortable key. The same spelling the database stores, so a
/// comparison between a query result and a computed key cannot disagree.
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// One row per day across a window, oldest first.
///
/// Days with nothing logged are present with zero totals rather than absent.
/// A chart that skips them would show an unbroken run of good days to someone
/// who simply stopped recording, which is the opposite of the truth.
List<DayTotal> dailyTotals(
  List<Entry> entries, {
  required DateTime endDay,
  int days = insightsWindowDays,
}) {
  final buckets = <String, DayTotal>{};
  final ordered = <DayTotal>[];

  for (var i = days - 1; i >= 0; i--) {
    final day = DateTime(endDay.year, endDay.month, endDay.day)
        .subtract(Duration(days: i));
    final row = DayTotal(day: day);
    buckets[dayKey(day)] = row;
    ordered.add(row);
  }

  for (final e in entries) {
    if (e.deleted) continue;
    final row = buckets[dayKey(e.eatenAt)];
    if (row == null) continue; // outside the window
    row.kcal += e.kcal;
    row.carbsG += e.carbsG;
    row.proteinG += e.proteinG;
    row.fatG += e.fatG;
    row.entryCount += 1;
    row.byCategory[e.category] = (row.byCategory[e.category] ?? 0) + e.kcal;
  }

  return ordered;
}

/// Consecutive days with at least one entry, counting back from the last day.
///
/// Today is allowed to be empty without breaking the run: a streak that
/// collapses at breakfast every morning would be useless.
int loggingStreak(List<DayTotal> totals) {
  if (totals.isEmpty) return 0;
  var streak = 0;
  var index = totals.length - 1;

  if (totals[index].entryCount == 0) {
    index -= 1; // today not logged yet; start from yesterday
  }
  while (index >= 0 && totals[index].entryCount > 0) {
    streak += 1;
    index -= 1;
  }
  return streak;
}

/// Averages and adherence across a window.
///
/// The average is taken over days that were actually logged, not over the whole
/// window. Dividing by seven when only three days were recorded reports an
/// intake of roughly half what the person ate, which would make every summary
/// look like a deficit.
TrendSummary summariseTrend(List<DayTotal> totals, int targetKcal) {
  final logged = totals.where((d) => d.entryCount > 0).toList();
  final tolerance = targetKcal * onTargetTolerance;

  var kcal = 0;
  var carbs = 0.0;
  var protein = 0.0;
  var fat = 0.0;
  var onTarget = 0;
  var over = 0;
  var under = 0;

  for (final d in logged) {
    kcal += d.kcal;
    carbs += d.carbsG;
    protein += d.proteinG;
    fat += d.fatG;
    if ((d.kcal - targetKcal).abs() <= tolerance) {
      onTarget += 1;
    } else if (d.kcal > targetKcal) {
      over += 1;
    } else {
      under += 1;
    }
  }

  final n = logged.length;
  return TrendSummary(
    days: totals.length,
    daysLogged: n,
    target: targetKcal,
    averageKcal: n == 0 ? 0 : (kcal / n).round(),
    averageMacros: Nutrition(
      kcal: n == 0 ? 0 : (kcal / n).round(),
      carbsG: n == 0 ? 0 : _round1(carbs / n),
      proteinG: n == 0 ? 0 : _round1(protein / n),
      fatG: n == 0 ? 0 : _round1(fat / n),
    ),
    macroTargets: macroTargets(targetKcal),
    daysOnTarget: onTarget,
    daysOver: over,
    daysUnder: under,
    streak: loggingStreak(totals),
    highest: logged.isEmpty
        ? 0
        : logged.map((d) => d.kcal).reduce((a, b) => a > b ? a : b),
    lowest: logged.isEmpty
        ? 0
        : logged.map((d) => d.kcal).reduce((a, b) => a < b ? a : b),
  );
}

/// Calories per meal across a window, for the breakdown on Insights.
Map<String, int> categoryTotals(List<DayTotal> totals) {
  final out = <String, int>{for (final c in categories) c: 0};
  for (final d in totals) {
    d.byCategory.forEach((category, kcal) {
      out[category] = (out[category] ?? 0) + kcal;
    });
  }
  return out;
}

/// Change in weight between the first and last recorded measurement.
///
/// Returns null rather than zero when there is nothing to compare, so the
/// screen can say "log a second weight" instead of claiming no change.
double? weightChange(List<WeightEntry> log) {
  final live = log.where((w) => !w.deleted).toList()
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  if (live.length < 2) return null;
  return _round1(live.last.kg - live.first.kg);
}

/// How far a weight log has moved towards its target, as a percentage.
///
/// Null when there is no target, fewer than two measurements, or the starting
/// weight already met the target, since a share of zero progress needed is not
/// a meaningful number.
int? progressTowardsTarget(List<WeightEntry> log, double? targetKg) {
  if (targetKg == null) return null;
  final live = log.where((w) => !w.deleted).toList()
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  if (live.length < 2) return null;

  final start = live.first.kg;
  final current = live.last.kg;
  final needed = targetKg - start;
  if (needed.abs() < 0.1) return null;

  final done = current - start;
  final percent = (done / needed * 100).round();
  return percent < 0 ? 0 : (percent > 100 ? 100 : percent);
}
