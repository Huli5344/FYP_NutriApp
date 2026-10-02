/// Talks to the Flask backend.
///
/// Every call here is allowed to fail. The diary works with no server at all,
/// so nothing in this file is on the critical path for logging a meal; a
/// failure means a stale suggestion list or an unsynced entry, never a broken
/// screen.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';
import 'models.dart';
import 'seed_data.dart';

class ApiConfig {
  /// Where the Flask backend is.
  ///
  /// 10.0.2.2 is the address the Android emulator maps to the host machine;
  /// inside the emulator, 127.0.0.1 means the emulator itself. On a physical
  /// phone, put your computer's LAN address here instead, for example
  /// http://192.168.1.24:5000
  static const String baseUrl = 'http://10.0.2.2:5000';

  static const Duration timeout = Duration(seconds: 6);
}

/// What produced the meals currently on screen.
enum RecipeOrigin { api, local }

class RecipeResult {
  final List<Recipe> recipes;
  final RecipeOrigin origin;
  final String? warning;
  const RecipeResult(this.recipes, this.origin, [this.warning]);
}

class SyncResult {
  final bool ok;
  final int pushed;
  final int pulled;
  final String? error;
  const SyncResult({
    required this.ok,
    this.pushed = 0,
    this.pulled = 0,
    this.error,
  });
}

class Api {
  static final Api instance = Api._();
  Api._();

  final _client = http.Client();

  // --------------------------------------------------------------- sync
  /// Push local changes and pull everything changed elsewhere, in one call.
  ///
  /// Repeats while the server reports more waiting, so a first sync on a full
  /// diary completes rather than stopping at one page.
  Future<SyncResult> sync() async {
    final db = LocalDb.instance;
    var pushed = 0;
    var pulled = 0;

    try {
      var guard = 0;
      while (guard++ < 20) {
        final dirty = await db.dirtyEntries();
        final since = await db.cursor();

        final response = await _client
            .post(
              Uri.parse('${ApiConfig.baseUrl}/sync'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'since': since,
                'changes': dirty.map((e) => e.toSyncJson()).toList(),
              }),
            )
            .timeout(ApiConfig.timeout);

        if (response.statusCode != 200) {
          return SyncResult(
              ok: false, error: 'Server returned ${response.statusCode}');
        }

        final body = jsonDecode(response.body) as Map<String, dynamic>;

        // Clear the dirty flags only once the server has confirmed the push.
        // Doing it earlier would lose an entry if the response never arrived.
        await db.markClean(dirty.map((e) => e.id));
        pushed += dirty.length;

        final changes =
            (body['changes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
        for (final remote in changes) {
          await db.applyRemote(remote);
        }
        pulled += changes.length;

        await db.setCursor((body['cursor'] as num?)?.toInt() ?? since);

        final hasMore = (body['has_more'] as bool?) ?? false;
        final moreToPush = (await db.dirtyEntries()).isNotEmpty;
        if (!hasMore && !moreToPush) break;
      }
      return SyncResult(ok: true, pushed: pushed, pulled: pulled);
    } catch (e) {
      // Offline is the normal case, not an error worth surfacing loudly.
      return SyncResult(ok: false, pushed: pushed, pulled: pulled, error: '$e');
    }
  }

  // ----------------------------------------------------- recommendations
  /// Meals for a slot, from the backend when it can be reached.
  ///
  /// The backend owns the TheMealDB call, the calorie estimation and the
  /// allergen derivation. Those need a network anyway, so nothing is lost by
  /// leaving them there, and the API key stays off the device.
  Future<RecipeResult> recommendations(String dietType) async {
    try {
      final response = await _client
          .get(Uri.parse(
              '${ApiConfig.baseUrl}/api/recipes?diet=${Uri.encodeComponent(dietType)}'))
          .timeout(ApiConfig.timeout);

      if (response.statusCode != 200) {
        return RecipeResult(seedRecipes, RecipeOrigin.local,
            'The recipe service returned ${response.statusCode}, so these come '
            'from the meals stored on this device.');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final items =
          (body['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (items.isEmpty) {
        return RecipeResult(seedRecipes, RecipeOrigin.local,
            'The recipe service returned nothing, so these come from the meals '
            'stored on this device.');
      }

      final recipes = items.map(Recipe.fromApi).toList();
      // Top up a short response rather than leaving a half-empty screen.
      if (recipes.length < 10) {
        final have = recipes.map((r) => r.name.toLowerCase()).toSet();
        recipes.addAll(
            seedRecipes.where((r) => !have.contains(r.name.toLowerCase())));
      }
      return RecipeResult(recipes, RecipeOrigin.api);
    } catch (e) {
      return RecipeResult(seedRecipes, RecipeOrigin.local,
          'The recipe service could not be reached, so these come from the '
          'meals stored on this device.');
    }
  }

  /// A quick reachability check for the status screen.
  Future<Map<String, dynamic>> testConnection() async {
    final started = DateTime.now();
    try {
      final response = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/ping'))
          .timeout(ApiConfig.timeout);
      final ms = DateTime.now().difference(started).inMilliseconds;
      return {
        'ok': response.statusCode == 200,
        'ms': ms,
        'detail': 'HTTP ${response.statusCode}',
      };
    } catch (e) {
      return {
        'ok': false,
        'ms': DateTime.now().difference(started).inMilliseconds,
        'detail': '$e',
      };
    }
  }
}
