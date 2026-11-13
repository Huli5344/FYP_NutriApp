/// Talks to the Flask backend.
///
/// Every call here is allowed to fail. The diary works with no server at all,
/// so nothing in this file is on the critical path for logging a meal; a
/// failure means a stale suggestion list or an unsynced entry, never a broken
/// screen.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';
import 'models.dart';
import 'seed_data.dart';
import 'session.dart';

class ApiConfig {
  /// Where the backend is.
  ///
  /// The default is the deployed server, so a build with no flags works --
  /// including one made by somebody who has just cloned the repository and
  /// has never seen this file. It used to default to a LAN address from the
  /// machine this was written on, which meant a forgotten flag produced an
  /// app that silently reached nothing.
  ///
  /// Override at build time to point somewhere else:
  ///
  ///     flutter run --dart-define=API_BASE=http://192.168.1.42:5000
  ///
  /// For a laptop on the same Wi-Fi, use its LAN address rather than
  /// 10.0.2.2 -- that one is emulator-only and resolves to nothing on a
  /// physical phone. `ipconfig` shows it, next to the Wi-Fi adapter. A plain
  /// http:// address also needs `usesCleartextTraffic` in the Android
  /// manifest, which the https:// default does not.
  ///
  /// No trailing slash: request paths are appended directly, so one would
  /// produce `...com//api/login`, which the server answers with a 404.
  static const String baseUrl = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://nutriapp-backend-qqpl.onrender.com',
  );

  /// For calls nobody is waiting on.
  ///
  /// Sync and the recipe list are allowed to fail: they try again later and
  /// the diary works without them. Six seconds keeps a dead server from
  /// holding up a screen.
  static const Duration timeout = Duration(seconds: 6);

  /// For sign-in, registration and the launch check.
  ///
  /// Much longer, because somebody is sitting there watching these, and
  /// because a free host spins its container down after fifteen idle minutes
  /// and takes about a minute to come back. At six seconds the first sign-in
  /// of the evening would fail -- and the message would be about the password,
  /// which is a lie about the one thing the user is trying to get right.
  ///
  /// The screens show a "still waking up" note after a few seconds so the
  /// wait is explained rather than silent.
  static const Duration authTimeout = Duration(seconds: 75);

  /// How long before a screen should explain the wait.
  static const Duration slowHint = Duration(seconds: 6);
}

/// What a call to the backend did.
///
/// `unauthorised` is separated from a general failure because the two mean
/// opposite things to the interface: a network failure is ordinary and silent,
/// while a rejected token means this device is signed out and has to say so.
enum ApiOutcome { ok, unauthorised, failed }

class AuthResult {
  final ApiOutcome outcome;
  final Session? session;

  /// Something to show the user. Null when there is nothing useful to say.
  final String? message;

  const AuthResult(this.outcome, {this.session, this.message});

  bool get ok => outcome == ApiOutcome.ok;
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

  /// Not a real HTTP status. The timeout handlers below return it so that a
  /// server which never answered can be told apart from one that refused,
  /// without catching an exception type -- which would mean importing
  /// dart:async for a single name.
  static const int _timedOut = 599;

  static const String _wakingMessage =
      'The server did not answer in time. Free hosting puts it to sleep '
      'after fifteen idle minutes and it takes about a minute to wake, so '
      'waiting a moment and trying again usually works.';

  /// Set when a call is rejected for a bad or expired token, so the shell can
  /// return to the sign-in screen rather than leaving someone on a dashboard
  /// that will never sync again.
  bool signedOut = false;

  Map<String, String> _headers({bool json = false}) {
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
    };
    final session = SessionStore.instance.current;
    if (session != null) headers.addAll(session.authHeader);
    return headers;
  }

  // --------------------------------------------------------------- accounts

  /// Create an account. Returns the session on success.
  Future<AuthResult> register(
      {required String email,
      required String password,
      required String name}) async {
    try {
      final response = await _client
          .post(Uri.parse('${ApiConfig.baseUrl}/api/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(
                  {'email': email, 'password': password, 'name': name}))
          .timeout(ApiConfig.authTimeout, onTimeout: _timeoutResponse);

      if (response.statusCode == _timedOut) {
        return const AuthResult(ApiOutcome.failed, message: _wakingMessage);
      }

      final body = _decode(response.body);
      if (response.statusCode == 201) {
        return AuthResult(ApiOutcome.ok,
            session: Session.fromLogin(
                '${body['token']}', body['user'] as Map<String, dynamic>));
      }
      // The server returns a list of specific problems; showing them beats a
      // generic "registration failed" the user cannot act on.
      final problems = (body['problems'] as List?)?.cast<String>();
      return AuthResult(ApiOutcome.failed,
          message: problems != null && problems.isNotEmpty
              ? problems.join('\n')
              : '${body['error'] ?? 'Could not create the account.'}');
    } catch (e) {
      return AuthResult(ApiOutcome.failed, message: _offlineMessage(e));
    }
  }

  Future<AuthResult> login(
      {required String email, required String password}) async {
    try {
      final response = await _client
          .post(Uri.parse('${ApiConfig.baseUrl}/api/login'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'password': password}))
          .timeout(ApiConfig.authTimeout, onTimeout: _timeoutResponse);

      if (response.statusCode == _timedOut) {
        return const AuthResult(ApiOutcome.failed, message: _wakingMessage);
      }

      if (response.statusCode == 200) {
        final body = _decode(response.body);
        return AuthResult(ApiOutcome.ok,
            session: Session.fromLogin(
                '${body['token']}', body['user'] as Map<String, dynamic>));
      }
      if (response.statusCode == 401) {
        // Deliberately not "no such account": which addresses are registered
        // is not something a sign-in screen should reveal.
        return const AuthResult(ApiOutcome.failed,
            message: 'Email or password is incorrect.');
      }
      return AuthResult(ApiOutcome.failed,
          message: 'The server returned ${response.statusCode}.');
    } catch (e) {
      return AuthResult(ApiOutcome.failed, message: _offlineMessage(e));
    }
  }

  /// Tell the server to forget this token. Best-effort: the local session is
  /// cleared either way, because a device that cannot reach the server still
  /// has to be able to sign out.
  Future<void> logout() async {
    try {
      await _client
          .post(Uri.parse('${ApiConfig.baseUrl}/api/logout'),
              headers: _headers())
          .timeout(ApiConfig.timeout);
    } catch (_) {
      // Nothing to do. The token expires server-side in thirty days.
    }
  }

  /// Who the stored token belongs to, and whether setup has been done.
  ///
  /// Called on launch. `unauthorised` means the token has expired or been
  /// revoked; `failed` means the server could not be reached, which is not a
  /// reason to sign anybody out.
  /// Delete this account and everything in it, permanently.
  ///
  /// The password goes with the request even though the token is already in
  /// the headers: the server re-checks it, because a token on an unlocked
  /// phone is not proof that the owner is the one tapping, and this action
  /// has no undo.
  ///
  /// Returns null on success, or a message to show the user.
  Future<String?> deleteAccount(String password) async {
    try {
      final response = await _client
          .post(Uri.parse('${ApiConfig.baseUrl}/api/account/delete'),
              headers: _headers(json: true),
              body: jsonEncode({'password': password}))
          .timeout(ApiConfig.authTimeout, onTimeout: _timeoutResponse);

      if (response.statusCode == 200) return null;
      if (response.statusCode == _timedOut) return _wakingMessage;
      if (response.statusCode == 401) {
        signedOut = true;
        return 'Your session expired. Sign in again, then try once more.';
      }

      final body = _decode(response.body);
      return body['error']?.toString() ?? 'Could not delete the account.';
    } catch (e) {
      // Nothing was deleted -- the request never completed -- so it is safe
      // to say so plainly and let them try again.
      return 'Could not reach the server, so nothing has been deleted. '
          'Check your connection and try again.';
    }
  }

  Future<ApiOutcome> checkSession() async {
    try {
      final response = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/me'), headers: _headers())
          .timeout(ApiConfig.authTimeout, onTimeout: _timeoutResponse);
      // A server that never answered says nothing about the token, so this is
      // `failed` and not `unauthorised`. Signing someone out because their
      // host was asleep would be the worst possible reading of silence.
      if (response.statusCode == _timedOut) return ApiOutcome.failed;
      if (response.statusCode == 200) return ApiOutcome.ok;
      if (response.statusCode == 401) {
        signedOut = true;
        return ApiOutcome.unauthorised;
      }
      return ApiOutcome.failed;
    } catch (_) {
      return ApiOutcome.failed;
    }
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Stands in for a reply that never came, so the caller can branch on a
  /// status code like any other outcome.
  static http.Response _timeoutResponse() =>
      http.Response('{"error":"timeout"}', _timedOut);

  static String _offlineMessage(Object error) =>
      'Could not reach the server. Check that it is running and that '
      '${ApiConfig.baseUrl} is reachable from this phone.';

  // --------------------------------------------------------------- sync
  /// Push local changes and pull everything changed elsewhere, in one call.
  ///
  /// Carries three collections: diary entries, the weight log and the profile.
  /// They share one `server_seq` sequence and therefore one cursor, so a client
  /// cannot end up having pulled entries up to one point and weights up to
  /// another, which is the state that would make "what have I not seen?"
  /// unanswerable.
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
        final dirtyWeights = await db.dirtyWeights();
        final dirtyFoods = await db.dirtyCustomFoods();
        final dirtyProfile = await db.dirtyProfile();
        final since = await db.cursor();

        final response = await _client
            .post(
              Uri.parse('${ApiConfig.baseUrl}/sync'),
              headers: _headers(json: true),
              body: jsonEncode({
                'since': since,
                'changes': dirty.map((e) => e.toSyncJson()).toList(),
                'weights':
                    dirtyWeights.map((w) => w.toSyncJson()).toList(),
                // The stored row minus `dirty`, which is this device's own
                // bookkeeping and means nothing to the server.
                'custom_foods': [
                  for (final food in dirtyFoods)
                    {
                      for (final field in food.entries)
                        if (field.key != 'dirty') field.key: field.value,
                    }
                ],
                'profile': dirtyProfile?.toSyncJson(),
              }),
            )
            .timeout(ApiConfig.timeout);

        if (response.statusCode == 401) {
          // The token has expired or been revoked. Worth surfacing, unlike an
          // ordinary network failure: nothing will ever sync again until the
          // user signs in, so silence would be a lie.
          signedOut = true;
          return const SyncResult(
              ok: false, error: 'Signed out. Sign in again to sync.');
        }
        if (response.statusCode != 200) {
          return SyncResult(
              ok: false, error: 'Server returned ${response.statusCode}');
        }

        final body = jsonDecode(response.body) as Map<String, dynamic>;

        // Clear the dirty flags only once the server has confirmed the push.
        // Doing it earlier would lose an entry if the response never arrived.
        await db.markClean(dirty.map((e) => e.id));
        await db.markWeightsClean(dirtyWeights.map((w) => w.id));
        await db.markCustomFoodsClean(
            dirtyFoods.map((food) => '${food['id']}'));
        if (dirtyProfile != null) await db.markProfileClean();
        pushed += dirty.length +
            dirtyWeights.length +
            dirtyFoods.length +
            (dirtyProfile == null ? 0 : 1);

        final changes =
            (body['changes'] as List?)?.cast<Map<String, dynamic>>() ??
                const [];
        for (final remote in changes) {
          await db.applyRemote(remote);
        }

        final weights =
            (body['weights'] as List?)?.cast<Map<String, dynamic>>() ??
                const [];
        for (final remote in weights) {
          await db.applyRemoteWeight(remote);
        }

        final foods =
            (body['custom_foods'] as List?)?.cast<Map<String, dynamic>>() ??
                const [];
        for (final remote in foods) {
          await db.applyRemoteCustomFood(remote);
        }

        final profile = body['profile'] as Map<String, dynamic>?;
        if (profile != null) await db.applyRemoteProfile(profile);

        pulled += changes.length +
            weights.length +
            foods.length +
            (profile == null ? 0 : 1);

        await db.setCursor((body['cursor'] as num?)?.toInt() ?? since);

        final hasMore = (body['has_more'] as bool?) ?? false;
        final moreToPush = (await db.dirtyEntries()).isNotEmpty ||
            (await db.dirtyWeights()).isNotEmpty ||
            (await db.dirtyCustomFoods()).isNotEmpty ||
            (await db.dirtyProfile()) != null;
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
          .get(
              Uri.parse('${ApiConfig.baseUrl}/api/recipes'
                  '?diet=${Uri.encodeComponent(dietType)}'),
              headers: _headers())
          .timeout(ApiConfig.timeout);

      if (response.statusCode == 401) {
        signedOut = true;
        return const RecipeResult(seedRecipes, RecipeOrigin.local,
            'Signed out, so these come from the meals stored on this device.');
      }

      if (response.statusCode != 200) {
        return RecipeResult(seedRecipes, RecipeOrigin.local,
            'The recipe service returned ${response.statusCode}, so these come '
            'from the meals stored on this device.');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final items =
          (body['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (items.isEmpty) {
        return const RecipeResult(seedRecipes, RecipeOrigin.local,
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
      return const RecipeResult(seedRecipes, RecipeOrigin.local,
          'The recipe service could not be reached, so these come from the '
          'meals stored on this device.');
    }
  }

  /// A quick reachability check for the status screen.
  Future<Map<String, dynamic>> testConnection() async {
    final started = DateTime.now();
    try {
      final response = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/ping'), headers: _headers())
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
