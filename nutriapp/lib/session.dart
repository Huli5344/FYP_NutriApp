/// The signed-in account, as this device knows it.
///
/// A session is a token and the user it identifies. The token is stored in the
/// local database's `meta` table rather than in shared_preferences, which
/// keeps the dependency list as it is and puts the token in the same file as
/// everything else belonging to this account -- so signing out clears one
/// thing, not two that could disagree.
///
/// **What this is not.** The token is stored in plain text in the app's
/// private database. On a normal device that is readable only by this app,
/// but it is not encrypted and it is not in the Android Keystore. A rooted
/// phone, or a backup extraction, would yield it. Saying so here rather than
/// implying otherwise: a production app would use flutter_secure_storage, and
/// swapping this file for one is the whole change.
///
/// Tokens expire after thirty days server-side. An expired or revoked token
/// comes back as a 401, which [Api] reports and the shell turns into a return
/// to the sign-in screen.
library;

import 'db.dart';

class Session {
  final String token;
  final String userId;
  final String email;
  final String name;

  const Session({
    required this.token,
    required this.userId,
    required this.email,
    required this.name,
  });

  Map<String, String> get authHeader => {'Authorization': 'Bearer $token'};

  factory Session.fromLogin(String token, Map<String, dynamic> user) =>
      Session(
        token: token,
        userId: '${user['id']}',
        email: '${user['email']}',
        name: '${user['name']}',
      );
}

class SessionStore {
  static final SessionStore instance = SessionStore._();
  SessionStore._();

  static const _tokenKey = 'auth_token';
  static const _userIdKey = 'auth_user_id';
  static const _emailKey = 'auth_email';
  static const _nameKey = 'auth_name';

  Session? _cached;

  /// The session held in memory, if one has been loaded this run.
  ///
  /// Synchronous so a widget's build method can ask without a FutureBuilder.
  /// Call [load] once at startup before relying on it.
  Session? get current => _cached;

  Future<Session?> load() async {
    final token = await LocalDb.instance.meta(_tokenKey);
    if (token == null || token.isEmpty) {
      _cached = null;
      return null;
    }
    _cached = Session(
      token: token,
      userId: await LocalDb.instance.meta(_userIdKey) ?? '',
      email: await LocalDb.instance.meta(_emailKey) ?? '',
      name: await LocalDb.instance.meta(_nameKey) ?? '',
    );
    return _cached;
  }

  Future<void> save(Session session) async {
    await LocalDb.instance.setMeta(_tokenKey, session.token);
    await LocalDb.instance.setMeta(_userIdKey, session.userId);
    await LocalDb.instance.setMeta(_emailKey, session.email);
    await LocalDb.instance.setMeta(_nameKey, session.name);
    _cached = session;
  }

  /// Forget the token but keep the data.
  ///
  /// For a token that stopped working -- expired, or revoked from another
  /// device. The same account is going to sign back in on this phone, and
  /// anything not yet pushed still has to get its chance, so the diary stays
  /// exactly where it is. Clearing it here would delete a user's meals
  /// because a token aged out, which is not a trade anyone would accept.
  Future<void> forgetToken() async {
    _cached = null;
    await LocalDb.instance.setMeta(_tokenKey, '');
    await LocalDb.instance.setMeta(_userIdKey, '');
    await LocalDb.instance.setMeta(_emailKey, '');
    await LocalDb.instance.setMeta(_nameKey, '');
  }

  /// Forget the token, and everything belonging to the account that held it.
  ///
  /// For a deliberate sign-out, where the next person to use the phone may be
  /// someone else. The diary is cleared, not kept: two accounts on one device
  /// must not see each other's meals, and the local tables carry no user
  /// column -- this device holds one account's data at a time, by design,
  /// because the alternative is a user_id on every local row and in every
  /// local query, for a case a phone rarely has.
  ///
  /// Because this destroys data, the caller syncs first and warns about
  /// anything that could not be pushed. See ProfileScreen._signOut.
  Future<void> clear() async {
    await forgetToken();
    await LocalDb.instance.resetEverything();
  }
}
