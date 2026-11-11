/// Sign in.
///
/// Three jobs: authenticate against the backend, store the token, then decide
/// where to go. Someone with a saved profile lands on the dashboard; someone
/// without one goes through profile setup. That last check is what stops
/// onboarding running on every launch.
///
/// There is no demo account any more. This talks to /api/login, which compares
/// a PBKDF2 digest server-side and returns a session token.
library;

import 'package:flutter/material.dart';

import '../api.dart';
import '../db.dart';
import '../main.dart';
import '../session.dart';
import '../ui.dart';
import 'onboarding/onboarding_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  /// Shown once when the screen is reached because a token stopped working,
  /// rather than because the user asked to sign in.
  final String? notice;

  const LoginScreen({super.key, this.notice});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final formKey = GlobalKey<FormState>();

  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool hidePassword = true;
  bool busy = false;
  String? error;

  /// Shown while a call is taking an unusual amount of time.
  ///
  /// A free host sleeps after fifteen idle minutes, so the first sign-in of
  /// the day can take about a minute. Without this the screen looks frozen
  /// and the natural move is to kill the app -- which guarantees the next
  /// attempt is also against a cold server.
  String? slowNote;

  /// Rises on each attempt, so a note scheduled by an abandoned one cannot
  /// appear over a later result.
  int attempt = 0;

  void startSlowHint() {
    final mine = ++attempt;
    Future.delayed(ApiConfig.slowHint, () {
      if (!mounted || mine != attempt || !busy) return;
      setState(() => slowNote =
          'Still waiting. If the server has been idle it can take up to a '
          'minute to wake up.');
    });
  }

  void clearSlowHint() {
    attempt++;
    slowNote = null;
  }

  Future<void> login() async {
    if (!formKey.currentState!.validate()) return;

    setState(() {
      busy = true;
      error = null;
      slowNote = null;
    });
    startSlowHint();

    final result = await Api.instance.login(
      email: emailController.text.trim(),
      password: passwordController.text,
    );

    if (!mounted) return;

    if (!result.ok || result.session == null) {
      setState(() {
        busy = false;
        clearSlowHint();
        error = result.message ?? 'Could not sign in.';
      });
      return;
    }
    clearSlowHint();

    await SessionStore.instance.save(result.session!);
    Api.instance.signedOut = false;

    // Pull from the server before deciding where to go.
    //
    // Signing out clears this device -- it has to, because the next person to
    // sign in here may be a different account and the local tables carry no
    // owner column. So the local profile is *always* absent at this point,
    // even for someone who set one up months ago. Deciding from local state
    // alone therefore sent every returning user back through onboarding to
    // re-enter a profile the server already had, which is the bug this fixes.
    //
    // The sync restores the profile and the diary along with it: the cursor
    // was reset to 0 by the sign-out, so this pulls the account's whole
    // history back down.
    setState(() => slowNote = 'Restoring your profile and diary...');
    final restored = await Api.instance.sync();
    if (!mounted) return;
    setState(() => slowNote = null);

    if (!restored.ok) {
      // Signing in requires the server, so the network was working seconds
      // ago and a failure here is unlikely to be the connection. It still
      // must not be ignored: continuing would show onboarding to someone who
      // already has a profile, and the profile they typed would then
      // overwrite the real one on the server, because conflicts are settled
      // by whichever copy was written last.
      //
      // The underlying reason is shown rather than hidden behind a guess.
      // sync() reports every failure as if it were a network problem, which
      // once turned "no column named user_id" into "you appear to be
      // offline" and cost two days of looking in the wrong place.
      setState(() {
        busy = false;
        clearSlowHint();
        error = 'Signed in, but could not restore your profile from the '
            'server, so nothing has been changed. Try again in a moment.'
            '\n\nReason: ${restored.error ?? 'unknown'}';
      });
      return;
    }

    // Now the local copy reflects the account, so this is a real question
    // rather than one with a foregone answer.
    final profile = await LocalDb.instance.loadProfile();
    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => profile == null
            ? OnboardingScreen(
                email: result.session!.email,
                suggestedName: result.session!.name)
            : const Shell(),
      ),
      (route) => false,
    );
  }

  Future<void> openRegister() async {
    final session = await Navigator.push<Session>(
      context,
      MaterialPageRoute(builder: (context) => const RegisterScreen()),
    );
    if (!mounted || session == null) return;

    // Registration already signed them in and stored the token, so this goes
    // straight to setup rather than back to a form they have just filled.
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => OnboardingScreen(
            email: session.email, suggestedName: session.name),
      ),
      (route) => false,
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Welcome back',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),

                if (widget.notice != null) ...[
                  const SizedBox(height: 16),
                  WireNote(widget.notice!, warning: true),
                ],

                const SizedBox(height: 24),

                TextFormField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final text = (value ?? '').trim();
                    if (text.isEmpty ||
                        !text.contains('@') ||
                        !text.contains('.')) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 16),

                TextFormField(
                  controller: passwordController,
                  obscureText: hidePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => busy ? null : login(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(hidePassword
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => hidePassword = !hidePassword),
                    ),
                  ),
                  validator: (value) =>
                      (value ?? '').isEmpty ? 'Enter your password' : null,
                ),

                if (slowNote != null) ...[
                  const SizedBox(height: 16),
                  WireNote(slowNote!),
                ],

                if (error != null) ...[
                  const SizedBox(height: 16),
                  WireNote(error!, warning: true),
                ],

                const SizedBox(height: 24),

                ElevatedButton(
                  onPressed: busy ? null : login,
                  child: Text(busy ? 'Signing in...' : 'Sign in'),
                ),

                const SizedBox(height: 10),

                OutlinedButton(
                  onPressed: busy ? null : openRegister,
                  child: const Text('Create an account'),
                ),

                const SizedBox(height: 24),

                const WireNote(
                  'Your diary, profile and weights belong to your account and '
                  'are not shared with anyone else. Your password is never '
                  'stored: the server keeps a slow, salted hash that cannot '
                  'be reversed.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
