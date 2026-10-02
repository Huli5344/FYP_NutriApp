/// On-device SQLite store.
///
/// This is the source of truth for the interface. Every screen reads and
/// writes here and never waits on the network; sync runs in the background and
/// updates the same tables. If a screen ever shows a spinner while waiting for
/// the server, the architecture has leaked.
///
/// The entries schema mirrors the backend's, with one extra column: `dirty`,
/// the device's own record of what it still owes the server.

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'logic.dart';
import 'models.dart';
import 'seed_data.dart';

class LocalDb {
  static final LocalDb instance = LocalDb._();
  LocalDb._();

  static const _uuid = Uuid();
  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'nutriapp.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE entries (
            id          TEXT PRIMARY KEY,
            food_id     INTEGER,
            food_name   TEXT NOT NULL,
            quantity    REAL NOT NULL DEFAULT 1,
            serving     TEXT,
            kcal        INTEGER NOT NULL,
            carbs_g     REAL NOT NULL,
            protein_g   REAL NOT NULL,
            fat_g       REAL NOT NULL,
            category    TEXT NOT NULL,
            tags        TEXT DEFAULT '',
            note        TEXT DEFAULT '',
            eaten_at    TEXT NOT NULL,
            source      TEXT DEFAULT 'manual',
            deleted     INTEGER NOT NULL DEFAULT 0,
            updated_at  TEXT NOT NULL,
            dirty       INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute('CREATE INDEX entries_eaten ON entries(eaten_at)');

        // Single-row settings, including the sync cursor.
        await db.execute('''
          CREATE TABLE meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.insert('meta', {'key': 'cursor', 'value': '0'});

        // Recipes recently offered, so a refresh produces a different set.
        await db.execute('''
          CREATE TABLE shown (
            recipe_id TEXT NOT NULL,
            shown_at  TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // -------------------------------------------------------------- foods
  /// Reference data ships in the binary rather than the database: it never
  /// changes on the device, so there is nothing to migrate or sync.
  List<Food> searchFoods(String query) {
    if (query.trim().isEmpty) return seedFoods.take(8).toList();
    final q = query.toLowerCase();
    return seedFoods
        .where((f) =>
            f.name.toLowerCase().contains(q) ||
            (f.brand ?? '').toLowerCase().contains(q))
        .take(12)
        .toList();
  }

  Food? foodById(int id) {
    for (final f in seedFoods) {
      if (f.id == id) return f;
    }
    return null;
  }

  Recipe? localRecipeById(String id) {
    for (final r in seedRecipes) {
      if (r.id == id) return r;
    }
    return null;
  }

  // ------------------------------------------------------------ entries
  Future<List<Entry>> entriesForDay(DateTime day) async {
    final db = await database;
    final key = _dayKey(day);
    final rows = await db.query(
      'entries',
      where: "deleted = 0 AND substr(eaten_at, 1, 10) = ?",
      whereArgs: [key],
      orderBy: 'eaten_at',
    );
    return rows.map(Entry.fromRow).toList();
  }

  Future<Entry?> entryById(String id) async {
    final db = await database;
    final rows = await db.query('entries',
        where: 'id = ? AND deleted = 0', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Entry.fromRow(rows.first);
  }

  /// Record a food. The id is generated here, on the device.
  Future<Entry> addEntry({
    required Food food,
    required double quantity,
    required DateTime eatenAt,
    String? category,
    String note = '',
  }) async {
    final nutrition = scaleNutrition(food.perServing, quantity);
    final entry = Entry(
      id: _uuid.v4(),
      foodId: food.id,
      foodName: food.name,
      quantity: quantity,
      serving: food.serving,
      kcal: nutrition.kcal,
      carbsG: nutrition.carbsG,
      proteinG: nutrition.proteinG,
      fatG: nutrition.fatG,
      // An explicit choice beats the automatic one.
      category: category ?? categoriseByTime(eatenAt),
      tags: autoTags(nutrition),
      note: note,
      eatenAt: eatenAt,
      updatedAt: DateTime.now().toUtc(),
      dirty: true,
    );
    final db = await database;
    await db.insert('entries', entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return entry;
  }

  Future<Entry> addRecipeEntry({
    required Recipe recipe,
    required String category,
  }) async {
    final nutrition = Nutrition(
      kcal: recipe.kcal,
      carbsG: recipe.carbsG,
      proteinG: recipe.proteinG,
      fatG: recipe.fatG,
    );
    final entry = Entry(
      id: _uuid.v4(),
      foodId: null,
      foodName: recipe.name,
      quantity: 1,
      serving: '1 serving',
      kcal: nutrition.kcal,
      carbsG: nutrition.carbsG,
      proteinG: nutrition.proteinG,
      fatG: nutrition.fatG,
      category: category,
      tags: autoTags(nutrition),
      note: recipe.estimated
          ? 'From recommendations, estimated values'
          : 'From recommendations',
      eatenAt: DateTime.now(),
      source: recipe.source,
      updatedAt: DateTime.now().toUtc(),
      dirty: true,
    );
    final db = await database;
    await db.insert('entries', entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return entry;
  }

  Future<void> updateEntry(Entry entry) async {
    final db = await database;
    final updated = entry.copyWith(
      updatedAt: DateTime.now().toUtc(),
      dirty: true,
    );
    await db.update('entries', updated.toRow(),
        where: 'id = ?', whereArgs: [entry.id]);
  }

  /// Tombstone rather than DELETE. A removed row would otherwise be handed
  /// straight back by the next pull and reappear in the diary.
  Future<void> deleteEntry(String id) async {
    final db = await database;
    await db.update(
      'entries',
      {
        'deleted': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // --------------------------------------------------------------- sync
  Future<List<Entry>> dirtyEntries() async {
    final db = await database;
    final rows = await db.query('entries', where: 'dirty = 1', limit: 500);
    return rows.map(Entry.fromRow).toList();
  }

  Future<void> markClean(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update('entries', {'dirty': 0}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Apply a row that arrived from the server.
  ///
  /// Last-write-wins on `updated_at`, the same rule the server applies, so the
  /// two never disagree about which edit survived.
  Future<void> applyRemote(Map<String, dynamic> remote) async {
    final db = await database;
    final id = remote['id'] as String;
    final incomingAt = DateTime.tryParse('${remote['updated_at']}');
    if (incomingAt == null) return;

    final existing =
        await db.query('entries', where: 'id = ?', whereArgs: [id], limit: 1);
    if (existing.isNotEmpty) {
      final localAt = DateTime.tryParse('${existing.first['updated_at']}');
      // A local edit the server has not seen yet must not be overwritten.
      if (localAt != null && !incomingAt.isAfter(localAt)) return;
    }

    final row = Map<String, Object?>.from(remote)
      ..remove('server_seq')
      ..['dirty'] = 0;
    await db.insert('entries', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> cursor() async {
    final db = await database;
    final rows =
        await db.query('meta', where: 'key = ?', whereArgs: ['cursor'], limit: 1);
    if (rows.isEmpty) return 0;
    return int.tryParse('${rows.first['value']}') ?? 0;
  }

  Future<void> setCursor(int value) async {
    final db = await database;
    await db.insert('meta', {'key': 'cursor', 'value': '$value'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // -------------------------------------------------------------- shown
  Future<Set<String>> recentlyShown() async {
    final db = await database;
    final rows =
        await db.query('shown', orderBy: 'shown_at DESC', limit: 8);
    return rows.map((r) => '${r['recipe_id']}').toSet();
  }

  Future<void> recordShown(Iterable<String> ids) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final id in ids) {
      batch.insert('shown', {'recipe_id': id, 'shown_at': now});
    }
    await batch.commit(noResult: true);
  }

  /// Clear recorded entries so the app can be demonstrated again.
  Future<void> reset() async {
    final db = await database;
    await db.delete('entries');
    await db.delete('shown');
    await setCursor(0);
  }

  String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
