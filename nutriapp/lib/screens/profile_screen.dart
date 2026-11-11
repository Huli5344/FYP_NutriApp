/// Profile and Goals.
///
/// The tab that was inert. It shows what was saved during setup, explains how
/// the calorie target was arrived at, and lets both be changed — which matters
/// because onboarding runs once, and without this screen a profile could be
/// entered but never corrected.
///
/// Editing reuses the onboarding flow rather than duplicating it as a second
/// form. Two forms over the same fields drift apart; the validation rules would
/// have to be written twice and would eventually disagree.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../session.dart';
import '../ui.dart';
import 'login_screen.dart';
import 'onboarding/onboarding_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  UserProfile? _profile;
  List<WeightEntry> _weights = [];
  bool _loading = true;
  String? _syncNote;

  /// True while sign-out is pushing pending changes, which disables both
  /// account buttons so a second tap cannot race the first.
  bool _signingOut = false;

  /// The signed-in account, for the address shown under Account.
  ///
  /// The profile carries an email too, but it was typed during setup and can
  /// be left blank; the session's address is the one the server authenticated.
  Session? _session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await LocalDb.instance.loadProfile();
    final weights = await LocalDb.instance.weightLog(limit: 10);
    final session = await SessionStore.instance.load();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _weights = weights;
      _session = session;
      _loading = false;
    });
  }

  Future<void> _edit() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => OnboardingScreen(existing: _profile)),
    );
    if (changed == true) _load();
  }

  /// Override the generated target, or go back to it.
  Future<void> _editTarget() async {
    final profile = _profile;
    if (profile == null) return;

    final controller =
        TextEditingController(text: '${profile.targetKcal}');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Daily calorie target'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Your measurements and goal work out to '
                '${profile.computedTargetKcal} kcal. You can set a different '
                'figure if you have been advised one.',
                style: tMute),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'kcal a day'),
            ),
          ],
        ),
        actions: [
          if (profile.targetIsManual)
            TextButton(
              onPressed: () => Navigator.pop(context, 'reset'),
              child: const Text('Use calculated'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == null) return;

    if (result == 'reset') {
      await LocalDb.instance.saveProfile(profile.copyWith(
        targetKcal: profile.computedTargetKcal,
        targetIsManual: false,
        updatedAt: DateTime.now().toUtc(),
      ));
      _load();
      return;
    }

    final value = int.tryParse(result.trim());
    if (value == null || value < minDailyTarget || value > maxDailyTarget) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter a target between $minDailyTarget and '
            '$maxDailyTarget kcal.'),
      ));
      return;
    }

    await LocalDb.instance.saveProfile(profile.copyWith(
      targetKcal: value,
      targetIsManual: true,
      updatedAt: DateTime.now().toUtc(),
    ));
    _load();
  }

  Future<void> _logWeight() async {
    final profile = _profile;
    if (profile == null) return;

    final controller = TextEditingController(text: '${profile.weightKg}');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Today's weight"),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'kg'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;

    final kg = double.tryParse(result.trim());
    if (kg == null || kg < 25 || kg > 400) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter a weight in kilograms, between 25 and 400.'),
      ));
      return;
    }

    await LocalDb.instance.logWeight(kg);

    // The new weight changes the calculated target, so the profile is rebuilt
    // rather than left describing a body that has changed. A target set by
    // hand is preserved, which is what buildProfile's manual argument is for.
    final rebuilt = buildProfile(
      name: profile.name,
      email: profile.email,
      age: profile.age,
      gender: profile.gender,
      heightCm: profile.heightCm,
      weightKg: kg,
      activityLevel: profile.activityLevel,
      goal: profile.goal,
      targetWeightKg: profile.targetWeightKg,
      preferences: profile.preferences,
      restrictions: profile.restrictions,
      manualTargetKcal: profile.targetIsManual ? profile.targetKcal : null,
    );
    await LocalDb.instance.saveProfile(rebuilt);
    _load();
  }

  Future<void> _syncNow() async {
    setState(() => _syncNote = 'Syncing...');
    final result = await Api.instance.sync();
    if (!mounted) return;
    setState(() {
      _syncNote = result.ok
          ? 'Synced. Sent ${result.pushed}, received ${result.pulled}.'
          : 'Could not reach the server. Everything is still saved on this '
              'device.';
    });
  }

  /// Sign out of this device.
  ///
  /// Signing out clears the local diary, because the next person to sign in
  /// on this phone may be a different account and the local tables carry no
  /// owner column. That makes it destructive, so it does two things first:
  /// pushes whatever is pending, then counts what still has not reached the
  /// server and says the number out loud in the confirmation. Losing a day
  /// of meals to a tap is the failure worth the extra round trip.
  Future<void> _signOut() async {
    // Captured here, synchronously, while this widget is certainly still
    // mounted. Everything below crosses an await -- the sync, then the
    // dialog -- and Navigator.of(context) after one of those throws if the
    // screen has gone away in the meantime. An earlier version of this
    // method captured it after the dialog and claimed in a comment to be
    // doing exactly what it was not; `flutter analyze` caught it.
    final navigator = Navigator.of(context);

    setState(() {
      _signingOut = true;
      _syncNote = 'Saving your changes to your account...';
    });

    // Best effort. A failure here is not fatal -- it just means the warning
    // below will have a number in it.
    await Api.instance.sync();
    final pending = await LocalDb.instance.pendingCount();
    if (!mounted) return;
    setState(() {
      _signingOut = false;
      _syncNote = null;
    });

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(pending == 0
            ? 'Everything on this device has been saved to your account. '
                'Signing out clears it from this phone; signing back in '
                'brings it down again.'
            : '$pending change${pending == 1 ? '' : 's'} could not be sent to '
                'your account, so they exist only on this phone. Signing out '
                'clears this phone, which would lose them. Cancel, get a '
                'connection, and tap Sync now first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(pending == 0 ? 'Sign out' : 'Sign out anyway'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Asks the server to revoke the token, then forgets it locally. The local
    // half runs even if the request fails, because the user asked to be
    // signed out of this device and an unreachable server is not a reason to
    // leave them signed in here.
    await Api.instance.logout();
    await SessionStore.instance.clear();

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  /// Delete the account on the server, then this device.
  ///
  /// This replaced a "Start over" button that only cleared the phone. That
  /// was misleading in the one direction that matters: someone pressing it
  /// to remove their data left the account, the email and every meal sitting
  /// on the server, and had no way to tell.
  ///
  /// The password is asked for again here, and checked again on the server.
  /// The token already in the headers proves a session, not a person -- an
  /// unlocked phone is enough to have one -- and this is the last gate in
  /// front of something with no undo.
  Future<void> _deleteAccount() async {
    final navigator = Navigator.of(context);
    final password = await showDialog<String>(
      context: context,
      builder: (context) => const _DeleteAccountDialog(),
    );
    if (password == null || password.isEmpty) return;

    setState(() {
      _signingOut = true;
      _syncNote = 'Deleting your account...';
    });

    final failure = await Api.instance.deleteAccount(password);
    if (!mounted) return;

    if (failure != null) {
      setState(() {
        _signingOut = false;
        _syncNote = null;
      });
      // Nothing was deleted, so the screen stays exactly as it was.
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
      return;
    }

    // The account is gone, so the local copy is now the only trace of it and
    // has no account to belong to. clear() wipes the diary as well as the
    // token, which is what is wanted here -- unlike a sign-out, there is
    // nothing left to sync it back to.
    await SessionStore.instance.clear();

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const LoginScreen(
          notice: 'Your account and everything in it have been deleted. '
              'You can create a new one with the same email if you want to '
              'start again.',
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final profile = _profile;
    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const WireNote(
                  'No profile saved yet. Setting one up is what gives you a '
                  'calorie target and filters suggestions.'),
              const SizedBox(height: 12),
              WireButton(label: 'Set up my profile', onPressed: _edit),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          TextButton(
            onPressed: _edit,
            child: const Text('Edit', style: TextStyle(color: AppColors.mute)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _targetPanel(profile),
          const SizedBox(height: 12),
          const Text('Goal', style: tHead),
          const SizedBox(height: 6),
          WireCard(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                WireField(label: 'Goal', value: profile.goal),
                WireField(
                    label: 'Target weight',
                    value: profile.targetWeightKg == null
                        ? 'Not set'
                        : '${profile.targetWeightKg} kg'),
                WireField(
                    label: 'Current weight', value: '${profile.weightKg} kg'),
                WireField(
                    label: 'Macro split',
                    value: _splitPhrase(macroSplitFor(profile.goal)),
                    last: true),
              ],
            ),
          ),
          const SizedBox(height: 10),
          WireButton(
              label: "Log today's weight",
              outlined: true,
              small: true,
              onPressed: _logWeight),
          if (_weights.isNotEmpty) ...[
            const SizedBox(height: 10),
            WireCard(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                children: [
                  for (final w in _weights)
                    WireRow(
                      title: '${w.kg} kg',
                      subtitle: w.note.isEmpty
                          ? DateFormat('EEEE d MMMM').format(w.recordedAt)
                          : '${DateFormat('d MMM').format(w.recordedAt)} · '
                              '${w.note}',
                      last: w == _weights.last,
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text('About you', style: tHead),
          const SizedBox(height: 6),
          WireCard(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                WireField(label: 'Name', value: profile.name),
                WireField(label: 'Age', value: '${profile.age}'),
                WireField(
                    label: 'Gender', value: profile.gender ?? 'Not specified'),
                WireField(label: 'Height', value: '${profile.heightCm} cm'),
                WireField(
                    label: 'Activity',
                    value: profile.activityLevel,
                    last: true),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text('Diet', style: tHead),
          const SizedBox(height: 6),
          WireCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Preferences', style: tLabel),
                const SizedBox(height: 6),
                if (profile.preferences.isEmpty)
                  const Text('None chosen. Suggestions are not narrowed.',
                      style: tMute)
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in profile.preferences) WireChip(p),
                    ],
                  ),
                const SizedBox(height: 12),
                const Text('Restrictions', style: tLabel),
                const SizedBox(height: 6),
                if (profile.restrictions.isEmpty)
                  const Text('None recorded. Nothing is filtered out.',
                      style: tMute)
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final r in profile.restrictions)
                        WireChip(r, warning: true),
                    ],
                  ),
                if (profile.restrictions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  // Shows the translation rather than hiding it. The screen
                  // says "Dairy"; the recipe data says "milk"; this is where
                  // someone can see that the two were connected.
                  WireNote('Matched against recipes tagged '
                      '${profile.allergens.join(', ')}. Meals listing any of '
                      'these are removed before anything is ranked.'),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text('Account', style: tHead),
          const SizedBox(height: 6),
          WireCard(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                WireField(
                    label: 'Signed in as',
                    value: profile.email.isEmpty
                        ? (_session?.email ?? 'Not signed in')
                        : profile.email),
                WireField(
                    label: 'Profile updated',
                    value: DateFormat('d MMM, HH:mm')
                        .format(profile.updatedAt.toLocal()),
                    last: true),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const WireNote(
              'Your password is never stored anywhere -- the server keeps a '
              'slow salted hash of it. Your profile and diary live on this '
              'device and sync to your account when a connection is '
              'available.'),
          const SizedBox(height: 12),
          WireButton(
              label: 'Sync now', outlined: true, small: true, onPressed: _syncNow),
          if (_syncNote != null) ...[
            const SizedBox(height: 8),
            Text(_syncNote!, style: tMute),
          ],
          const SizedBox(height: 20),
          WireButton(
              label: _signingOut ? 'Signing out...' : 'Sign out',
              outlined: true,
              small: true,
              onPressed: _signingOut ? null : _signOut),
          const SizedBox(height: 10),
          WireButton(
              label: 'Delete account',
              danger: true,
              small: true,
              onPressed: _signingOut ? null : _deleteAccount),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  /// The calorie target, with the working shown.
  Widget _targetPanel(UserProfile profile) {
    final bmr = basalMetabolicRate(
      age: profile.age,
      heightCm: profile.heightCm,
      weightKg: profile.weightKg,
      gender: profile.gender,
    );
    final multiplier =
        activityMultipliers[profile.activityLevel] ?? defaultActivityMultiplier;
    final maintenance = (bmr * multiplier).round();
    final adjustment = goalAdjustments[profile.goal] ?? 0;
    // Built up here rather than nested inside the interpolation below, where
    // three levels of quoting would be legal but unreadable.
    final goalClause = adjustment == 0
        ? ''
        : ', ${adjustment > 0 ? '+' : ''}$adjustment for '
            '${profile.goal.toLowerCase()}';

    return WireCard(
      onTap: _editTarget,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${profile.targetKcal}', style: tBig),
                    const Text('kcal a day', style: tMute),
                  ],
                ),
              ),
              WireChip(profile.targetIsManual ? 'Set by you' : 'Calculated',
                  filled: profile.targetIsManual),
            ],
          ),
          const SizedBox(height: 10),
          // Spelled out because a number a person is asked to live by should
          // not arrive unexplained.
          Text(
            'Resting burn about $bmr kcal, '
            '× $multiplier for ${profile.activityLevel.toLowerCase()} '
            '≈ $maintenance kcal to maintain$goalClause. '
            'Calculated: ${profile.computedTargetKcal} kcal.',
            style: tMute,
          ),
          const SizedBox(height: 8),
          const Text('Select to change it.', style: tLabel),
        ],
      ),
    );
  }

  static String _splitPhrase(List<double> split) =>
      '${(split[0] * 100).round()}% carbs · '
      '${(split[1] * 100).round()}% protein · '
      '${(split[2] * 100).round()}% fat';
}

/// Asks for the password before deleting an account.
///
/// A widget of its own rather than a bare AlertDialog, because it holds a
/// text field and therefore state, and because the dialog has to dispose its
/// controller. Pops the typed password, or null if cancelled.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _controller.text;
    if (password.isEmpty) return;
    Navigator.pop(context, password);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your account, your diary, your weight '
            'log and your profile -- from this phone and from the server. '
            'Any other device signed in to this account is signed out.\n\n'
            'It cannot be undone. There is no backup.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: _hidden,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Confirm your password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _hidden ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
