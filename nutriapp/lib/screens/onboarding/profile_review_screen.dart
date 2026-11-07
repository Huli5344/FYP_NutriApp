import 'package:flutter/material.dart';

class ProfileReviewScreen extends StatelessWidget {
  // Personal details
  final String name;
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

  /// The calorie target these answers produce, or null if they are incomplete.
  final int? dailyTarget;

  const ProfileReviewScreen({
    super.key,
    required this.name,
    required this.age,
    required this.gender,
    required this.height,
    required this.weight,
    required this.activityLevel,
    required this.dietaryGoal,
    required this.targetWeight,
    required this.preferences,
    required this.restrictions,
    this.dailyTarget,
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

        // Shown before saving, because the daily target is the one figure
        // these answers produce that the rest of the app measures against.
        Card(
          color: const Color(0xFFE8F5E9),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your daily calorie target',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  dailyTarget == null
                      ? 'Complete your measurements to see this.'
                      : '$dailyTarget kcal a day',
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  dailyTarget == null
                      ? ''
                      : 'Worked out from your measurements and activity level, '
                          'then adjusted for "$dietaryGoal". You can change it '
                          'later on the Profile tab.',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        buildProfileItem('Name', name.trim().isEmpty ? 'Not set' : name),

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
