/// Nutri App.
///
/// Opens on a gate that reads the stored session and decides where to go: the
/// dashboard for a returning user, profile setup for one who signed in but
/// never finished, and the sign-in screen for everyone else.
///
/// The app works with no server at all. The diary, the profile and the food
/// table are all on the device; sync runs in the background when the backend
/// can be reached, and a failure is silent by design -- being offline is the
/// normal case for a food diary, not an error worth interrupting someone over.
///
/// The one failure that is *not* silent is a rejected token. That means
/// nothing will ever sync again until the user signs in, so staying quiet
/// would be a lie.
library;

import 'package:flutter/material.dart';

import 'api.dart';
import 'db.dart';
import 'screens/diary_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/home_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/profile_screen.dart';
import 'session.dart';
import 'ui.dart';

void main() {
  runApp(const NutriApp());
}

class NutriApp extends StatelessWidget {
  const NutriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nutri App',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const StartupGate(),
    );
  }
}

/// Decides the first screen.
///
/// Reads the token and the profile from the device, not from the network, so
/// an offline launch still reaches the dashboard. The token is verified
/// against the server afterwards, in the background: if it turns out to be
/// expired the shell says so, but a server that cannot be reached is not a
/// reason to sign anybody out.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  Widget? _destination;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final session = await SessionStore.instance.load();
    if (session == null) {
      _land(const LoginScreen());
      return;
    }

    var profile = await LocalDb.instance.loadProfile();

    // A signed-in device with no profile is almost always one that has not
    // pulled yet rather than a genuinely new account: the profile is on the
    // server, this copy just has not seen it. Ask before marching someone
    // through a setup they already did.
    //
    // This runs only when the profile is missing, so an ordinary launch pays
    // nothing for it. It matters because sign-in is not the only way to get
    // here -- closing the app midway through a restore lands exactly here,
    // and without this the next launch would offer onboarding instead.
    if (profile == null) {
      await Api.instance.sync();
      profile = await LocalDb.instance.loadProfile();
    }

    _land(profile == null
        ? OnboardingScreen(email: session.email, suggestedName: session.name)
        : const Shell());
  }

  void _land(Widget screen) {
    if (!mounted) return;
    setState(() => _destination = screen);
  }

  @override
  Widget build(BuildContext context) =>
      _destination ??
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _tab = 0;

  // Rebuilt on every tab change so each screen reloads from the local
  // database rather than showing figures captured when the app started. This
  // is also how a profile edit reaches the other tabs: they re-read it.
  int _refreshToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncQuietly();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sync on returning to the foreground, which is when a connection is most
    // likely to have come back.
    if (state == AppLifecycleState.resumed) _syncQuietly();
  }

  Future<void> _syncQuietly() async {
    final result = await Api.instance.sync();
    if (!mounted) return;

    if (Api.instance.signedOut) {
      _returnToSignIn();
      return;
    }
    if (result.ok && (result.pushed > 0 || result.pulled > 0)) {
      setState(() => _refreshToken++);
    }
  }

  /// The token was rejected, so this device is signed out.
  ///
  /// The local data is left alone rather than cleared: it may contain meals
  /// that were never pushed, and signing back in to the same account should
  /// recover them. SessionStore.clear is for a deliberate sign-out.
  void _returnToSignIn() {
    // Drop the dead token so the next launch opens on sign-in rather than on
    // a dashboard that fails to sync again. forgetToken, not clear: the data
    // belongs to an account that is about to sign back in.
    SessionStore.instance.forgetToken();

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginScreen(
          notice: 'Your session expired, so syncing stopped. Sign in again '
              'to resume. Nothing recorded on this device has been lost.',
        ),
      ),
      (route) => false,
    );
  }

  void _go(int index) {
    setState(() {
      _tab = index;
      _refreshToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(key: ValueKey('home$_refreshToken'), onNavigate: _go),
      DiaryScreen(key: ValueKey('diary$_refreshToken')),
      DiscoverScreen(key: ValueKey('discover$_refreshToken')),
      InsightsScreen(key: ValueKey('insights$_refreshToken')),
      ProfileScreen(key: ValueKey('profile$_refreshToken')),
    ];

    return Scaffold(
      body: SafeArea(child: screens[_tab]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: BottomNavigationBar(
          currentIndex: _tab,
          onTap: _go,
          type: BottomNavigationBarType.fixed,
          backgroundColor: AppColors.surface,
          selectedItemColor: AppColors.ink,
          unselectedItemColor: AppColors.mute,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined), label: 'Home'),
            BottomNavigationBarItem(
                icon: Icon(Icons.menu_book_outlined), label: 'Diary'),
            BottomNavigationBarItem(
                icon: Icon(Icons.explore_outlined), label: 'Discover'),
            BottomNavigationBarItem(
                icon: Icon(Icons.show_chart_outlined), label: 'Insights'),
            BottomNavigationBarItem(
                icon: Icon(Icons.person_outline), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
