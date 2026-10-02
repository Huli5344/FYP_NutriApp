/// Add food and serving.
///
/// Search and the serving controls share one screen: a serving size needs a
/// food to apply to, so the picker sits above and collapses once one is chosen.

import 'package:flutter/material.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'saved_screen.dart';

class AddFoodScreen extends StatefulWidget {
  const AddFoodScreen({super.key});

  @override
  State<AddFoodScreen> createState() => _AddFoodScreenState();
}

class _AddFoodScreenState extends State<AddFoodScreen> {
  final _searchController = TextEditingController();
  final _noteController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');

  List<Food> _results = [];
  Food? _selected;
  String _category = '';
  DateTime _eatenAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _results = LocalDb.instance.searchFoods('');
    _category = categoriseByTime(_eatenAt);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _noteController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  double get _quantity {
    final parsed = double.tryParse(_quantityController.text.trim());
    if (parsed == null || parsed < 0.25) return 1;
    return parsed;
  }

  Nutrition? get _preview => _selected == null
      ? null
      : scaleNutrition(_selected!.perServing, _quantity);

  Future<void> _pickTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _eatenAt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_eatenAt),
    );
    if (time == null) return;
    setState(() {
      _eatenAt =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
      // The category follows the time of the meal, not the time of logging.
      _category = categoriseByTime(_eatenAt);
    });
  }

  Future<void> _save() async {
    final food = _selected;
    if (food == null) return;
    final entry = await LocalDb.instance.addEntry(
      food: food,
      quantity: _quantity,
      eatenAt: _eatenAt,
      category: _category,
      note: _noteController.text.trim(),
    );
    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => SavedScreen(entry: entry)));
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: Text(_selected?.name ?? 'Add food')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          WireCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                      labelText: 'Search foods',
                      hintText: 'rice, oats, salmon...'),
                  onChanged: (value) => setState(
                      () => _results = LocalDb.instance.searchFoods(value)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          WireCard(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                if (_results.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 9),
                    child: Text('Nothing matched. Try a shorter word.',
                        style: tMute),
                  ),
                for (final f in _results)
                  WireRow(
                    title: f.name,
                    subtitle: '${f.brand ?? 'Generic'} · ${f.serving}',
                    trailing: '${f.perServing.kcal} kcal',
                    last: f == _results.last,
                    onTap: () => setState(() => _selected = f),
                  ),
              ],
            ),
          ),
          if (_selected != null && preview != null) ...[
            const SizedBox(height: 10),
            WireCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Serving size', style: tLabel),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 12),
                              decoration: BoxDecoration(
                                  border: Border.all(color: AppColors.wire2)),
                              child: Text(_selected!.serving, style: tBody),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _quantityController,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Quantity'),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                      'One unit is ${_selected!.serving}. Use 0.5 for half, '
                      '1.5 for one and a half.',
                      style: tMute),
                ],
              ),
            ),
            const SizedBox(height: 10),
            WireCard(
              child: Column(
                children: [
                  const Text('Calculated', style: tLabel),
                  Text('${preview.kcal}', style: tBig),
                  const Text('kcal', style: tMute),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Stat(value: '${preview.carbsG} g', label: 'Carbs'),
                      Stat(value: '${preview.proteinG} g', label: 'Protein'),
                      Stat(value: '${preview.fatG} g', label: 'Fat'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            WireCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Meal', style: tLabel),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: _category,
                    items: [
                      for (final c in categories)
                        DropdownMenuItem(value: c, child: Text(capitalise(c)))
                    ],
                    onChanged: (value) =>
                        setState(() => _category = value ?? _category),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                      'Set automatically from the time below. Change it if it '
                      'is wrong.',
                      style: tMute),
                  const SizedBox(height: 12),
                  const Text('Date and time', style: tLabel),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: _pickTime,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 12),
                      decoration:
                          BoxDecoration(border: Border.all(color: AppColors.wire2)),
                      child: Text(
                        '${_eatenAt.day}/${_eatenAt.month}/${_eatenAt.year}  '
                        '${_eatenAt.hour.toString().padLeft(2, '0')}:'
                        '${_eatenAt.minute.toString().padLeft(2, '0')}',
                        style: tBody,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Dietary tags', style: tHead),
                      const Text('Auto', style: tLabel),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: autoTags(preview).isEmpty
                        ? [const Chip_('none apply at this serving')]
                        : [
                            for (final t in autoTags(preview))
                              Chip_(t, filled: true)
                          ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteController,
                    decoration: const InputDecoration(
                        labelText: 'Note',
                        hintText: 'Optional, for example: ate half'),
                  ),
                  const SizedBox(height: 12),
                  WireButton(label: 'Add to diary', onPressed: _save),
                ],
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child:
                  Text('Pick a food above to set the serving size.', style: tMute),
            ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
