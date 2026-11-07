/// Plain data classes. No framework imports, so logic.dart and the tests can
/// use them without pulling in Flutter.
library;

class Nutrition {
  final int kcal;
  final double carbsG;
  final double proteinG;
  final double fatG;

  const Nutrition({
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
  });

  static const zero = Nutrition(kcal: 0, carbsG: 0, proteinG: 0, fatG: 0);
}

/// One food from the Health Promotion Board dataset.
///
/// `perServing` is HPB's own per-serving column, not a figure derived here.
/// Their per-100 column is per 100 g of *edible* portion while the serving
/// weight is as purchased and includes shell and bone, so multiplying the two
/// overstates anything with an edible portion below 100% -- by eight times on
/// crayfish. HPB has already done that arithmetic correctly.
///
/// `suppressed` names nutrients whose published figure contradicts itself for
/// this food, such as a trans fat larger than the total fat. The interface
/// must not display those, and does not: the food database strips them before
/// a Food is built.
class Food {
  /// HPB's own id, such as "F05020050". A string, not an integer: it is stable
  /// across re-imports of the dataset, which a row number would not be.
  final String id;
  final String name;
  final String? foodGroup;

  /// As published, for example "1 plate(s) = 480g".
  final String serving;
  final Nutrition perServing;

  /// True when the default serving is a shopping quantity rather than a meal
  /// -- a whole roast turkey is 4,243 kcal. The interface warns rather than
  /// logging that from one tap.
  final bool bulkServing;

  final List<String> suppressed;

  const Food({
    required this.id,
    required this.name,
    this.foodGroup,
    required this.serving,
    required this.perServing,
    this.bulkServing = false,
    this.suppressed = const [],
  });

  factory Food.fromRow(Map<String, Object?> row) => Food(
        id: '${row['food_id']}',
        name: row['name'] as String,
        foodGroup: row['food_group'] as String?,
        serving: (row['serving_label'] as String?) ?? '1 serving',
        perServing: Nutrition(
          // Energy is populated for every one of the 2,692 rows. The optional
          // nutrients are not, so they are read defensively; a missing value
          // means "never measured", which is not the same as zero, but a
          // diary entry needs a number and zero is the only honest one to
          // total with.
          kcal: (row['energy_kcal'] as num?)?.round() ?? 0,
          carbsG: (row['carbohydrate_g'] as num?)?.toDouble() ?? 0,
          proteinG: (row['protein_g'] as num?)?.toDouble() ?? 0,
          fatG: (row['total_fat_g'] as num?)?.toDouble() ?? 0,
        ),
        bulkServing: ((row['bulk_serving'] as num?) ?? 0) != 0,
        suppressed: ((row['suppress_nutrients'] as String?) ?? '')
            .split(',')
            .where((n) => n.isNotEmpty)
            .toList(),
      );
}

/// One diary entry.
///
/// The id is a UUID generated on this device, not an autoincrementing integer:
/// two devices offline at once would both create entry 1 and the server could
/// not tell them apart.
///
/// `updatedAt`, `deleted` and `dirty` are the sync bookkeeping. `dirty` is the
/// one field the server never sees; it exists only so the device knows what it
/// still owes.
class Entry {
  final String id;

  /// The HPB food this came from, or null for a recommendation or a food that
  /// no longer exists. Provenance only: the entry stores its own copy of the
  /// nutrition, so a later correction to the food table never rewrites what
  /// somebody ate last week.
  final String? foodId;
  final String foodName;
  final double quantity;
  final String serving;
  final int kcal;
  final double carbsG;
  final double proteinG;
  final double fatG;
  final String category;
  final List<String> tags;
  final String note;
  final DateTime eatenAt;
  final String source;
  final bool deleted;
  final DateTime updatedAt;
  final bool dirty;

  const Entry({
    required this.id,
    this.foodId,
    required this.foodName,
    required this.quantity,
    required this.serving,
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    required this.category,
    required this.tags,
    this.note = '',
    required this.eatenAt,
    this.source = 'manual',
    this.deleted = false,
    required this.updatedAt,
    this.dirty = true,
  });

  Nutrition get nutrition =>
      Nutrition(kcal: kcal, carbsG: carbsG, proteinG: proteinG, fatG: fatG);

  Entry copyWith({
    double? quantity,
    int? kcal,
    double? carbsG,
    double? proteinG,
    double? fatG,
    String? category,
    List<String>? tags,
    String? note,
    DateTime? eatenAt,
    bool? deleted,
    DateTime? updatedAt,
    bool? dirty,
  }) =>
      Entry(
        id: id,
        foodId: foodId,
        foodName: foodName,
        quantity: quantity ?? this.quantity,
        serving: serving,
        kcal: kcal ?? this.kcal,
        carbsG: carbsG ?? this.carbsG,
        proteinG: proteinG ?? this.proteinG,
        fatG: fatG ?? this.fatG,
        category: category ?? this.category,
        tags: tags ?? this.tags,
        note: note ?? this.note,
        eatenAt: eatenAt ?? this.eatenAt,
        source: source,
        deleted: deleted ?? this.deleted,
        updatedAt: updatedAt ?? this.updatedAt,
        dirty: dirty ?? this.dirty,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'food_id': foodId,
        'food_name': foodName,
        'quantity': quantity,
        'serving': serving,
        'kcal': kcal,
        'carbs_g': carbsG,
        'protein_g': proteinG,
        'fat_g': fatG,
        'category': category,
        'tags': tags.join(','),
        'note': note,
        'eaten_at': eatenAt.toIso8601String(),
        'source': source,
        'deleted': deleted ? 1 : 0,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'dirty': dirty ? 1 : 0,
      };

  /// The shape the /sync endpoint expects. `dirty` is deliberately absent.
  Map<String, Object?> toSyncJson() {
    final row = toRow();
    row.remove('dirty');
    return row;
  }

  factory Entry.fromRow(Map<String, Object?> row) => Entry(
        id: row['id'] as String,
        // Read as a string rather than cast, because a device upgraded from
        // schema 2 may still hold an integer here from the old food table.
        // `as String?` on an int throws, and would take the diary down.
        foodId: row['food_id']?.toString(),
        foodName: row['food_name'] as String,
        quantity: (row['quantity'] as num).toDouble(),
        serving: (row['serving'] as String?) ?? '',
        kcal: (row['kcal'] as num).round(),
        carbsG: (row['carbs_g'] as num).toDouble(),
        proteinG: (row['protein_g'] as num).toDouble(),
        fatG: (row['fat_g'] as num).toDouble(),
        category: row['category'] as String,
        tags: ((row['tags'] as String?) ?? '')
            .split(',')
            .where((t) => t.isNotEmpty)
            .toList(),
        note: (row['note'] as String?) ?? '',
        eatenAt: DateTime.parse(row['eaten_at'] as String),
        source: (row['source'] as String?) ?? 'manual',
        deleted: ((row['deleted'] as num?) ?? 0) != 0,
        updatedAt: DateTime.parse(row['updated_at'] as String),
        dirty: ((row['dirty'] as num?) ?? 0) != 0,
      );
}

class Recipe {
  final String id;
  final String name;
  final int kcal;
  final double carbsG;
  final double proteinG;
  final double fatG;
  final int? minutes;
  final List<String> allergens;
  final List<String> dietTypes;
  final List<String> ingredients;
  final String? area;
  final bool estimated;
  final String source;

  const Recipe({
    required this.id,
    required this.name,
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    this.minutes,
    this.allergens = const [],
    this.dietTypes = const [],
    this.ingredients = const [],
    this.area,
    this.estimated = false,
    this.source = 'local',
  });

  factory Recipe.fromRow(Map<String, Object?> row) => Recipe(
        id: 'local-${row['id']}',
        name: row['name'] as String,
        kcal: (row['kcal'] as num).round(),
        carbsG: (row['carbs_g'] as num).toDouble(),
        proteinG: (row['protein_g'] as num).toDouble(),
        fatG: (row['fat_g'] as num).toDouble(),
        minutes: (row['minutes'] as num?)?.round(),
        allergens: _split(row['allergens'] as String?, ','),
        dietTypes: _split(row['diet_types'] as String?, ','),
        ingredients: _split(row['ingredients'] as String?, '|'),
      );

  /// A meal from the backend, which has already derived allergens and
  /// estimated the nutrition from the ingredient list.
  factory Recipe.fromApi(Map<String, dynamic> json) => Recipe(
        id: json['id'] as String,
        name: json['name'] as String,
        kcal: (json['kcal'] as num).round(),
        carbsG: (json['carbs_g'] as num).toDouble(),
        proteinG: (json['protein_g'] as num).toDouble(),
        fatG: (json['fat_g'] as num).toDouble(),
        minutes: (json['minutes'] as num?)?.round(),
        allergens: (json['allergens'] as List?)?.cast<String>() ?? const [],
        dietTypes: (json['diet_types'] as List?)?.cast<String>() ?? const [],
        ingredients: (json['ingredients'] as List?)?.cast<String>() ?? const [],
        area: json['area'] as String?,
        estimated: (json['estimated'] as bool?) ?? true,
        source: (json['source'] as String?) ?? 'themealdb',
      );

  static List<String> _split(String? value, String separator) =>
      (value ?? '').split(separator).where((v) => v.isNotEmpty).toList();
}

class DaySummary {
  final int eaten;
  final int target;
  final int remaining;
  final bool over;
  final int percent;
  final Nutrition macros;
  final Nutrition macroTargets;
  final Map<String, int> byCategory;
  final Map<String, int> allowances;
  final int entryCount;

  const DaySummary({
    required this.eaten,
    required this.target,
    required this.remaining,
    required this.over,
    required this.percent,
    required this.macros,
    required this.macroTargets,
    required this.byCategory,
    required this.allowances,
    required this.entryCount,
  });
}

/// What the user told the app about themselves, and the goal derived from it.
///
/// Stored rather than computed on demand. The raw onboarding answers are kept
/// alongside the normalised tokens: the answers are what the edit screen has to
/// show back, the tokens are what the recipe filter compares against, and
/// keeping both means a screen can never accidentally filter on a label.
///
/// `targetKcal` is the figure the whole app measures against. It is written
/// here rather than recalculated at every read so that a target someone set by
/// hand survives, and so a stored target can be inspected rather than inferred.
class UserProfile {
  final String name;
  final String email;
  final int age;
  final String? gender;
  final double heightCm;
  final double weightKg;
  final String activityLevel;
  final String goal;
  final double? targetWeightKg;

  /// Onboarding answers, exactly as chosen.
  final List<String> preferences;
  final List<String> restrictions;

  /// The same answers translated into the vocabulary the recipe data uses.
  final List<String> allergens;
  final List<String> dietTypes;
  final String dietType;

  /// What the formula produced, kept even when overridden, so the profile
  /// screen can show both and explain the difference.
  final int computedTargetKcal;
  final int targetKcal;
  final bool targetIsManual;

  final DateTime updatedAt;

  const UserProfile({
    required this.name,
    required this.email,
    required this.age,
    this.gender,
    required this.heightCm,
    required this.weightKg,
    required this.activityLevel,
    required this.goal,
    this.targetWeightKg,
    this.preferences = const [],
    this.restrictions = const [],
    this.allergens = const [],
    this.dietTypes = const [],
    this.dietType = 'balanced',
    required this.computedTargetKcal,
    required this.targetKcal,
    this.targetIsManual = false,
    required this.updatedAt,
  });

  /// Used only when a screen is reached without a stored profile, which the
  /// sign-in gate should prevent. Deliberately unflattering numbers: if this
  /// ever shows up on screen it should be obvious that something was skipped.
  static final UserProfile fallback = UserProfile(
    name: 'Guest',
    email: '',
    age: 30,
    gender: null,
    heightCm: 170,
    weightKg: 70,
    activityLevel: 'Moderately Active',
    goal: 'Eat Healthier',
    computedTargetKcal: 2000,
    targetKcal: 2000,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  UserProfile copyWith({
    String? name,
    String? email,
    int? age,
    String? gender,
    bool clearGender = false,
    double? heightCm,
    double? weightKg,
    String? activityLevel,
    String? goal,
    double? targetWeightKg,
    bool clearTargetWeight = false,
    List<String>? preferences,
    List<String>? restrictions,
    List<String>? allergens,
    List<String>? dietTypes,
    String? dietType,
    int? computedTargetKcal,
    int? targetKcal,
    bool? targetIsManual,
    DateTime? updatedAt,
  }) =>
      UserProfile(
        name: name ?? this.name,
        email: email ?? this.email,
        age: age ?? this.age,
        gender: clearGender ? null : (gender ?? this.gender),
        heightCm: heightCm ?? this.heightCm,
        weightKg: weightKg ?? this.weightKg,
        activityLevel: activityLevel ?? this.activityLevel,
        goal: goal ?? this.goal,
        targetWeightKg:
            clearTargetWeight ? null : (targetWeightKg ?? this.targetWeightKg),
        preferences: preferences ?? this.preferences,
        restrictions: restrictions ?? this.restrictions,
        allergens: allergens ?? this.allergens,
        dietTypes: dietTypes ?? this.dietTypes,
        dietType: dietType ?? this.dietType,
        computedTargetKcal: computedTargetKcal ?? this.computedTargetKcal,
        targetKcal: targetKcal ?? this.targetKcal,
        targetIsManual: targetIsManual ?? this.targetIsManual,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// A single row, because there is one profile on a device. The fixed key
  /// means a save replaces rather than accumulates.
  static const String rowId = 'me';

  Map<String, Object?> toRow() => {
        'id': rowId,
        'name': name,
        'email': email,
        'age': age,
        'gender': gender,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'activity_level': activityLevel,
        'goal': goal,
        'target_weight_kg': targetWeightKg,
        'preferences': preferences.join(','),
        'restrictions': restrictions.join(','),
        'allergens': allergens.join(','),
        'diet_types': dietTypes.join(','),
        'diet_type': dietType,
        'computed_target_kcal': computedTargetKcal,
        'target_kcal': targetKcal,
        'target_is_manual': targetIsManual ? 1 : 0,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  Map<String, Object?> toSyncJson() => toRow();

  factory UserProfile.fromRow(Map<String, Object?> row) => UserProfile(
        name: (row['name'] as String?) ?? 'Guest',
        email: (row['email'] as String?) ?? '',
        age: (row['age'] as num?)?.round() ?? 30,
        gender: row['gender'] as String?,
        heightCm: (row['height_cm'] as num?)?.toDouble() ?? 170,
        weightKg: (row['weight_kg'] as num?)?.toDouble() ?? 70,
        activityLevel:
            (row['activity_level'] as String?) ?? 'Moderately Active',
        goal: (row['goal'] as String?) ?? 'Eat Healthier',
        targetWeightKg: (row['target_weight_kg'] as num?)?.toDouble(),
        preferences: _csv(row['preferences']),
        restrictions: _csv(row['restrictions']),
        allergens: _csv(row['allergens']),
        dietTypes: _csv(row['diet_types']),
        dietType: (row['diet_type'] as String?) ?? 'balanced',
        computedTargetKcal:
            (row['computed_target_kcal'] as num?)?.round() ?? 2000,
        targetKcal: (row['target_kcal'] as num?)?.round() ?? 2000,
        targetIsManual: ((row['target_is_manual'] as num?) ?? 0) != 0,
        updatedAt: DateTime.tryParse('${row['updated_at']}')?.toUtc() ??
            DateTime.now().toUtc(),
      );

  static List<String> _csv(Object? value) => '${value ?? ''}'
      .split(',')
      .map((v) => v.trim())
      .where((v) => v.isNotEmpty)
      .toList();
}

/// One recorded weight.
///
/// Carries the same sync bookkeeping as a diary entry, for the same reasons:
/// a client-generated id so two devices cannot collide, a tombstone so a
/// deletion is not undone by the next pull.
class WeightEntry {
  final String id;
  final double kg;
  final DateTime recordedAt;
  final String note;
  final bool deleted;
  final DateTime updatedAt;
  final bool dirty;

  const WeightEntry({
    required this.id,
    required this.kg,
    required this.recordedAt,
    this.note = '',
    this.deleted = false,
    required this.updatedAt,
    this.dirty = true,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'kg': kg,
        'recorded_at': recordedAt.toIso8601String(),
        'note': note,
        'deleted': deleted ? 1 : 0,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'dirty': dirty ? 1 : 0,
      };

  Map<String, Object?> toSyncJson() {
    final row = toRow();
    row.remove('dirty');
    return row;
  }

  factory WeightEntry.fromRow(Map<String, Object?> row) => WeightEntry(
        id: row['id'] as String,
        kg: (row['kg'] as num).toDouble(),
        recordedAt: DateTime.parse(row['recorded_at'] as String),
        note: (row['note'] as String?) ?? '',
        deleted: ((row['deleted'] as num?) ?? 0) != 0,
        updatedAt: DateTime.parse(row['updated_at'] as String),
        dirty: ((row['dirty'] as num?) ?? 0) != 0,
      );
}

/// Totals for one calendar day. Mutable because [dailyTotals] fills a
/// pre-built run of days in a single pass over the entries.
class DayTotal {
  final DateTime day;
  int kcal;
  double carbsG;
  double proteinG;
  double fatG;
  int entryCount;
  final Map<String, int> byCategory;

  DayTotal({
    required this.day,
    this.kcal = 0,
    this.carbsG = 0,
    this.proteinG = 0,
    this.fatG = 0,
    this.entryCount = 0,
    Map<String, int>? byCategory,
  }) : byCategory = byCategory ?? <String, int>{};
}

/// What the Insights screen shows across a window of days.
class TrendSummary {
  final int days;
  final int daysLogged;
  final int target;
  final int averageKcal;
  final Nutrition averageMacros;
  final Nutrition macroTargets;
  final int daysOnTarget;
  final int daysOver;
  final int daysUnder;
  final int streak;
  final int highest;
  final int lowest;

  const TrendSummary({
    required this.days,
    required this.daysLogged,
    required this.target,
    required this.averageKcal,
    required this.averageMacros,
    required this.macroTargets,
    required this.daysOnTarget,
    required this.daysOver,
    required this.daysUnder,
    required this.streak,
    required this.highest,
    required this.lowest,
  });

  /// Share of logged days that landed within tolerance of the target.
  int get adherencePercent =>
      daysLogged == 0 ? 0 : ((daysOnTarget / daysLogged) * 100).round();
}
