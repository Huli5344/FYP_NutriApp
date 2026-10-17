import 'package:flutter/material.dart';

class ProfileReviewScreen extends StatelessWidget {
  // Personal details
  final String age;
  final String? gender;
  final String height;
  final String weight;
  final String activityLevel;

  // Dietary details
  final String dietaryGoal;
  final String targetWeight;
  final List<String> preferences;
  final List<String> restrictions;

  const ProfileReviewScreen({
    super.key,
    required this.age,
    required this.gender,
    required this.height,
    required this.weight,
    required this.activityLevel,
    required this.dietaryGoal,
    required this.targetWeight,
    required this.preferences,
    required this.restrictions,
  });

  Widget buildProfileItem(String title, String value) {
    return ListTile(
      title: Text(title),
      subtitle: Text(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showTargetWeight =
        targetWeight.trim().isNotEmpty &&
        (dietaryGoal == 'Lose Weight' ||
         dietaryGoal == 'Gain Weight' ||
         dietaryGoal == 'Build Muscle');
    
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Review Your Profile',
          style: TextStyle(
            fontSize: 24, 
            fontWeight: FontWeight.bold
          ),
        ),

        const SizedBox(height: 8),

        const Text('Check your details before finishing.'),

        const SizedBox(height: 20),

        buildProfileItem('Age', age),

        buildProfileItem(
          'Gender',
          gender ?? 'Not specified',
        ),

        buildProfileItem(
          'Height',
          '$height cm',
        ),

        buildProfileItem(
          'Current Weight',
          '$weight kg',
        ),

        buildProfileItem(
          'Activity Level',
          activityLevel,
        ),

        const Divider(),

        buildProfileItem(
          'Dietary Goal',
          dietaryGoal,
        ),

        if (showTargetWeight)
          buildProfileItem(
            'Target Weight',
            '$targetWeight kg',
          ),

        const Divider(),

        buildProfileItem(
          'Preferences',
          preferences.isEmpty
              ? 'None selected'
              : preferences.join(', '),
        ),

        buildProfileItem(
          'Restrictions',
          restrictions.isEmpty
              ? 'None selected'
              : restrictions.join(', '),
        ),
      ],
    );
  }
}
