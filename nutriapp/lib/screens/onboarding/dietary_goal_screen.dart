import 'package:flutter/material.dart';

import '../../profile_fields.dart';

class DietaryGoalScreen extends StatelessWidget {
  // Current goal
  final String dietaryGoal;

  // Target weight input
  final TextEditingController targetController;

  // Function to notify the parent about a new goal
  final ValueChanged<String> onGoalChanged;

  const DietaryGoalScreen({
    super.key,
    required this.dietaryGoal,
    required this.targetController,
    required this.onGoalChanged,
  });

  @override
  Widget build(BuildContext context) {
    // goalOptions and goalUsesTargetWeight live in profile_fields.dart, so
    // this screen and the per-field editor on the profile tab offer the same
    // choices and agree on which goals carry a target weight.

    final bool showTargetWeight = goalUsesTargetWeight(dietaryGoal);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'What is your dietary goal?',
          style: TextStyle(
            fontSize: 24, 
            fontWeight: FontWeight.bold
          ),
        ),

        const SizedBox(height: 8),

        const Text(
          'Choose the goal that best describes you.',
        ),

        const SizedBox(height: 20),

        RadioGroup<String>(
          groupValue: dietaryGoal,
          onChanged: (value) {
            if (value != null) {
              onGoalChanged(value);
            }
          },
          child: Column(
            children: [
              for (final goal in goalOptions)
                Card(
                  child: RadioListTile<String>(
                    title: Text(goal),
                    value: goal,
                  ),
                ),
            ],
          )
        ),
          

        if (showTargetWeight) ...[
          const SizedBox(height: 20),
          TextField(
            controller: targetController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Target Weight (kg, optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }
}
