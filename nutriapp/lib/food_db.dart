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
  /// rather than kept forever. Compared against a marker row in the user
  /// database, because this file itself is read-only.
  static const int datasetVersion = 1;

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

    // An asset cannot be opened in place, so it is copied out once. The file
    // is only written when absent: copying on every launch would waste a
    // second of startup and churn the device's storage for no reason.
    if (!await databaseExists(path)) {
      await _copyFromAsset(path);
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
