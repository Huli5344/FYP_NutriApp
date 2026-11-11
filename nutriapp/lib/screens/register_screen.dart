/// Create an account.
///
/// This used to be a stub that validated three fields and discarded them.
/// It now posts to /api/register, which creates the user, hashes the password
/// with PBKDF2 and a per-user salt, and returns a session token.
///
/// On success it pops the new session back to the sign-in screen, which sends
/// the user straight into profile setup rather than asking them to type the
/// credentials they just chose.
library;

import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../ui.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final formKey = GlobalKey<FormState>();

  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool busy = false;
  String? error;

  /// Matches the server's rule in accounts.py. Checked here too so an obvious
  /// mistake does not need a round trip, but the server's check is the one
  /// that counts -- a client can be bypassed.
  static const int minPasswordLength = 8;

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

  Future<void> register() async {
    if (!formKey.currentState!.validate()) return;

    setState(() {
      busy = true;
      error = null;
      slowNote = null;
    });
    startSlowHint();

    final result = await Api.instance.register(
      email: emailController.text.trim(),
      password: passwordController.text,
      name: nameController.text.trim(),
    );

    if (!mounted) return;

    if (!result.ok || result.session == null) {
      setState(() {
        busy = false;
        clearSlowHint();
        error = result.message ?? 'Could not create the account.';
      });
      return;
    }
    clearSlowHint();

    await SessionStore.instance.save(result.session!);
    Api.instance.signedOut = false;
    if (!mounted) return;
    Navigator.pop(context, result.session);
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create an account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Please enter your name'
                      : null,
                ),

                const SizedBox(height: 16),

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
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => busy ? null : register(),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    helperText: 'At least $minPasswordLength characters',
                  ),
                  validator: (value) => (value ?? '').length < minPasswordLength
                      ? 'Use at least $minPasswordLength characters'
                      : null,
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
                  onPressed: busy ? null : register,
                  child: Text(busy ? 'Creating...' : 'Create account'),
                ),

                const SizedBox(height: 10),

                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('I already have an account'),
                ),

                const SizedBox(height: 20),

                const WireNote(
                  'There is no email verification and no password reset in '
                  'this build, so use a password you will remember.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
