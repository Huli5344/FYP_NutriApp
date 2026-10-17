import 'package:flutter/material.dart';

import 'about_you_screen.dart';
import 'dietary_goal_screen.dart';
import 'dietary_preferences_screen.dart';
import 'dietary_restrictions_screen.dart';
import 'profile_review_screen.dart';
import '../../main.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  // Page navigation
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Personal information
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

  // Navigate forward
  void nextPage() {
    if (_currentPage == 0) {
      final age = int.tryParse(ageController.text);
      final height = double.tryParse(heightController.text);
      final weight = double.tryParse(weightController.text);

      if (age == null || age < 18 || age > 120 ||
          height == null || height <= 0 ||
          weight == null || weight <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter valid personal information.'),
          ),
        );
        return;
      }
    }

    if (_currentPage == 1) {
      final usesTarget = dietaryGoal == 'Lose Weight' ||
          dietaryGoal == 'Gain Weight' ||
          dietaryGoal == 'Build Muscle';
      
      if (usesTarget && targetController.text.trim().isNotEmpty) {
        final target = double.tryParse(targetController.text);

        if (target == null || target <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please enter a valid target weight.'),
            ),
          );
          return;
        }
      }
    }

    if (_currentPage < 4) {
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

  // Finish onboarding
  void finishOnboarding() {
    final usesTarget = dietaryGoal == 'Lose Weight' ||
        dietaryGoal == 'Gain Weight' ||
        dietaryGoal == 'Build Muscle';

    final profile = <String, Object?>{
      'age': int.parse(ageController.text),
      'gender': gender,
      'heightCm': double.parse(heightController.text),
      'weightKg': double.parse(weightController.text),
      'activityLevel': activityLevel,
      'dietaryGoal': dietaryGoal,
      'targetWeightKg': usesTarget &&
              targetController.text.trim().isNotEmpty
          ? double.parse(targetController.text)
          : null,
      'preferences': List<String>.of(selectedPreferences),
      'restrictions': List<String>.of(selectedRestrictions),
    };

    debugPrint('Completed profile: $profile');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Profile setup completed!'),
      ),
    );

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => const Shell()
      ),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    ageController.dispose();
    heightController.dispose();
    weightController.dispose();
    targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile Setup'),
      ),

      body: SafeArea(
        child: Column(
          children: [
            // Progress
            Padding(
              padding: const EdgeInsets.all(16),
              child: LinearProgressIndicator(
                value: (_currentPage + 1) / 5,
                minHeight: 6,
                color: const Color(0xFF4CAF50),
                backgroundColor: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(10),
              ),
            ),

            Text('Step ${_currentPage + 1} of 5'),

            // FIVE ONBOARDING SCREENS
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
                    age: ageController.text,
                    gender: gender,
                    height: heightController.text,
                    weight: weightController.text,
                    targetWeight: targetController.text,
                    activityLevel: activityLevel,
                    dietaryGoal: dietaryGoal,
                    preferences: selectedPreferences,
                    restrictions: selectedRestrictions,
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
                        onPressed: previousPage,
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white
                      ),
                      onPressed: nextPage,
                      child: Text(
                        _currentPage == 4 ? 'Finish' : 'Continue',
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
