import 'package:flutter/material.dart';

class DietaryRestrictionsScreen extends StatelessWidget {
  final List<String> selectedRestrictions;

  final ValueChanged<String> onRestrictionToggled;

  const DietaryRestrictionsScreen({
    super.key,
    required this.selectedRestrictions,
    required this.onRestrictionToggled,
  });

  @override
  Widget build(BuildContext context) {
    final List<String> restrictions = [
      'Peanuts',
      'Tree Nuts',
      'Dairy',
      'Eggs',
      'Gluten',
      'Soy',
      'Fish',
      'Shellfish',
      'Sesame',
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Dietary Restrictions',
          style: TextStyle(
            fontSize: 24, 
            fontWeight: FontWeight.bold
          ),
        ),

        const SizedBox(height: 8),

        const Text('Select foods or ingredients you need to avoid.'),

        const SizedBox(height: 20),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final restriction in restrictions)
              FilterChip(
                label: Text(restriction),
                selected: selectedRestrictions.contains(restriction),
                onSelected: (selected) {
                  onRestrictionToggled(restriction);
                },
              ),
          ],
        ),
      ],
    );
  }
}
