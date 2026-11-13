/// The food table, read from a database bundled inside the app.
///
/// All 2,692 Health Promotion Board foods ship in the APK as `assets/foods.db`
/// -- about 1.2 MB -- and are copied to the device's database directory the
/// first time the app runs.
///
/// **Why it is not fetched from the server.** Recording a meal is the one
/// thing a food diary has to do without a connection, and searching for the
/// food is part of recording it. A search that went to the network would mean
/// no lunch logged on the train. The server holds the same table for its own
/// pages and for an initial download, but the app never depends on reaching
/// it to find a food.
///
/// The table is read-only here. Nothing in the app writes to it, so there is
/// no migration to run and no risk of a user's data living in the same file:
/// user data is in `nutriapp.db`, this is a separate database opened
/// alongside it.
library;

import 'dart:io' show Directory, File;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class FoodDb {
  static final FoodDb instance = FoodDb._();
  FoodDb._();

  static const String assetPath = 'assets/foods.db';
  static const String fileName = 'foods.db';

  /// Bumped when a new foods.db ships, so the copy on the device is replaced
  /// rather than kept forever.
  ///
  /// Version 2 added the allergens and diet_types columns, which is what lets
  /// a food appear as a suggestion without bypassing the allergen filter.
  ///
  /// This was declared from the start and never actually read: _open copied
  /// the asset only when no file existed, so an updated dataset reached new
  /// installs and nobody else. The marker below is what makes it real.
  static const int datasetVersion = 2;

  Database? _db;

  /// Columns a result list needs. The full row is 42 columns, most of them the
  /// per-100 figures and trace minerals only a detail view reads; selecting
  /// them for every row of every search is plain overfetch.
  static const String _listColumns =
      'food_id, name, food_group, serving_label, energy_kcal, '
      'carbohydrate_g, protein_g, total_fat_g, bulk_serving, '
      'suppress_nutrients';

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), fileName);

    // The version of the copy currently on the device, kept in a plain file
    // beside it. A file rather than a row, because this database is opened
    // read-only and reaching into the other one from here would make the two
    // import each other.
    final stamp = File('$path.version');
    var copied = 0;
    if (await databaseExists(path) && await stamp.exists()) {
      copied = int.tryParse((await stamp.readAsString()).trim()) ?? 0;
    }

    // An asset cannot be opened in place, so it is copied out. Only when it
    // is absent or stale: copying on every launch would cost a second of
    // startup and churn the device's storage for nothing.
    if (copied != datasetVersion) {
      if (await databaseExists(path)) {
        await deleteDatabase(path);
      }
      await _copyFromAsset(path);
      await stamp.writeAsString('$datasetVersion');
    }
    return openDatabase(path, readOnly: true);
  }

  Future<void> _copyFromAsset(String path) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
        data.offsetInBytes, data.lengthInBytes);
    // The parent directory may not exist on a first run.
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsBytes(bytes, flush: true);
  }

  /// Replace the copy on the device, for when a newer dataset ships.
  Future<void> refreshFromAsset() async {
    final path = p.join(await getDatabasesPath(), fileName);
    await _db?.close();
    _db = null;
    if (await databaseExists(path)) {
      await deleteDatabase(path);
    }
    await _copyFromAsset(path);
  }

  // ------------------------------------------------------------------ search

  /// `_` and `%` are wildcards to SQL's LIKE but ordinary characters to
  /// somebody typing in a search box. Left alone, "teh_" would quietly match
  /// "teh c", "teh o" and the rest. Escaped here, with the escape character
  /// itself escaped first so it cannot be used to smuggle one of the others
  /// back in.
  ///
  /// Written with escaped quotes rather than raw strings: a raw string ending
  /// in a backslash is the kind of thing that reads fine and lexes badly.
  static String _escapeLike(String text) => text
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  /// Foods whose name matches, best matches first.
  ///
  /// A name beginning with the query ranks above one merely containing it, so
  /// searching "rice" offers rice dishes before fried chicken with rice.
  Future<List<Food>> search(String query, {int limit = 30}) async {
    final db = await database;
    final text = query.trim().toLowerCase();

    if (text.isEmpty) {
      final rows = await db.rawQuery(
          'SELECT $_listColumns FROM foods ORDER BY name LIMIT ?', [limit]);
      return rows.map(Food.fromRow).toList();
    }

    final pattern = _escapeLike(text);
    final rows = await db.rawQuery(
        'SELECT $_listColumns FROM foods '
        "WHERE lower(name) LIKE ? ESCAPE '\\' "
        "ORDER BY CASE WHEN lower(name) LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END, "
        'name LIMIT ?',
        ['%$pattern%', '$pattern%', limit]);
    return rows.map(Food.fromRow).toList();
  }

  /// Foods offered as meal suggestions, shaped as recipes.
  ///
  /// Discover ranks and filters [Recipe]s, so foods arrive as recipes rather
  /// than as a second type threaded through the same pipeline. They carry
  /// `estimated: false`, because unlike a MealDB recipe their figures are
  /// published rather than worked out from an ingredient list, and
  /// `source: 'hpb'`, which the detail screen uses to describe where the
  /// allergen tags came from.
  ///
  /// The tags are the point. Without the allergens column every food would
  /// have an empty allergen list, and an empty list is indistinguishable
  /// from a safe one to `isSafeFor` -- so all 2,692 would pass every filter.
  ///
  /// Only a slice is returned. There are 2,692 foods against a few dozen
  /// recipes, so handing the ranker everything at once would bury the
  /// recipes entirely. Bulk servings are left out because a whole roast
  /// turkey is not a dinner suggestion.
  ///
  /// [offset] is what makes the Discover list endless. Rows come back
  /// ordered by distance from the calories left for this meal, so page one
  /// is the closest fits and each page after is a little further off -- the
  /// right order to run out in. Ordering by an expression rather than a
  /// column means SQLite sorts the whole table for each page; at 2,692 rows
  /// that is cheap, and the alternative is an index that would have to be
  /// rebuilt for every different target.
  Future<List<Recipe>> suggestions({
    required int targetKcal,
    int limit = 40,
    int offset = 0,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT food_id, name, food_group, energy_kcal, carbohydrate_g, '
      'protein_g, total_fat_g, allergens, diet_types FROM foods '
      'WHERE bulk_serving = 0 AND energy_kcal > 0 '
      'ORDER BY ABS(energy_kcal - ?), food_id LIMIT ? OFFSET ?',
      [targetKcal, limit, offset],
    );

    return [
      for (final row in rows)
        Recipe(
          id: 'hpb-${row['food_id']}',
          name: '${row['name']}',
          kcal: (row['energy_kcal'] as num).round(),
          carbsG: (row['carbohydrate_g'] as num?)?.toDouble() ?? 0,
          proteinG: (row['protein_g'] as num?)?.toDouble() ?? 0,
          fatG: (row['total_fat_g'] as num?)?.toDouble() ?? 0,
          allergens: _split(row['allergens']),
          dietTypes: _split(row['diet_types']),
          area: row['food_group'] as String?,
          estimated: false,
          source: 'hpb',
        ),
    ];
  }

  /// How many foods could ever be suggested, so the list knows when to stop
  /// asking for more.
  Future<int> suggestionCount() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) n FROM foods WHERE bulk_serving = 0 '
        'AND energy_kcal > 0');
    return (rows.first['n'] as int?) ?? 0;
  }

  static List<String> _split(Object? value) {
    final text = (value as String?) ?? '';
    return text.split(',').where((part) => part.isNotEmpty).toList();
  }

  Future<Food?> byId(String foodId) async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT $_listColumns FROM foods WHERE food_id = ? LIMIT 1',
        [foodId]);
    return rows.isEmpty ? null : Food.fromRow(rows.first);
  }

  /// Everything stored about one food, for a detail view.
  ///
  /// Returns the raw row with the contradictory nutrients removed, rather than
  /// a Food, because a detail view wants the columns a Food does not carry:
  /// sodium, fibre, the per-100 figures.
  Future<Map<String, Object?>?> detail(String foodId) async {
    final db = await database;
    final rows = await db
        .rawQuery('SELECT * FROM foods WHERE food_id = ? LIMIT 1', [foodId]);
    if (rows.isEmpty) return null;

    final row = Map<String, Object?>.from(rows.first);
    final hidden = ((row['suppress_nutrients'] as String?) ?? '')
        .split(',')
        .where((n) => n.isNotEmpty);
    // Applied here rather than in each widget, so no screen can show a figure
    // the import marked as contradicting itself.
    for (final nutrient in hidden) {
      row[nutrient] = null;
      row['per100_$nutrient'] = null;
    }
    return row;
  }

  Future<int> count() async {
    final db = await database;
    final row = await db.rawQuery('SELECT COUNT(*) AS c FROM foods');
    return (row.first['c'] as num).toInt();
  }
}
