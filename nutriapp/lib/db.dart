/// On-device SQLite store.
///
/// This is the source of truth for the interface. Every screen reads and
/// writes here and never waits on the network; sync runs in the background and
/// updates the same tables. If a screen ever shows a spinner while waiting for
/// the server, the architecture has leaked.
///
/// The entries schema mirrors the backend's, with one extra column: `dirty`,
/// the device's own record of what it still owes the server.
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'logic.dart';
import 'models.dart';
import 'food_db.dart';
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

  /// Bumped whenever the schema changes. A device that already holds an older
  /// database runs [_upgrade] rather than [_create], so an installed copy of
  /// the app is migrated instead of failing on a missing table.
  static const int schemaVersion = 3;

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'nutriapp.db');
    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, version) async {
        await _createV1(db);
        await _createV2(db);
      },
      onUpgrade: (db, from, to) async {
        // Each step is additive and guarded, so upgrading from any earlier
        // version is a matter of running the steps it has not seen.
        if (from < 2) await _createV2(db);
        if (from < 3) await _upgradeToV3(db);
      },
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _createV1(Database db) async {
    {
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
    }
  }

  /// Food ids became strings when the thirty hand-entered foods were replaced
  /// by the Health Promotion Board dataset, whose ids look like "F05020050".
  ///
  /// The integers already stored point at rows in a table that no longer
  /// exists, so they are cleared rather than converted: there is nothing to
  /// convert them to. The entries themselves are untouched -- each carries its
  /// own copy of the nutrition, so clearing the pointer loses provenance, not
  /// anybody's lunch.
  ///
  /// The column keeps its declared type. SQLite's types are advisory, so it
  /// stores the new strings happily, and a table rebuild on a database that
  /// cannot be tested here is a worse risk than a misleading declaration.
  /// `Entry.fromRow` reads this column defensively for the same reason.
  Future<void> _upgradeToV3(Database db) async {
    await db.execute('UPDATE entries SET food_id = NULL');
  }

  /// The profile and weight log, added after the first release.
  ///
  /// `IF NOT EXISTS` throughout so running this against a database that has
  /// already seen it is harmless, which is what makes the upgrade path above
  /// safe to re-run.
  Future<void> _createV2(Database db) async {
    // One row, keyed 'me'. A device holds one profile, so a save should
    // replace rather than append; a fixed key makes that the default.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS profile (
        id                   TEXT PRIMARY KEY,
        name                 TEXT NOT NULL,
        email                TEXT DEFAULT '',
        age                  INTEGER NOT NULL,
        gender               TEXT,
        height_cm            REAL NOT NULL,
        weight_kg            REAL NOT NULL,
        activity_level       TEXT NOT NULL,
        goal                 TEXT NOT NULL,
        target_weight_kg     REAL,
        preferences          TEXT DEFAULT '',
        restrictions         TEXT DEFAULT '',
        allergens            TEXT DEFAULT '',
        diet_types           TEXT DEFAULT '',
        diet_type            TEXT DEFAULT 'balanced',
        computed_target_kcal INTEGER NOT NULL,
        target_kcal          INTEGER NOT NULL,
        target_is_manual     INTEGER NOT NULL DEFAULT 0,
        updated_at           TEXT NOT NULL,
        dirty                INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS weights (
        id          TEXT PRIMARY KEY,
        kg          REAL NOT NULL,
        recorded_at TEXT NOT NULL,
        note        TEXT DEFAULT '',
        deleted     INTEGER NOT NULL DEFAULT 0,
        updated_at  TEXT NOT NULL,
        dirty       INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS weights_recorded ON weights(recorded_at)');
  }

  // -------------------------------------------------------------- foods
  /// Foods live in their own bundled, read-only database. See food_db.dart.
  ///
  /// Asynchronous now, where the thirty hand-entered foods were a constant
  /// list: 2,692 rows belong in a queryable table, not in compiled Dart.
  Future<List<Food>> searchFoods(String query, {int limit = 30}) =>
      FoodDb.instance.search(query, limit: limit);

  Future<Food?> foodById(String id) => FoodDb.instance.byId(id);

  Recipe? localRecipeById(String id) {
    for (final r in seedRecipes) {
      if (r.id == id) return r;
    }
    return null;
  }

  // ------------------------------------------------------------ entries
  Future<List<Entry>> entriesForDay(DateTime day) async {
    final db = await database;
    final key = dayKey(day);
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

  /// Live entries across a window of days ending today, for Insights.
  ///
  /// Filtered in SQL on the date prefix rather than loading the whole diary and
  /// discarding most of it, so the screen stays quick on a long history.
  Future<List<Entry>> entriesForRange(DateTime from, DateTime to) async {
    final db = await database;
    final rows = await db.query(
      'entries',
      where: 'deleted = 0 AND substr(eaten_at, 1, 10) BETWEEN ? AND ?',
      whereArgs: [dayKey(from), dayKey(to)],
      orderBy: 'eaten_at',
    );
    return rows.map(Entry.fromRow).toList();
  }

  // ------------------------------------------------------------- profile
  /// The stored profile, or null when onboarding has not been completed.
  ///
  /// Null is the signal the sign-in gate uses, so it has to mean exactly "no
  /// profile" and never "a profile with default values".
  Future<UserProfile?> loadProfile() async {
    final db = await database;
    final rows = await db.query('profile',
        where: 'id = ?', whereArgs: [UserProfile.rowId], limit: 1);
    return rows.isEmpty ? null : UserProfile.fromRow(rows.first);
  }

  Future<void> saveProfile(UserProfile profile) async {
    final db = await database;
    final row = profile.toRow()..['dirty'] = 1;
    await db.insert('profile', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Remove the profile and everything derived from it.
  ///
  /// Used by "start over" on the Profile screen. The diary is left alone: a
  /// person redoing their goals has not stopped having eaten.
  Future<void> clearProfile() async {
    final db = await database;
    await db.delete('profile');
  }

  // ------------------------------------------------------------- weights
  Future<List<WeightEntry>> weightLog({int limit = 60}) async {
    final db = await database;
    final rows = await db.query('weights',
        where: 'deleted = 0', orderBy: 'recorded_at DESC', limit: limit);
    return rows.map(WeightEntry.fromRow).toList();
  }

  Future<WeightEntry> logWeight(double kg,
      {DateTime? recordedAt, String note = ''}) async {
    final entry = WeightEntry(
      id: _uuid.v4(),
      kg: kg,
      recordedAt: recordedAt ?? DateTime.now(),
      note: note,
      updatedAt: DateTime.now().toUtc(),
      dirty: true,
    );
    final db = await database;
    await db.insert('weights', entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return entry;
  }

  /// Tombstone, for the same reason entries are tombstoned.
  Future<void> deleteWeight(String id) async {
    final db = await database;
    await db.update(
      'weights',
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
  /// How many locally recorded rows have never reached the server.
  ///
  /// Asked before a deliberate sign-out, which clears this device. If the
  /// count is above zero and the server cannot be reached, signing out loses
  /// work -- so the number goes into the confirmation dialog rather than
  /// being discovered afterwards. A changed profile counts as one.
  Future<int> pendingCount() async {
    final db = await database;
    var total = 0;
    for (final table in ['entries', 'weights', 'profile']) {
      final rows = await db.rawQuery(
          'SELECT COUNT(*) AS n FROM $table WHERE dirty = 1');
      total += (rows.first['n'] as int?) ?? 0;
    }
    return total;
  }

  Future<List<Entry>> dirtyEntries() async {
    final db = await database;
    final rows = await db.query('entries', where: 'dirty = 1', limit: 500);
    return rows.map(Entry.fromRow).toList();
  }

  Future<List<WeightEntry>> dirtyWeights() async {
    final db = await database;
    final rows = await db.query('weights', where: 'dirty = 1', limit: 500);
    return rows.map(WeightEntry.fromRow).toList();
  }

  /// The profile, only when it has local changes the server has not seen.
  Future<UserProfile?> dirtyProfile() async {
    final db = await database;
    final rows = await db.query('profile',
        where: 'id = ? AND dirty = 1',
        whereArgs: [UserProfile.rowId],
        limit: 1);
    return rows.isEmpty ? null : UserProfile.fromRow(rows.first);
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

  Future<void> markWeightsClean(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in ids) {
      batch.update('weights', {'dirty': 0}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> markProfileClean() async {
    final db = await database;
    await db.update('profile', {'dirty': 0},
        where: 'id = ?', whereArgs: [UserProfile.rowId]);
  }

  /// Apply a weight row that arrived from the server. Same rule as entries.
  Future<void> applyRemoteWeight(Map<String, dynamic> remote) async {
    final db = await database;
    final id = remote['id'] as String?;
    if (id == null) return;
    final incomingAt = DateTime.tryParse('${remote['updated_at']}');
    if (incomingAt == null) return;

    final existing =
        await db.query('weights', where: 'id = ?', whereArgs: [id], limit: 1);
    if (existing.isNotEmpty) {
      final localAt = DateTime.tryParse('${existing.first['updated_at']}');
      if (localAt != null && !incomingAt.isAfter(localAt)) return;
    }

    final row = Map<String, Object?>.from(remote)
      ..remove('server_seq')
      ..['dirty'] = 0;
    await db.insert('weights', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Apply a profile that arrived from the server.
  ///
  /// Last-write-wins like everything else, but worth stating plainly: a profile
  /// edited on this device and not yet pushed must not be replaced by an older
  /// copy the server still holds.
  Future<void> applyRemoteProfile(Map<String, dynamic> remote) async {
    final db = await database;
    final incomingAt = DateTime.tryParse('${remote['updated_at']}');
    if (incomingAt == null) return;

    final existing = await db.query('profile',
        where: 'id = ?', whereArgs: [UserProfile.rowId], limit: 1);
    if (existing.isNotEmpty) {
      final localAt = DateTime.tryParse('${existing.first['updated_at']}');
      if (localAt != null && !incomingAt.isAfter(localAt)) return;
    }

    final row = Map<String, Object?>.from(remote)
      ..remove('server_seq')
      ..['id'] = UserProfile.rowId
      ..['dirty'] = 0;
    await db.insert('profile', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
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

  // --------------------------------------------------------------- meta
  /// A stored setting. The sync cursor and the session token both live here.
  Future<String?> meta(String key) async {
    final db = await database;
    final rows = await db
        .query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : '${rows.first['value']}';
  }

  Future<void> setMeta(String key, String value) async {
    final db = await database;
    await db.insert('meta', {'key': key, 'value': value},
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
  ///
  /// Leaves the profile in place. Clearing the diary for another run-through
  /// should not make someone re-enter their height.
  Future<void> reset() async {
    final db = await database;
    await db.delete('entries');
    await db.delete('shown');
    await setCursor(0);
  }

  /// Clear everything, profile included. Used by "start over".
  Future<void> resetEverything() async {
    final db = await database;
    await db.delete('entries');
    await db.delete('shown');
    await db.delete('weights');
    await db.delete('profile');
    await setCursor(0);
  }
}
