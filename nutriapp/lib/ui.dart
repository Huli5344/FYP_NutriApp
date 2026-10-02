/// Shared styling and the small widgets every screen reuses.
///
/// Follows the wireframe pack rather than a finished visual design: flat
/// surfaces, square corners, hairline borders, a monochrome palette, and grey
/// placeholder boxes where photography will go.

import 'package:flutter/material.dart';

class AppColors {
  static const ink = Color(0xFF20252A);
  static const mute = Color(0xFF6B747C);
  static const line = Color(0xFFC9CFC9);
  static const wire = Color(0xFFDDE1DD);
  static const wire2 = Color(0xFFC5CBC5);
  static const surface = Color(0xFFFFFFFF);
  static const warn = Color(0xFF8A5A2B);
  static const bad = Color(0xFFA33A2E);
  static const tint = Color(0xFFF5F7F5);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.surface,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.ink,
      primary: AppColors.ink,
      surface: AppColors.surface,
    ),
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.ink,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      shape: Border(bottom: BorderSide(color: AppColors.line)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Color(0xFFFCFDFC),
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.wire2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.wire2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.ink, width: 2),
      ),
      labelStyle: TextStyle(color: AppColors.mute, fontSize: 12),
    ),
  );
}

// ---------------------------------------------------------------- text
const tBig = TextStyle(
    fontSize: 38, fontWeight: FontWeight.w600, height: 1.0, color: AppColors.ink);
const tHead = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.ink);
const tBody = TextStyle(fontSize: 13, color: AppColors.ink, height: 1.4);
const tMute = TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4);
const tLabel = TextStyle(fontSize: 11, color: AppColors.mute);

// ---------------------------------------------------------------- blocks

/// Bordered container, the frames' basic grouping.
class WireCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  const WireCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(10),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line),
        color: AppColors.surface,
      ),
      child: child,
    );
    return onTap == null ? box : InkWell(onTap: onTap, child: box);
  }
}

/// Grey placeholder where imagery will go.
class WireBox extends StatelessWidget {
  final double height;
  final String label;
  const WireBox({super.key, required this.height, this.label = 'Meal photo'});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.wire,
          border: Border.all(color: AppColors.wire2),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11, color: AppColors.mute)),
      );
}

/// Hairline-separated list row.
class WireRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTap;
  final bool last;
  final List<String> tags;

  const WireRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.last = false,
    this.tags = const [],
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tBody),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(subtitle!, style: tMute),
                if (tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [for (final t in tags) Chip_(t)],
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(trailing!,
                  style: const TextStyle(fontSize: 13, color: AppColors.mute)),
            ),
        ],
      ),
    );
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }
}

/// Square-cornered pill. Named with a trailing underscore to avoid clashing
/// with Flutter's own Chip.
class Chip_ extends StatelessWidget {
  final String label;
  final bool filled;
  final bool warning;
  const Chip_(this.label, {super.key, this.filled = false, this.warning = false});

  @override
  Widget build(BuildContext context) {
    final border = warning ? AppColors.warn : (filled ? AppColors.ink : AppColors.wire2);
    final fg = warning ? AppColors.warn : (filled ? Colors.white : AppColors.mute);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? AppColors.ink : AppColors.surface,
        border: Border.all(color: border),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: fg)),
    );
  }
}

/// Progress bar. Turns red past the target.
class WireBar extends StatelessWidget {
  final int percent;
  final bool over;
  const WireBar({super.key, required this.percent, this.over = false});

  @override
  Widget build(BuildContext context) => Container(
        height: 8,
        color: AppColors.wire,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: (percent / 100).clamp(0.0, 1.0),
          child: Container(color: over ? AppColors.bad : AppColors.wire2),
        ),
      );
}

/// Left-ruled note, for explanations and cautions.
class WireNote extends StatelessWidget {
  final String text;
  final bool warning;
  const WireNote(this.text, {super.key, this.warning = false});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: warning ? const Color(0xFFFBF3E7) : AppColors.tint,
          border: Border(
            left: BorderSide(
                color: warning ? AppColors.warn : AppColors.wire2, width: 3),
          ),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: warning ? AppColors.warn : AppColors.mute,
                height: 1.4)),
      );
}

/// Filled or outlined action.
class WireButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  final bool danger;
  final bool small;

  const WireButton({
    super.key,
    required this.label,
    this.onPressed,
    this.outlined = false,
    this.danger = false,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppColors.bad : (outlined ? AppColors.ink : Colors.white);
    final bg = (outlined || danger) ? AppColors.surface : AppColors.ink;
    final border = danger ? AppColors.bad : AppColors.ink;
    return SizedBox(
      width: double.infinity,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          padding: EdgeInsets.symmetric(vertical: small ? 8 : 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, border: Border.all(color: border)),
          child: Text(label,
              style: TextStyle(
                  color: fg, fontSize: small ? 12 : 13, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// One of three figures under the calorie panel.
class Stat extends StatelessWidget {
  final String value;
  final String label;
  const Stat({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: AppColors.mute)),
          ],
        ),
      );
}

String capitalise(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
