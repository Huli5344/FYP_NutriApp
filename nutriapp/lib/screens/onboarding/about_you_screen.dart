import 'package:flutter/material.dart';

class AboutYouScreen extends StatelessWidget {
  // Controllers received from the parent
  final TextEditingController ageController;
  final TextEditingController heightController;
  final TextEditingController weightController;

  // Current values received from the parent
  final String? gender;
  final String activityLevel;

  // Callback functions received from the parent
  final ValueChanged<String?> onGenderChanged;
  final ValueChanged<String> onActivityChanged;

  const AboutYouScreen({
    super.key,
    required this.ageController,
    required this.heightController,
    required this.weightController,
    required this.gender,
    required this.activityLevel,
    required this.onGenderChanged,
    required this.onActivityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Tell us about yourself',
          style: TextStyle(
            fontSize: 24, 
            fontWeight: FontWeight.bold
          ),
        ),

        const SizedBox(height: 8),

        const Text(
          'This information helps personalize your nutrition experience.',
        ),

        const SizedBox(height: 24),

        TextField(
          controller: ageController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Age',
            border: OutlineInputBorder(),
          ),
        ),

        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          initialValue: gender,
          decoration: const InputDecoration(
            labelText: 'Gender (optional)',
            border: OutlineInputBorder(),
          ),
          items: [
            'Female', 
            'Male', 
            'Non-binary', 
            'Prefer not to say'
          ].map((value) {
            return DropdownMenuItem(
              value: value,
              child: Text(value),
            );
          }).toList(),
          onChanged: onGenderChanged, 
        ),

        const SizedBox(height: 16),

        TextField(
          controller: heightController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Height (cm)',
            border: OutlineInputBorder(),
          ),
        ),

        const SizedBox(height: 16),

        TextField(
          controller: weightController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Current weight (kg)',
            border: OutlineInputBorder(),
          ),
        ),

        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          initialValue: activityLevel,
          decoration: const InputDecoration(
            labelText: 'Activity Level',
            border: OutlineInputBorder(),
          ),
          items: [
            'Sedentary',
            'Lightly Active',
            'Moderately Active',
            'Very Active',
          ].map((value) {
            return DropdownMenuItem(
              value: value,
              child: Text(value),
            );
          }).toList(),
          
          onChanged: (value) {
            if (value != null) {
              onActivityChanged(value);
            }
          },
        ),
      ],
    );
  }
}
