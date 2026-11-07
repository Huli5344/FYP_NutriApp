/// Profile setup.
///
/// Five steps, then a save. The same screen is reused to edit an existing
/// profile: pass `existing` and the fields arrive filled in, which is why
/// there is no separate edit form to keep in step with this one.
///
/// Nothing here calculates anything. The answers are handed to buildProfile in
/// logic.dart, which owns the translation into allergen tokens, diet tokens and
/// a calorie target.
library;

import 'package:flutter/material.dart';

import '../../db.dart';
import '../../logic.dart';
import '../../models.dart';
import 'about_you_screen.dart';
import 'dietary_goal_screen.dart';
import 'dietary_preferences_screen.dart';
import 'dietary_restrictions_screen.dart';
import 'profile_review_screen.dart';
import '../../main.dart';

class OnboardingScreen extends StatefulWidget {
  /// The profile being edited, or null when setting one up for the first time.
  final UserProfile? existing;

  /// Email of the signed-in account, used when there is no profile yet.
  final String email;

  /// Name collected by the register screen, if the user came that way.
  final String? suggestedName;

  const OnboardingScreen({
    super.key,
    this.existing,
    this.email = '',
    this.suggestedName,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const int _steps = 5;

  // Page navigation
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _saving = false;

  // Personal information
  final nameController = TextEditingController();
  final ageController = TextEditingController();
  final heightController = TextEditingController();
  final weightController = TextEditingController();
  final targetController = TextEditingController();

  String? gender;
  String activityLevel = 'Moderately Active';

  // Dietary information
  String dietaryGoal = 'Eat Healthier';

  final List<String> selectedPreferences = [];
  final List<String> selectedRestrictions = [];

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      nameController.text = existing.name;
      ageController.text = '${existing.age}';
      heightController.text = _trim(existing.heightCm);
      weightController.text = _trim(existing.weightKg);
      targetController.text = existing.targetWeightKg == null
          ? ''
          : _trim(existing.targetWeightKg!);
      gender = existing.gender;
      activityLevel = existing.activityLevel;
      dietaryGoal = existing.goal;
      selectedPreferences.addAll(existing.preferences);
      selectedRestrictions.addAll(existing.restrictions);
    } else if (widget.suggestedName != null) {
      nameController.text = widget.suggestedName!;
    }
  }

  /// 170.0 reads better as "170" on a form someone is about to edit.
  static String _trim(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  bool get _goalUsesTargetWeight =>
      dietaryGoal == 'Lose Weight' ||
      dietaryGoal == 'Gain Weight' ||
      dietaryGoal == 'Build Muscle';

  // Navigate forward
  void nextPage() {
    if (_currentPage == 0) {
      final name = nameController.text.trim();
      final age = int.tryParse(ageController.text);
      final height = double.tryParse(heightController.text);
      final weight = double.tryParse(weightController.text);

      if (name.isEmpty) {
        _complain('Please enter your name.');
        return;
      }
      // Bounds are deliberately wide. They exist to catch a typed-in
      // centimetre value in the kilogram box, not to judge anyone's body.
      if (age == null || age < 13 || age > 120) {
        _complain('Please enter an age between 13 and 120.');
        return;
      }
      if (height == null || height < 90 || height > 250) {
        _complain('Please enter a height in centimetres, between 90 and 250.');
        return;
      }
      if (weight == null || weight < 25 || weight > 400) {
        _complain('Please enter a weight in kilograms, between 25 and 400.');
        return;
      }
    }

    if (_currentPage == 1 &&
        _goalUsesTargetWeight &&
        targetController.text.trim().isNotEmpty) {
      final target = double.tryParse(targetController.text);
      if (target == null || target < 25 || target > 400) {
        _complain('Please enter a target weight in kilograms, or leave it '
            'empty.');
        return;
      }
    }

    if (_currentPage < _steps - 1) {
      _pageController.animateToPage(
        _currentPage + 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      finishOnboarding();
    }
  }

  // Navigate backward
  void previousPage() {
    if (_currentPage > 0) {
      _pageController.animateToPage(
        _currentPage - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // Update a multiple-choice selection
  void toggleSelection(List<String> list, String value) {
    setState(() {
      if (list.contains(value)) {
        list.remove(value);
      } else {
        list.add(value);
      }
    });
  }

  void _complain(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The target the current answers imply, for the review step.
  ///
  /// Returns null while the measurements are incomplete, so the review can say
  /// so rather than show a figure derived from zeroes.
  int? get _previewTarget {
    final age = int.tryParse(ageController.text);
    final height = double.tryParse(heightController.text);
    final weight = double.tryParse(weightController.text);
    if (age == null || height == null || weight == null) return null;
    return dailyTargetFor(
      age: age,
      heightCm: height,
      weightKg: weight,
      activityLevel: activityLevel,
      goal: dietaryGoal,
      gender: gender,
    );
  }

  // Finish onboarding
  Future<void> finishOnboarding() async {
    if (_saving) return; // a second tap must not write two profiles
    setState(() => _saving = true);

    final existing = widget.existing;
    final weight = double.parse(weightController.text);

    final profile = buildProfile(
      name: nameController.text.trim(),
      email: existing?.email ?? widget.email,
      age: int.parse(ageController.text),
      gender: gender,
      heightCm: double.parse(heightController.text),
      weightKg: weight,
      activityLevel: activityLevel,
      goal: dietaryGoal,
      targetWeightKg: _goalUsesTargetWeight &&
              targetController.text.trim().isNotEmpty
          ? double.parse(targetController.text)
          : null,
      preferences: selectedPreferences,
      restrictions: selectedRestrictions,
      // A target set by hand is kept through an edit. Someone who overrode the
      // figure once should not have it silently recalculated because they
      // corrected their height.
      manualTargetKcal:
          (existing != null && existing.targetIsManual) ? existing.targetKcal : null,
    );

    await LocalDb.instance.saveProfile(profile);

    // Seed the weight log from the stated weight, so the trend on Insights has
    // a starting point without asking for the same number twice.
    final log = await LocalDb.instance.weightLog(limit: 1);
    if (log.isEmpty) {
      await LocalDb.instance.logWeight(weight, note: 'From profile setup');
    } else if (existing != null && existing.weightKg != weight) {
      await LocalDb.instance.logWeight(weight, note: 'Updated in profile');
    }

    if (!mounted) return;

    if (_editing) {
      Navigator.pop(context, true);
      return;
    }

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const Shell()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    nameController.dispose();
    ageController.dispose();
    heightController.dispose();
    weightController.dispose();
    targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lastPage = _currentPage == _steps - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit profile' : 'Profile Setup'),
      ),

      body: SafeArea(
        child: Column(
          children: [
            // Progress
            Padding(
              padding: const EdgeInsets.all(16),
              child: LinearProgressIndicator(
                value: (_currentPage + 1) / _steps,
                minHeight: 6,
                color: const Color(0xFF4CAF50),
                backgroundColor: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(10),
              ),
            ),

            Text('Step ${_currentPage + 1} of $_steps'),

            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),

                onPageChanged: (page) {
                  setState(() {
                    _currentPage = page;
                  });
                },

                children: [
                  AboutYouScreen(
                    nameController: nameController,
                    ageController: ageController,
                    heightController: heightController,
                    weightController: weightController,
                    gender: gender,
                    activityLevel: activityLevel,
                    onGenderChanged: (value) {
                      setState(() => gender = value);
                    },
                    onActivityChanged: (value) {
                      setState(() => activityLevel = value);
                    },
                  ),

                  DietaryGoalScreen(
                    dietaryGoal: dietaryGoal,
                    targetController: targetController,
                    onGoalChanged: (value) {
                      setState(() {
                        dietaryGoal = value;
                      });
                    },
                  ),

                  DietaryPreferencesScreen(
                    selectedPreferences: selectedPreferences,
                    onPreferenceToggled: (value) {
                      toggleSelection(selectedPreferences, value);
                    },
                  ),

                  DietaryRestrictionsScreen(
                    selectedRestrictions: selectedRestrictions,
                    onRestrictionToggled: (value) {
                      toggleSelection(selectedRestrictions, value);
                    },
                  ),

                  ProfileReviewScreen(
                    name: nameController.text,
                    age: ageController.text,
                    gender: gender,
                    height: heightController.text,
                    weight: weightController.text,
                    targetWeight: targetController.text,
                    activityLevel: activityLevel,
                    dietaryGoal: dietaryGoal,
                    preferences: selectedPreferences,
                    restrictions: selectedRestrictions,
                    dailyTarget: _previewTarget,
                  ),
                ],
              ),
            ),

            // BACK AND CONTINUE BUTTONS
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_currentPage > 0) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving ? null : previousPage,
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _saving ? null : nextPage,
                      child: Text(
                        _saving
                            ? 'Saving...'
                            : lastPage
                                ? (_editing ? 'Save changes' : 'Finish')
                                : 'Continue',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
