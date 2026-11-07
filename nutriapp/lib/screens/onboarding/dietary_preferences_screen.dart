import 'package:flutter/material.dart';

class DietaryPreferencesScreen extends StatelessWidget {
  // Selected values from parent
  final List<String> selectedPreferences;

  // Function to tell parent which option was tapped
  final ValueChanged<String> onPreferenceToggled;

  const DietaryPreferencesScreen({
    super.key,
    required this.selectedPreferences,  
    required this.onPreferenceToggled,
  });

  @override
  Widget build(BuildContext context) {
    final List<String> preferences = [
      // Every option here maps to a tag the recipe data actually carries, via
      // dietTokens in logic.dart. An option with no counterpart in the data
      // could be chosen and would then change nothing, which is worse than not
      // offering it.
      'Vegetarian',
      'Vegan',
      'Pescatarian',
      'Halal',
      'High protein',
      'High fibre',
      'Low carb',
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Dietary Preferences',
          style: TextStyle(
            fontSize: 24, 
            fontWeight: FontWeight.bold
          ),
        ),

        const SizedBox(height: 8),

        const Text('Select all that apply. You can leave this empty.'),

        const SizedBox(height: 20),

        for (final preference in preferences)
          CheckboxListTile(
            title: Text(preference),
            value: selectedPreferences.contains(preference),
            onChanged: (checked) {
              onPreferenceToggled(preference);
            },
        ),
      ],
    );
  }
}
