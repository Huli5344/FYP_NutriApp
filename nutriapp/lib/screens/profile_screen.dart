/// Profile and Goals.
///
/// The tab that was inert. It shows what was saved during setup, explains how
/// the calorie target was arrived at, and lets both be changed — which matters
/// because onboarding runs once, and without this screen a profile could be
/// entered but never corrected.
///
/// Each field is edited on its own. Correcting a mistyped height used to mean
/// walking the whole setup flow again -- five screens and every answer
/// re-confirmed, to change one number. The flow still runs for a profile that
/// does not exist yet, where the order teaches what is being asked and why;
/// it is the wrong shape for a correction.
///
/// The risk in having two ways to edit the same fields is that they drift:
/// the bounds get written twice and one copy is widened. So neither path
/// carries its own rules. Both read profile_fields.dart, which holds the
/// options, the bounds and the messages, and every save here goes through
/// `applyProfileChange`, which rebuilds the derived values rather than
/// letting a new height sit beside a target computed from the old one.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../profile_fields.dart';
import '../session.dart';
import '../ui.dart';
import 'edit_field_screen.dart';
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

  /// The guided flow. Still used to create a profile that does not exist,
  /// and offered as "Review everything" for anyone who would rather be walked
  /// through all of it than tap fields one at a time.
  Future<void> _runSetupFlow() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => OnboardingScreen(existing: _profile)),
    );
    if (changed == true) _load();
  }

  // -------------------------------------------------------------------------
  // Editing one field
  //
  // Every one of these ends at `_apply`, and none of them writes a profile
  // itself. That is what keeps a changed height from leaving a calorie target
  // behind that was computed from the old one.
  // -------------------------------------------------------------------------

  /// Save a rebuilt profile and redraw.
  Future<void> _apply(UserProfile updated) async {
    await LocalDb.instance.saveProfile(updated);
    await _load();
  }

  Future<void> _editName() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await editValue(
      context,
      title: 'Name',
      label: 'Name',
      initial: profile.name,
      validate: validateName,
      keyboard: TextInputType.name,
    );
    if (result == null) return;
    await _apply(applyProfileChange(profile, name: result.trim()));
  }

  Future<void> _editAge() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await editValue(
      context,
      title: 'Age',
      label: 'Age',
      initial: '${profile.age}',
      validate: validateAge,
      help: 'Used with your height, weight and activity level to estimate '
          'what your body uses at rest.',
      suffix: 'years',
      keyboard: TextInputType.number,
    );
    if (result == null) return;
    await _apply(applyProfileChange(profile, age: int.parse(result.trim())));
  }

  Future<void> _editHeight() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await editValue(
      context,
      title: 'Height',
      label: 'Height',
      initial: '${profile.heightCm}',
      validate: validateHeight,
      suffix: 'cm',
      keyboard: const TextInputType.numberWithOptions(decimal: true),
    );
    if (result == null) return;
    await _apply(
        applyProfileChange(profile, heightCm: double.parse(result.trim())));
  }

  Future<void> _editGender() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await chooseOne(
      context,
      title: 'Gender',
      options: genderOptions,
      current: profile.gender,
      help: 'Affects the resting-burn estimate. "Prefer not to say" uses an '
          'average of the two formulas.',
    );
    if (result == null) return;
    await _apply(applyProfileChange(profile, gender: result));
  }

  Future<void> _editActivity() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await chooseOne(
      context,
      title: 'Activity level',
      options: activityOptions,
      current: profile.activityLevel,
      help: 'Scales the resting-burn estimate into a daily figure.',
    );
    if (result == null) return;
    await _apply(applyProfileChange(profile, activityLevel: result));
  }

  Future<void> _editGoal() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await chooseOne(
      context,
      title: 'Goal',
      options: goalOptions,
      current: profile.goal,
    );
    if (result == null || result == profile.goal) return;
    // `chooseOne` was awaited, so this screen may have gone away while the
    // dialog was open. Everything below uses `context` again.
    if (!mounted) return;

    // Said out loud rather than done silently. A target weight belongs to a
    // goal that is about reaching a weight; changing to one that is not
    // clears it, and somebody who had entered 68 kg should find out here
    // rather than by noticing it gone.
    if (!goalUsesTargetWeight(result) && profile.targetWeightKg != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear your target weight?'),
          content: Text(
              '"$result" is not about reaching a particular weight, so your '
              'target of ${profile.targetWeightKg} kg will be cleared. You '
              'can set it again if you change goal later.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Change goal'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    await _apply(applyProfileChange(profile, goal: result));
  }

  Future<void> _editTargetWeight() async {
    final profile = _profile;
    if (profile == null) return;

    if (!goalUsesTargetWeight(profile.goal)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('A target weight applies to goals about reaching a '
            'weight. Your goal is "${profile.goal}".'),
      ));
      return;
    }

    final result = await editValue(
      context,
      title: 'Target weight',
      label: 'Target weight',
      initial: profile.targetWeightKg == null
          ? ''
          : '${profile.targetWeightKg}',
      validate: validateTargetWeight,
      help: 'What you are working towards. Leave it empty if you would '
          'rather not set one.',
      suffix: 'kg',
      keyboard: const TextInputType.numberWithOptions(decimal: true),
      clearLabel: profile.targetWeightKg == null ? null : 'Clear',
    );
    if (result == null) return;

    final trimmed = result.trim();
    await _apply(applyProfileChange(profile,
        targetWeightKg: trimmed.isEmpty ? null : double.parse(trimmed)));
  }

  Future<void> _editPreferences() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => EditChoicesScreen(
          title: 'Preferences',
          description: 'How you prefer to eat. Suggestions are narrowed to '
              'match. Select all that apply.',
          options: preferenceOptions,
          selected: profile.preferences,
        ),
      ),
    );
    if (result == null) return;
    await _apply(applyProfileChange(profile, preferences: result));
  }

  Future<void> _editRestrictions() async {
    final profile = _profile;
    if (profile == null) return;
    final result = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => EditChoicesScreen(
          title: 'Restrictions',
          description: 'Foods you need to avoid. Meals listing any of these '
              'are removed before anything is ranked.',
          options: restrictionOptions,
          selected: profile.restrictions,
          warning: true,
          footnote: (chosen) => 'Matched against recipes tagged '
              '${normaliseAllergens(chosen).join(', ')}.',
        ),
      ),
    );
    if (result == null) return;
    await _apply(applyProfileChange(profile, restrictions: result));
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

    final message = validateDailyTarget(result);
    if (message != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final value = int.parse(result.trim());

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

    final message = validateWeight(result);
    if (message != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final kg = double.parse(result.trim());

    await LocalDb.instance.logWeight(kg);

    // The new weight changes the calculated target, so the profile is rebuilt
    // rather than left describing a body that has changed. A target set by
    // hand is preserved, which is what buildProfile's manual argument is for.
    await _apply(applyProfileChange(profile, weightKg: kg));
  }

  /// A diet sub-heading with an edit control beside it.
  Widget _dietHeading(String label, VoidCallback onEdit) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: tLabel),
        InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(4),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text('Edit',
                style: TextStyle(fontSize: 13, color: AppColors.accent)),
          ),
        ),
      ],
    );
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
              WireButton(label: 'Set up my profile', onPressed: _runSetupFlow),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          // Tapping a field edits that field. This stays for anyone who
          // would rather be walked through every answer in order, which is
          // also the only way to revisit the explanations the setup flow
          // gives for each question.
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'setup') _runSetupFlow();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: 'setup', child: Text('Review everything')),
            ],
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
                WireField(
                    label: 'Goal', value: profile.goal, onTap: _editGoal),
                WireField(
                    label: 'Target weight',
                    value: !goalUsesTargetWeight(profile.goal)
                        ? 'Not used for this goal'
                        : profile.targetWeightKg == null
                            ? 'Not set'
                            : '${profile.targetWeightKg} kg',
                    onTap: _editTargetWeight),
                WireField(
                    label: 'Current weight',
                    value: '${profile.weightKg} kg',
                    onTap: _logWeight),
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
                WireField(
                    label: 'Name', value: profile.name, onTap: _editName),
                WireField(
                    label: 'Age', value: '${profile.age}', onTap: _editAge),
                WireField(
                    label: 'Gender',
                    value: profile.gender ?? 'Not specified',
                    onTap: _editGender),
                WireField(
                    label: 'Height',
                    value: '${profile.heightCm} cm',
                    onTap: _editHeight),
                WireField(
                    label: 'Activity',
                    value: profile.activityLevel,
                    onTap: _editActivity,
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
                _dietHeading('Preferences', _editPreferences),
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
                _dietHeading('Restrictions', _editRestrictions),
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
          const SizedBox(height: 16),
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
          style: TextButton.styleFrom(foregroundColor: AppColors.bad),
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
