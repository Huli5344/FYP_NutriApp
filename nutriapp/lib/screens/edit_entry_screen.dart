/// Edit or delete an entry.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';

class EditEntryScreen extends StatefulWidget {
  final Entry entry;
  const EditEntryScreen({super.key, required this.entry});

  @override
  State<EditEntryScreen> createState() => _EditEntryScreenState();
}

class _EditEntryScreenState extends State<EditEntryScreen> {
  late final TextEditingController _quantityController;
  late final TextEditingController _noteController;
  late String _category;

  @override
  void initState() {
    super.initState();
    _quantityController =
        TextEditingController(text: '${widget.entry.quantity}');
    _noteController = TextEditingController(text: widget.entry.note);
    _category = widget.entry.category;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  double get _quantity {
    final parsed = double.tryParse(_quantityController.text.trim());
    if (parsed == null || parsed < 0.25) return widget.entry.quantity;
    return parsed;
  }

  /// Recompute from the original per-serving values rather than the stored
  /// totals, so repeated edits do not compound rounding error.
  Nutrition _recalculated() {
    final food = widget.entry.foodId == null
        ? null
        : LocalDb.instance.foodById(widget.entry.foodId!);
    final perServing = food?.perServing ??
        Nutrition(
          kcal: (widget.entry.kcal / widget.entry.quantity).round(),
          carbsG: widget.entry.carbsG / widget.entry.quantity,
          proteinG: widget.entry.proteinG / widget.entry.quantity,
          fatG: widget.entry.fatG / widget.entry.quantity,
        );
    return scaleNutrition(perServing, _quantity);
  }

  Future<void> _save() async {
    final n = _recalculated();
    await LocalDb.instance.updateEntry(widget.entry.copyWith(
      quantity: _quantity,
      kcal: n.kcal,
      carbsG: n.carbsG,
      proteinG: n.proteinG,
      fatG: n.fatG,
      category: _category,
      tags: autoTags(n),
      note: _noteController.text.trim(),
    ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: const Text("Today's total will update. There is no undo."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep it')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await LocalDb.instance.deleteEntry(widget.entry.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final recalculated = _recalculated();

    return Scaffold(
      appBar: AppBar(title: const Text('Edit entry')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          WireCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.foodName,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(
                    'Logged ${DateFormat('d MMM').format(e.eatenAt)} at '
                    '${DateFormat('HH:mm').format(e.eatenAt)} · ${e.kcal} kcal',
                    style: tMute),
              ],
            ),
          ),
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
                          const Text('Serving', style: tLabel),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 12),
                            decoration: BoxDecoration(
                                border: Border.all(color: AppColors.wire2)),
                            child: Text(e.serving, style: tBody),
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
                    'Recalculates to ${recalculated.kcal} kcal, '
                    'was ${e.kcal} kcal.',
                    style: tMute),
                const SizedBox(height: 12),
                const Text('Meal category', style: tLabel),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  value: _category,
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(
                          value: c,
                          child: Text(
                              '${capitalise(c)}${c == e.category ? ' — current' : ''}'))
                  ],
                  onChanged: (value) =>
                      setState(() => _category = value ?? _category),
                ),
                const SizedBox(height: 6),
                const Text(
                    'Your choice overrides the automatic time-of-day category.',
                    style: tMute),
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
                  children: autoTags(recalculated).isEmpty
                      ? [const Chip_('none')]
                      : [
                          for (final t in autoTags(recalculated))
                            Chip_(t, filled: true)
                        ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  decoration: const InputDecoration(labelText: 'Note'),
                ),
                const SizedBox(height: 12),
                WireButton(label: 'Save changes', onPressed: _save),
              ],
            ),
          ),
          const SizedBox(height: 10),
          WireButton(label: 'Delete entry', danger: true, onPressed: _delete),
          const SizedBox(height: 10),
          const WireNote(
              "Deleting asks for confirmation and updates the day's totals "
              'immediately. There is no undo.'),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
