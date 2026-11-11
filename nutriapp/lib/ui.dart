/// Shared styling and the small widgets every screen reuses.
///
/// The look is a reference publication rather than a fitness app, because
/// that is what this app actually is: it reports figures the Health Promotion
/// Board published, keeps their serving text verbatim, flags the servings
/// that are a whole roast turkey, and hides the nutrients HPB never measured.
/// Hierarchy comes from size, weight and alignment; rules appear only where
/// they separate data. There are no shadows and no decorative colour.
///
/// Two accents, each meaning exactly one thing: [AppColors.accent] for
/// interactive and on-track, [AppColors.warn] for over target and for a
/// portion worth a second look. Anything else is ink, mute or a rule.
///
/// Numbers are set with tabular figures wherever they stack in a column, so
/// 8, 373 and 4,243 line up down a list instead of jittering. It is the
/// cheapest thing that makes a table of figures look deliberate.
///
/// Every widget here keeps the name and constructor it had as a wireframe, so
/// restyling touched this file and not the twenty screens that use it.
library;

import 'package:flutter/material.dart';

class AppColors {
  /// Deep blue-black. Body text and the figures that matter.
  static const ink = Color(0xFF10232B);

  /// Secondary text: units, captions, labels, explanations.
  static const mute = Color(0xFF5B6E75);

  /// Hairline between rows and around surfaces.
  static const line = Color(0xFFDCE3E6);

  /// Empty track behind a bar, and the fill of a placeholder.
  static const wire = Color(0xFFE3E9EB);

  /// A stronger rule, for an input outline or a divider that has to carry.
  static const wire2 = Color(0xFFC3CED2);

  /// Cards and sheets.
  static const surface = Color(0xFFFFFFFF);

  /// The page behind them. Slightly cool so white surfaces lift off it
  /// without needing a shadow.
  static const paper = Color(0xFFF2F5F6);

  /// Interactive, and on track. The only colour that invites a tap.
  static const accent = Color(0xFF13505B);

  /// Over target, and large portions. Never used decoratively, so its
  /// appearance always means the same thing.
  static const warn = Color(0xFFA75B12);

  /// Destructive, and errors.
  static const bad = Color(0xFF93241F);

  /// A quiet wash for notes and inactive fills.
  static const tint = Color(0xFFEDF2F3);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.paper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      primary: AppColors.accent,
      surface: AppColors.surface,
    ),
    // Bundled rather than fetched, so a release build works offline and the
    // first launch has no unstyled moment. Subset to Latin and checked
    // against every character in the food table: 214 KB for three weights.
    fontFamily: 'IBMPlexSans',
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'IBMPlexSans',
        color: AppColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      shape: Border(bottom: BorderSide(color: AppColors.line)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      titleTextStyle: TextStyle(
        fontFamily: 'IBMPlexSans',
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'IBMPlexSans',
        fontSize: 15,
        height: 1.45,
        color: AppColors.ink,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: TextStyle(
          fontFamily: 'IBMPlexSans', fontSize: 15, color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        textStyle: const TextStyle(
            fontFamily: 'IBMPlexSans', fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    // Styled here so the sign-in and registration forms match the rest
    // without each screen dressing its own buttons -- which is how one of
    // them ended up green.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(
            fontFamily: 'IBMPlexSans', fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: AppColors.wire2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(
            fontFamily: 'IBMPlexSans', fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: false,
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.wire2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.wire2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.bad),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.bad, width: 2),
      ),
      labelStyle: const TextStyle(color: AppColors.mute, fontSize: 15),
      helperStyle: const TextStyle(color: AppColors.mute, fontSize: 13),
      hintStyle: const TextStyle(color: Color(0xFF9AA8AD), fontSize: 15),
    ),
  );
}

// ---------------------------------------------------------------- text
//
// Five styles, up from a scale that topped out at 13px. The old sizes were
// roughly two steps below what a phone needs, which is most of why the app
// read as unfinished rather than minimal.

/// Figures that stack in a column line up when they are tabular. Pulled out
/// as a constant because it belongs on every number the eye compares.
const _figures = [FontFeature.tabularFigures()];

/// The one loud thing on a screen: today's calories, a food's energy.
const tBig = TextStyle(
  fontSize: 44,
  fontWeight: FontWeight.w600,
  height: 1.0,
  letterSpacing: -1.4,
  color: AppColors.ink,
  fontFeatures: _figures,
);

/// A section heading.
const tHead = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: AppColors.ink);

/// Running text and row titles.
const tBody = TextStyle(fontSize: 15, color: AppColors.ink, height: 1.45);

/// Supporting text: subtitles, units, explanations.
const tMute = TextStyle(fontSize: 13, color: AppColors.mute, height: 1.45);

/// The smallest label, for a field name above a value.
const tLabel = TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4);

/// A number meant to be read against other numbers.
const tFigure = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: AppColors.ink,
    fontFeatures: _figures);

// ---------------------------------------------------------------- blocks

/// A white surface on the page. The basic grouping.
class WireCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  const WireCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(6),
        color: AppColors.surface,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: box,
      ),
    );
  }
}

/// Placeholder where imagery will go, for a food group with no picture yet.
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
          color: AppColors.tint,
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: tMute),
      );
}

/// A list row, separated from the next by a hairline.
///
/// The trailing text is a figure rather than a caption -- in practice it is
/// always a calorie count -- so it is set in ink with tabular numerals and
/// given the same weight as the title.
class WireRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTap;
  final bool last;
  final List<String> tags;

  /// Optional picture on the left, usually a [FoodImage]. Null by default,
  /// so every existing caller is unaffected.
  final Widget? leading;

  const WireRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.last = false,
    this.tags = const [],
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: leading,
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink)),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(subtitle!, style: tMute),
                  ),
                if (tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
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
              padding: const EdgeInsets.only(left: 12),
              child: Text(trailing!, style: tFigure),
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}

/// A small pill. Named WireChip rather than Chip both to avoid clashing with
/// Flutter's own Chip and to sit with the other widgets here.
class WireChip extends StatelessWidget {
  final String label;
  final bool filled;
  final bool warning;
  const WireChip(this.label,
      {super.key, this.filled = false, this.warning = false});

  @override
  Widget build(BuildContext context) {
    final border = warning
        ? const Color(0xFFE8D3B8)
        : (filled ? AppColors.accent : AppColors.line);
    final background = warning
        ? const Color(0xFFFBF4EA)
        : (filled ? AppColors.accent : AppColors.surface);
    final foreground =
        warning ? AppColors.warn : (filled ? Colors.white : AppColors.mute);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w500, color: foreground)),
    );
  }
}

/// Progress against the day's target.
class WireBar extends StatelessWidget {
  final int percent;
  final bool over;
  const WireBar({super.key, required this.percent, this.over = false});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Container(
          height: 10,
          color: AppColors.wire,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: (percent / 100).clamp(0.0, 1.0),
            child: Container(color: over ? AppColors.warn : AppColors.accent),
          ),
        ),
      );
}

/// A note with a rule down its left edge, for an explanation or a caution.
class WireNote extends StatelessWidget {
  final String text;
  final bool warning;
  const WireNote(this.text, {super.key, this.warning = false});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
        decoration: BoxDecoration(
          color: warning ? const Color(0xFFFBF4EA) : AppColors.tint,
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
          border: Border(
            left: BorderSide(
                color: warning ? AppColors.warn : AppColors.accent, width: 2),
          ),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: warning ? AppColors.warn : AppColors.mute)),
      );
}

/// A full-width action.
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
    final disabled = onPressed == null;
    final foreground = danger
        ? AppColors.bad
        : (outlined ? AppColors.ink : Colors.white);
    final background =
        (outlined || danger) ? AppColors.surface : AppColors.accent;
    final border =
        danger ? AppColors.bad : (outlined ? AppColors.wire2 : AppColors.accent);
    final radius = BorderRadius.circular(6);

    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: SizedBox(
        width: double.infinity,
        child: Material(
          color: background,
          borderRadius: radius,
          child: InkWell(
            onTap: onPressed,
            borderRadius: radius,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: small ? 11 : 15),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: border),
              ),
              child: Text(label,
                  style: TextStyle(
                      color: foreground,
                      fontSize: small ? 14 : 16,
                      fontWeight: FontWeight.w500)),
            ),
          ),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                    fontFeatures: _figures)),
            const SizedBox(height: 1),
            Text(label, style: tMute),
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
      padding: const EdgeInsets.symmetric(vertical: 13),
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
                style: const TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                    fontFeatures: _figures),
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

// ---------------------------------------------------------------- charts
//
// Drawn by hand rather than with a charting package. Three reasons: the
// shapes needed are a bar column and a line, a library would fight the flat
// treatment used everywhere else, and adding a dependency for that would mean
// a package to resolve on every machine that builds this.

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
        const SizedBox(height: 6),
        Row(
          children: [
            for (final label in labels)
              Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.mute)),
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
          color: AppColors.wire,
          borderRadius: BorderRadius.circular(1),
        ),
      );
    }
    final over = target != null && value > target! * overAt;
    return Container(
      height: (value / maxValue) * height,
      decoration: BoxDecoration(
        color: over ? AppColors.warn : AppColors.accent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
      ),
    );
  }
}

/// A single bar split into segments, for a macro breakdown.
class WireStackBar extends StatelessWidget {
  final List<double> parts;
  final double thickness;
  const WireStackBar({super.key, required this.parts, this.thickness = 10});

  /// Three steps down from the accent, so the segments read as one measure
  /// split up rather than as three unrelated categories.
  static const _shades = [
    AppColors.accent,
    Color(0xFF4C7F88),
    Color(0xFF9FBCC1),
    AppColors.wire,
  ];

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<double>(0, (a, b) => a + b);
    if (total <= 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Container(height: thickness, color: AppColors.wire),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
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
      ..color = AppColors.accent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(x(0), y(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    canvas.drawPath(path, line);

    final dot = Paint()..color = AppColors.accent;
    canvas.drawCircle(
        Offset(x(values.length - 1), y(values.last)), 3, dot);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.marker != marker;
}

String capitalise(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

/// Shown when a food's group has no picture, or it has no group at all.
const String fallbackFoodImage = 'assets/food_groups/fallback.webp';

/// The picture for a food group.
///
/// One image per group, not per food. There are 2,692 foods and 15 groups,
/// and a generated picture of a named dish is often wrong about the portion
/// or the preparation -- "without skin" is not something a picture is
/// careful about. A nutrition app whose photographs contradict its own
/// figures is worse than one with no photographs. A group image makes no
/// claim about the specific dish, so it cannot be wrong in that way.
///
/// This lives here rather than on Food because it is a presentation
/// concern: the model knows the group, the interface decides what to draw
/// for it. Keeping it out of models.dart also means the picture layer can
/// be added or removed without touching the data layer.
///
/// The slug is derived rather than looked up in a table, so adding a group
/// to the dataset needs only a file with the matching name.
/// tools/check_food_images.py checks every group has one.
String foodGroupImage(String? group) {
  if (group == null || group.trim().isEmpty) return fallbackFoodImage;
  final slug = group
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? fallbackFoodImage : 'assets/food_groups/$slug.webp';
}

/// A food group's picture.
///
/// The files are 1200x675 and shared by every food in a group, so whatever
/// matters should sit in the middle of the frame: a square thumbnail takes
/// the centre, a header takes the whole width.
///
/// `errorBuilder` is not decoration here. `Image.asset` throws at paint time
/// when a file is missing, which takes out whichever screen happens to be
/// showing that food -- during a demonstration, most likely, since that is
/// when unusual foods get searched for. A group whose image has not been
/// made yet leaves a quiet placeholder instead, and the app carries on.
///
/// `cacheWidth` matters for the list. Without it every row decodes a
/// 1200-pixel-wide bitmap to paint 56 points of it, and a scroll through
/// search results holds a dozen of them in memory at once.
class FoodImage extends StatelessWidget {
  final String asset;
  final double width;
  final double height;

  /// Decode at this width instead of the file's own. Set it to roughly the
  /// painted width in physical pixels.
  final int? decodeWidth;

  const FoodImage({
    super.key,
    required this.asset,
    required this.width,
    required this.height,
    this.decodeWidth,
  });

  /// The size used in a search result or diary row.
  factory FoodImage.thumb(String asset, {Key? key}) => FoodImage(
        key: key,
        asset: asset,
        width: 56,
        height: 56,
        decodeWidth: 168,
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.asset(
        asset,
        width: width,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: decodeWidth,
        errorBuilder: (context, error, stack) => Container(
          width: width,
          height: height,
          color: AppColors.tint,
          child: const Icon(Icons.restaurant_outlined,
              size: 20, color: AppColors.mute),
        ),
      ),
    );
  }
}
