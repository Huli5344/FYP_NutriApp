import 'package:flutter/material.dart';

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
    final List<String> goals = [
      'Lose Weight',
      'Maintain Weight',
      'Gain Weight',
      'Build Muscle',
      'Eat Healthier',
    ];

    final bool showTargetWeight =
        dietaryGoal == 'Lose Weight' ||
        dietaryGoal == 'Gain Weight' ||
        dietaryGoal == 'Build Muscle';

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
              for (final goal in goals)
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
