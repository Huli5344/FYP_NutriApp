/// Plain data classes. No framework imports, so logic.dart and the tests can
/// use them without pulling in Flutter.

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

class Food {
  final int id;
  final String name;
  final String? brand;
  final String serving;
  final Nutrition perServing;

  const Food({
    required this.id,
    required this.name,
    this.brand,
    required this.serving,
    required this.perServing,
  });

  factory Food.fromRow(Map<String, Object?> row) => Food(
        id: row['id'] as int,
        name: row['name'] as String,
        brand: row['brand'] as String?,
        serving: row['serving'] as String,
        perServing: Nutrition(
          kcal: (row['kcal'] as num).round(),
          carbsG: (row['carbs_g'] as num).toDouble(),
          proteinG: (row['protein_g'] as num).toDouble(),
          fatG: (row['fat_g'] as num).toDouble(),
        ),
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
  final int? foodId;
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
        foodId: row['food_id'] as int?,
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

/// The demo profile. Comes from the Accounts and Goals modules in the full
/// product; fixed here so the dashboard has something to measure against.
class Profile {
  static const String name = 'Sara Tan';
  static const int dailyTarget = 1850;
  static const String dietType = 'balanced';
  static const List<String> allergens = ['peanut', 'shellfish'];
}
