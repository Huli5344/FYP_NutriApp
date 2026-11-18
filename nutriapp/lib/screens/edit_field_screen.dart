/// Editing one field of the profile.
///
/// Before this, correcting a typed height meant walking the whole setup flow
/// again: five screens, every answer re-confirmed, to change one number. The
/// flow is right for setting a profile up, where the order teaches what is
/// being asked and why. It is the wrong shape for a correction.
///
/// Three kinds of editor, chosen by what the field is rather than by where it
/// appears:
///
///   * a short value — a name, a number — is a dialog, matching the calorie
///     target and weight dialogs that were already here;
///   * a choice from a handful of options is a dialog too, since the lists
///     are short enough to show whole;
///   * preferences and restrictions get a screen of their own, because a
///     dozen toggles in a dialog is a scrolling box inside a scrolling page.
///
/// None of them knows what is valid. The rules are in profile_fields.dart,
/// which the setup flow reads as well.
library;

import 'package:flutter/material.dart';

import '../ui.dart';

/// Ask for a single line of text or a number.
///
/// Returns the accepted raw string, or null if cancelled. Validation runs
/// before the dialog closes, so an invalid value is corrected in place
/// rather than rejected by a snackbar after the dialog has gone — by which
/// point what was typed is lost.
Future<String?> editValue(
  BuildContext context, {
  required String title,
  required String label,
  required String initial,
  required String? Function(String) validate,
  String? help,
  String? suffix,
  TextInputType keyboard = TextInputType.text,
  String saveLabel = 'Save',
  String? clearLabel,
}) {
  final controller = TextEditingController(text: initial);
  // Opening with the text selected means typing replaces it, which is what
  // somebody correcting a number almost always wants.
  controller.selection =
      TextSelection(baseOffset: 0, extentOffset: controller.text.length);

  return showDialog<String>(
    context: context,
    builder: (context) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (help != null) ...[
                Text(help, style: tMute),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                keyboardType: keyboard,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: label,
                  suffixText: suffix,
                  errorText: error,
                ),
                onSubmitted: (_) {
                  final message = validate(controller.text);
                  if (message == null) {
                    Navigator.pop(context, controller.text);
                  } else {
                    setState(() => error = message);
                  }
                },
              ),
            ],
          ),
          actions: [
            if (clearLabel != null)
              TextButton(
                onPressed: () => Navigator.pop(context, ''),
                child: Text(clearLabel),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final message = validate(controller.text);
                if (message == null) {
                  Navigator.pop(context, controller.text);
                } else {
                  setState(() => error = message);
                }
              },
              child: Text(saveLabel),
            ),
          ],
        ),
      );
    },
  );
}

/// Pick one of a short list.
///
/// Returns the chosen value, or null if cancelled. `allowNone` adds an
/// explicit "Prefer not to say"-style escape for a field that is genuinely
/// optional; without it the only way out of having answered is cancelling,
/// which keeps the old answer rather than clearing it.
Future<String?> chooseOne(
  BuildContext context, {
  required String title,
  required List<String> options,
  required String? current,
  String? help,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        if (help != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(help, style: tMute),
          ),
        // RadioGroup rather than a groupValue on each tile: this is the form
        // the setup flow already uses, and the per-tile properties are
        // deprecated in the Flutter version this project builds against.
        RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) Navigator.pop(context, value);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in options)
                RadioListTile<String>(
                  value: option,
                  title: Text(option),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Choose any number of options, on a screen of its own.
///
/// Returns the chosen list, or null if backed out of. An empty list is a
/// meaningful answer — "I have no restrictions" — and is returned as such,
/// which is why it is not treated the same as null.
class EditChoicesScreen extends StatefulWidget {
  final String title;
  final String description;
  final List<String> options;
  final List<String> selected;

  /// Shown under the list when anything is selected. Used by restrictions to
  /// say what the choices are matched against, so the translation from
  /// "Dairy" to "milk" is visible rather than hidden.
  final String Function(List<String>)? footnote;

  /// Restrictions are a safety answer, so they read as a warning; dietary
  /// preferences are a preference and read plainly.
  final bool warning;

  const EditChoicesScreen({
    super.key,
    required this.title,
    required this.description,
    required this.options,
    required this.selected,
    this.footnote,
    this.warning = false,
  });

  @override
  State<EditChoicesScreen> createState() => _EditChoicesScreenState();
}

class _EditChoicesScreenState extends State<EditChoicesScreen> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    // Copied, not aliased: editing in place would mutate the profile's own
    // list, so backing out would keep changes that were never saved.
    _selected = List<String>.of(widget.selected);
  }

  void _toggle(String value) {
    setState(() {
      if (_selected.contains(value)) {
        _selected.remove(value);
      } else {
        _selected.add(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _selected),
            child: const Text('Save',
                style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(widget.description, style: tMute),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in widget.options)
                FilterChip(
                  label: Text(option),
                  selected: _selected.contains(option),
                  onSelected: (_) => _toggle(option),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_selected.isEmpty)
            WireNote(widget.warning
                ? 'Nothing selected. No meals will be filtered out.'
                : 'Nothing selected. Suggestions are not narrowed.')
          else if (widget.footnote != null)
            WireNote(widget.footnote!(_selected)),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
