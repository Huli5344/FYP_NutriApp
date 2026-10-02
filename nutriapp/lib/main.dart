/// Nutri App — Diary and Recommendations module.
///
/// Opens on the Home dashboard. There is no sign-in: accounts and goals belong
/// to a different module, so one demo profile is used instead.
///
/// The app works with no server at all. Sync runs in the background when the
/// backend can be reached, and a failure is silent by design — being offline is
/// the normal case for a food diary, not an error worth interrupting someone
/// over.

import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/diary_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/home_screen.dart';
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
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _tab = 0;

  // Rebuilt on every tab change so each screen reloads from the local
  // database rather than showing figures captured when the app started.
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
    if (result.ok && (result.pushed > 0 || result.pulled > 0)) {
      setState(() => _refreshToken++);
    }
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
    ];

    return Scaffold(
      body: SafeArea(child: screens[_tab]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) {
            // Insights and Profile belong to the other two modules. They are
            // shown because the design has five destinations, but inert here.
            if (i > 2) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('That screen belongs to another module.'),
                duration: Duration(seconds: 2),
              ));
              return;
            }
            _go(i);
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: AppColors.surface,
          selectedItemColor: AppColors.ink,
          unselectedItemColor: AppColors.mute,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.square_outlined), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.square_outlined), label: 'Diary'),
            BottomNavigationBarItem(icon: Icon(Icons.square_outlined), label: 'Discover'),
            BottomNavigationBarItem(icon: Icon(Icons.square_outlined), label: 'Insights'),
            BottomNavigationBarItem(icon: Icon(Icons.square_outlined), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
