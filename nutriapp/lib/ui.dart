/// Shared styling and the small widgets every screen reuses.
///
/// Follows the wireframe pack rather than a finished visual design: flat
/// surfaces, square corners, hairline borders, a monochrome palette, and grey
/// placeholder boxes where photography will go.
library;

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
                      children: [for (final t in tags) WireChip(t)],
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

/// Square-cornered pill. Named WireChip rather than Chip both to avoid
/// clashing with Flutter's own Chip and to sit with the other widgets here.
class WireChip extends StatelessWidget {
  final String label;
  final bool filled;
  final bool warning;
  const WireChip(this.label,
      {super.key, this.filled = false, this.warning = false});

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

/// Label and value on one line, for the profile summary.
class WireField extends StatelessWidget {
  final String label;
  final String value;
  final bool last;
  final VoidCallback? onTap;

  const WireField({
    super.key,
    required this.label,
    required this.value,
    this.last = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 128, child: Text(label, style: tMute)),
          Expanded(
            child: Text(value,
                style: tBody, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

// ---------------------------------------------------------------- charts
//
// Drawn by hand rather than with a charting package. Three reasons: the
// wireframes call for flat bars and hairlines that a chart library would fight,
// the shapes needed here are a bar column and a line, and adding a dependency
// for that would mean a package to resolve on every machine that builds this.

/// A column of vertical bars with a target line across them.
///
/// Bars are scaled to the tallest value or the target, whichever is larger, so
/// the target line is always on screen. A day with nothing logged draws as an
/// empty outline rather than nothing at all, because a gap in a chart and a day
/// at zero look identical otherwise.
class WireVBars extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final double? target;
  final double height;

  /// Values above this fraction of the target are drawn in the warning colour.
  final double overAt;

  const WireVBars({
    super.key,
    required this.values,
    required this.labels,
    this.target,
    this.height = 120,
    this.overAt = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final maxValue = [
      ...values,
      if (target != null) target!,
      1.0,
    ].reduce((a, b) => a > b ? a : b);

    return Column(
      children: [
        SizedBox(
          height: height,
          child: Stack(
            children: [
              // Target line, behind the bars.
              if (target != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: (target! / maxValue) * height,
                  child: Container(height: 1, color: AppColors.wire2),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < values.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _bar(values[i], maxValue),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final label in labels)
              Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 9, color: AppColors.mute)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _bar(double value, double maxValue) {
    if (value <= 0) {
      return Container(
        height: 2,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.wire2),
        ),
      );
    }
    final over = target != null && value > target! * overAt;
    return Container(
      height: (value / maxValue) * height,
      color: over ? AppColors.bad : AppColors.wire2,
    );
  }
}

/// A single bar split into segments, for a macro breakdown.
class WireStackBar extends StatelessWidget {
  final List<double> parts;
  final double thickness;
  const WireStackBar({super.key, required this.parts, this.thickness = 10});

  static const _shades = [
    AppColors.ink,
    AppColors.mute,
    AppColors.wire2,
    AppColors.wire,
  ];

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<double>(0, (a, b) => a + b);
    if (total <= 0) {
      return Container(height: thickness, color: AppColors.wire);
    }
    return SizedBox(
      height: thickness,
      child: Row(
        children: [
          for (var i = 0; i < parts.length; i++)
            if (parts[i] > 0)
              Expanded(
                flex: (parts[i] / total * 1000).round().clamp(1, 1000),
                child: Container(color: _shades[i % _shades.length]),
              ),
        ],
      ),
    );
  }
}

/// A line through a short series of values, for the weight trend.
class WireSparkline extends StatelessWidget {
  final List<double> values;
  final double? marker;
  final double height;

  const WireSparkline({
    super.key,
    required this.values,
    this.marker,
    this.height = 70,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparklinePainter(values: values, marker: marker),
        ),
      );
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final double? marker;

  _SparklinePainter({required this.values, this.marker});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    // The marker is inside the range so a target line cannot fall off the top
    // or bottom of the box and look as though it is not there.
    final all = [...values, if (marker != null) marker!];
    var low = all.reduce((a, b) => a < b ? a : b);
    var high = all.reduce((a, b) => a > b ? a : b);
    if (high - low < 0.5) {
      // A flat series would otherwise divide by nearly zero and spike.
      low -= 0.5;
      high += 0.5;
    }
    final span = high - low;

    double y(double value) =>
        size.height - ((value - low) / span) * size.height;
    double x(int index) =>
        values.length == 1 ? 0 : (index / (values.length - 1)) * size.width;

    if (marker != null) {
      final dashed = Paint()
        ..color = AppColors.wire2
        ..strokeWidth = 1;
      final markerY = y(marker!);
      for (var px = 0.0; px < size.width; px += 6) {
        canvas.drawLine(
            Offset(px, markerY), Offset(px + 3, markerY), dashed);
      }
    }

    final line = Paint()
      ..color = AppColors.ink
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(x(0), y(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    canvas.drawPath(path, line);

    final dot = Paint()..color = AppColors.ink;
    canvas.drawCircle(
        Offset(x(values.length - 1), y(values.last)), 2.5, dot);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.marker != marker;
}

String capitalise(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
