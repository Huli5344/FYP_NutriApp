/// Tests for the parsing layer: database rows and JSON turning into objects.
///
/// This is where the app is most likely to break without anybody noticing,
/// because a bad cast throws at runtime rather than at compile time. Two
/// changes made it worth covering properly:
///
///  * the food table became the Health Promotion Board's 2,692 rows, with a
///    string id and a published serving label, in place of 30 hand-entered
///    foods with integer ids;
///  * a phone upgrading from schema 2 can still hold an integer in
///    `entries.food_id`, which `as String?` would throw on.
///
/// The food rows below are copied out of `assets/foods.db` rather than
/// invented, so a change to the import script that alters the row shape shows
/// up here instead of on a phone.
///
/// No database and no network: everything here is a pure function over a map.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nutriapp_diary/models.dart';
import 'package:nutriapp_diary/session.dart';

/// One real row, exactly as `FoodDb.search` selects it.
Map<String, Object?> roastedChickenRice() => {
      'food_id': 'F05100112',
      'name': 'Roasted chicken rice',
      'food_group': 'Grains and staples',
      'serving_label': '1 plate(s) = 363g',
      'energy_kcal': 643.0,
      'carbohydrate_g': 84.11,
      'protein_g': 29.67,
      'total_fat_g': 20.94,
      'bulk_serving': 0,
      'suppress_nutrients': '',
    };

Entry sampleEntry({String? foodId = 'F05100112'}) => Entry(
      id: 'c0ffee00-0000-4000-8000-000000000001',
      foodId: foodId,
      foodName: 'Roasted chicken rice',
      quantity: 1.5,
      serving: '1 plate(s) = 363g',
      kcal: 965,
      carbsG: 126.2,
      proteinG: 44.5,
      fatG: 31.4,
      category: 'lunch',
      tags: const ['high-carb'],
      note: 'ate most of it',
      eatenAt: DateTime.utc(2026, 3, 14, 12, 30),
      updatedAt: DateTime.utc(2026, 3, 14, 12, 31),
    );

void main() {
  group('Food.fromRow', () {
    test('reads a real HPB row', () {
      final food = Food.fromRow(roastedChickenRice());
      expect(food.id, 'F05100112');
      expect(food.name, 'Roasted chicken rice');
      expect(food.foodGroup, 'Grains and staples');
      // The serving label is HPB's own text, kept verbatim. The app shows it
      // and multiplies by it; it never tries to parse the grams out.
      expect(food.serving, '1 plate(s) = 363g');
      expect(food.perServing.kcal, 643);
      expect(food.perServing.carbsG, closeTo(84.11, 0.001));
      expect(food.bulkServing, isFalse);
      expect(food.suppressed, isEmpty);
    });

    test('energy is a float in the database and an int on the model', () {
      // Every energy figure in foods.db is stored as REAL. Casting straight
      // to int would throw on all 2,692 of them.
      final food = Food.fromRow(roastedChickenRice()..['energy_kcal'] = 643.6);
      expect(food.perServing.kcal, 644);
    });

    test('a whole roast turkey is flagged as a bulk serving', () {
      // One serving, 4,243 kcal, straight from HPB. The flag is what puts a
      // "large portion" warning in the search results, because a single tap
      // would otherwise log two days of food.
      final food = Food.fromRow({
        'food_id': 'F11050007',
        'name': 'Roasted turkey, without skin',
        'food_group': 'Poultry',
        'serving_label': '1 whole = 3812g',
        'energy_kcal': 4243.0,
        'carbohydrate_g': 0.0,
        'protein_g': 775.44,
        'total_fat_g': 102.47,
        'bulk_serving': 1,
        'suppress_nutrients': '',
      });
      expect(food.bulkServing, isTrue);
      expect(food.perServing.kcal, 4243);
    });

    test('suppressed nutrients are listed, and parsed one per name', () {
      final food = Food.fromRow(roastedChickenRice()
        ..['suppress_nutrients'] = 'trans_fat_g,saturated_fat_g');
      expect(food.suppressed, ['trans_fat_g', 'saturated_fat_g']);
    });

    test('an empty suppression list is empty, not a list of one blank', () {
      // ''.split(',') is [''] in Dart, so without the filter every food would
      // claim to have one suppressed nutrient with no name.
      expect(Food.fromRow(roastedChickenRice()).suppressed, isEmpty);
    });

    test('a missing nutrient reads as zero rather than throwing', () {
      // No row in the shipped file has a null here -- the import fills every
      // one of the four headline figures. This covers a future dataset that
      // does not, because the alternative is a crash in the search list.
      final food = Food.fromRow(roastedChickenRice()
        ..['carbohydrate_g'] = null
        ..['protein_g'] = null
        ..['total_fat_g'] = null
        ..['food_group'] = null);
      expect(food.perServing.carbsG, 0);
      expect(food.perServing.proteinG, 0);
      expect(food.perServing.fatG, 0);
      expect(food.foodGroup, isNull);
    });

    test('a null serving label falls back to something printable', () {
      final food =
          Food.fromRow(roastedChickenRice()..['serving_label'] = null);
      expect(food.serving, '1 serving');
    });
  });

  group('Entry rows', () {
    test('survives a round trip through the database shape', () {
      final before = sampleEntry();
      final after = Entry.fromRow(before.toRow());

      expect(after.id, before.id);
      expect(after.foodId, before.foodId);
      expect(after.quantity, before.quantity);
      expect(after.kcal, before.kcal);
      expect(after.carbsG, closeTo(before.carbsG, 0.001));
      expect(after.category, before.category);
      expect(after.tags, before.tags);
      expect(after.note, before.note);
      expect(after.eatenAt.toUtc(), before.eatenAt.toUtc());
      expect(after.deleted, isFalse);
    });

    test('an integer food_id left by schema 2 does not throw', () {
      // The one upgrade hazard in this release. Before version 3 the food
      // table was 30 rows with integer ids, and entries pointed at them with
      // an integer. `as String?` on an int is a type error, and it would have
      // taken the whole diary down on first launch after the update.
      final row = sampleEntry().toRow()..['food_id'] = 17;
      final entry = Entry.fromRow(row);
      expect(entry.foodId, '17');
    });

    test('a null food_id stays null', () {
      // What _upgradeToV3 writes, and what a recipe-sourced entry has: the
      // entry keeps its own nutrition, so there is nothing to look up.
      final row = sampleEntry().toRow()..['food_id'] = null;
      expect(Entry.fromRow(row).foodId, isNull);
    });

    test('an entry with no tags comes back with no tags', () {
      final entry = Entry.fromRow(sampleEntry().toRow()..['tags'] = '');
      expect(entry.tags, isEmpty);
    });

    test('the sync payload omits dirty, which is the device\'s own business',
        () {
      final json = sampleEntry().toSyncJson();
      expect(json.containsKey('dirty'), isFalse);
      // Everything else the server needs is still there.
      expect(json['id'], isNotNull);
      expect(json['updated_at'], isNotNull);
      expect(json['deleted'], 0);
    });

    test('updated_at is sent in UTC', () {
      // The server compares timestamps across devices to settle which edit
      // wins. A local-time string would make a phone in Singapore look eight
      // hours ahead of one in London and silently win every conflict.
      final json = sampleEntry().toSyncJson();
      expect(json['updated_at'] as String, endsWith('Z'));
    });

    test('copyWith keeps the id and the food it came from', () {
      final edited = sampleEntry().copyWith(quantity: 2, kcal: 1286);
      expect(edited.id, sampleEntry().id);
      expect(edited.foodId, 'F05100112');
      expect(edited.quantity, 2);
      expect(edited.kcal, 1286);
    });
  });

  group('Session', () {
    test('reads a login response', () {
      final session = Session.fromLogin('tok_abc', const {
        'id': 'u_123',
        'email': 'student@example.com',
        'name': 'Student',
      });
      expect(session.token, 'tok_abc');
      expect(session.userId, 'u_123');
      expect(session.email, 'student@example.com');
    });

    test('a numeric user id becomes a string', () {
      // SQLite hands back an integer id, Postgres a string. The app stores it
      // as text either way so a switch of backend does not change the shape.
      final session = Session.fromLogin('tok_abc', const {
        'id': 42,
        'email': 'student@example.com',
        'name': 'Student',
      });
      expect(session.userId, '42');
    });

    test('carries a bearer header', () {
      final session = Session.fromLogin('tok_abc', const {
        'id': 'u_123',
        'email': 'student@example.com',
        'name': 'Student',
      });
      expect(session.authHeader, {'Authorization': 'Bearer tok_abc'});
    });
  });
}
