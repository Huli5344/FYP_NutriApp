/// Enter a food the Health Promotion Board does not list.
///
/// A home recipe, an imported product, a dish from a stall that never made it
/// into the dataset. Saved rather than logged once, because the point is
/// reuse: it appears in search from then on, above the published foods.
///
/// What is typed here is the figures for *one serving*, whatever a serving
/// means to the person entering it. The app multiplies by that unit exactly
/// as it does with HPB's published "1 plate(s) = 363g", and never tries to
/// parse grams out of it.
library;

import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../ui.dart';

class CustomFoodScreen extends StatefulWidget {
  /// The food being edited, or null to create one.
  final Food? existing;

  const CustomFoodScreen({super.key, this.existing});

  @override
  State<CustomFoodScreen> createState() => _CustomFoodScreenState();
}

class _CustomFoodScreenState extends State<CustomFoodScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _serving;
  late final TextEditingController _kcal;
  late final TextEditingController _carbs;
  late final TextEditingController _protein;
  late final TextEditingController _fat;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final food = widget.existing;
    _name = TextEditingController(text: food?.name ?? '');
    _serving = TextEditingController(text: food?.serving ?? '');
    _kcal = TextEditingController(
        text: food == null ? '' : '${food.perServing.kcal}');
    _carbs = TextEditingController(
        text: food == null ? '' : '${food.perServing.carbsG}');
    _protein = TextEditingController(
        text: food == null ? '' : '${food.perServing.proteinG}');
    _fat = TextEditingController(
        text: food == null ? '' : '${food.perServing.fatG}');
  }

  @override
  void dispose() {
    for (final c in [_name, _serving, _kcal, _carbs, _protein, _fat]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Blank counts as zero for the macros, which is why they are not required.
  /// Somebody who only knows the calories can still record the food, and the
  /// macro bars will understate rather than refuse the entry.
  double _number(TextEditingController c) =>
      double.tryParse(c.text.trim()) ?? 0;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final navigator = Navigator.of(context);
    final food = await LocalDb.instance.saveCustomFood(
      id: widget.existing?.id,
      name: _name.text,
      serving: _serving.text,
      kcal: _number(_kcal).round(),
      carbsG: _number(_carbs),
      proteinG: _number(_protein),
      fatG: _number(_fat),
    );

    navigator.pop(food);
  }

  Future<void> _delete() async {
    final food = widget.existing;
    if (food == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this food?'),
        content: const Text(
            'It stops appearing in search. Meals you have already logged from '
            'it are not affected -- each one keeps its own figures.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.bad),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final navigator = Navigator.of(context);
    await LocalDb.instance.deleteCustomFood(food.id);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit your food' : 'Add your own food'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: "Ah Ma's laksa",
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Give it a name' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _serving,
              decoration: const InputDecoration(
                labelText: 'One serving is',
                hintText: '1 bowl',
                helperText: 'Whatever you measure it in. Left blank, it is '
                    '"1 serving".',
              ),
            ),
            const SizedBox(height: 20),
            const Text('Per serving', style: tHead),
            const SizedBox(height: 10),
            TextFormField(
              controller: _kcal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Calories', suffixText: 'kcal'),
              validator: (v) {
                final value = double.tryParse((v ?? '').trim());
                if (value == null) return 'Enter a number';
                if (value <= 0) return 'Must be more than zero';
                if (value > 10000) return 'That looks too high for a serving';
                return null;
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _macro(_carbs, 'Carbs')),
                const SizedBox(width: 10),
                Expanded(child: _macro(_protein, 'Protein')),
                const SizedBox(width: 10),
                Expanded(child: _macro(_fat, 'Fat')),
              ],
            ),
            const SizedBox(height: 10),
            const WireNote(
                'Leave a macro blank if you do not know it. It counts as zero, '
                'so your daily carbs, protein and fat will read a little low '
                'whenever you log this.'),
            const SizedBox(height: 24),
            WireButton(
              label: _busy
                  ? 'Saving...'
                  : (editing ? 'Save changes' : 'Save food'),
              onPressed: _busy ? null : _save,
            ),
            if (editing) ...[
              const SizedBox(height: 10),
              WireButton(
                label: 'Delete food',
                danger: true,
                small: true,
                onPressed: _busy ? null : _delete,
              ),
            ],
            const SizedBox(height: 16),
            const WireNote(
                'Saved to your account, so it is still here on another device '
                'and after reinstalling.'),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _macro(TextEditingController controller, String label) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, suffixText: 'g'),
      validator: (v) {
        final text = (v ?? '').trim();
        if (text.isEmpty) return null;
        final value = double.tryParse(text);
        if (value == null) return 'Number';
        if (value < 0) return 'Not negative';
        return null;
      },
    );
  }
}
