/// Widget tests for the shared pieces in ui.dart.
///
/// These replace the template `flutter create` writes, which referenced a
/// class called MyApp that this project does not have.
///
/// Deliberately limited to widgets that need nothing from outside: no
/// database, no network, no profile. Pumping a whole screen would need
/// sqflite, which has no implementation in a plain test binary and would fail
/// on a missing platform channel rather than on anything to do with the
/// widget. The screens are covered instead by the rules in logic.dart, which
/// logic_test.dart exercises directly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nutriapp_diary/ui.dart';

/// Wrap a widget in the minimum needed to pump it.
Widget host(Widget child) => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(body: child),
    );

void main() {
  group('WireChip', () {
    testWidgets('shows its label', (tester) async {
      await tester.pumpWidget(host(const WireChip('Dairy')));
      expect(find.text('Dairy'), findsOneWidget);
    });

    testWidgets('a warning chip is drawn in the warning colour', (tester) async {
      await tester.pumpWidget(host(const WireChip('Peanuts', warning: true)));
      final text = tester.widget<Text>(find.text('Peanuts'));
      expect(text.style?.color, AppColors.warn);
    });

    testWidgets('a filled chip inverts to white on ink', (tester) async {
      await tester.pumpWidget(host(const WireChip('Vegan', filled: true)));
      final text = tester.widget<Text>(find.text('Vegan'));
      expect(text.style?.color, Colors.white);
    });
  });

  group('WireBar', () {
    testWidgets('fills in proportion to the percentage', (tester) async {
      await tester.pumpWidget(host(const WireBar(percent: 40)));
      final box = tester.widget<FractionallySizedBox>(
          find.byType(FractionallySizedBox));
      expect(box.widthFactor, closeTo(0.4, 0.001));
    });

    testWidgets('a percentage above a hundred is clamped, not overflowed',
        (tester) async {
      // The summary allows an overshoot to exceed the target, so this widget
      // has to cope with a value above 100 without painting outside itself.
      await tester.pumpWidget(host(const WireBar(percent: 180, over: true)));
      final box = tester.widget<FractionallySizedBox>(
          find.byType(FractionallySizedBox));
      expect(box.widthFactor, 1.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('WireVBars', () {
    testWidgets('draws one bar per value and labels them', (tester) async {
      await tester.pumpWidget(host(const WireVBars(
        values: [1800, 2100, 0, 1950],
        labels: ['M', 'T', 'W', 'T'],
        target: 2000,
      )));
      expect(find.text('M'), findsOneWidget);
      expect(find.text('W'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a run of zeroes does not divide by zero', (tester) async {
      // An untouched diary gives every day a zero. The scale is taken from
      // the tallest value, so this is the case that would divide by nothing.
      await tester.pumpWidget(host(const WireVBars(
        values: [0, 0, 0],
        labels: ['M', 'T', 'W'],
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('WireSparkline', () {
    testWidgets('a single point renders rather than throwing', (tester) async {
      // Insights refuses to call one measurement a trend, but the widget
      // should still survive being handed one.
      await tester.pumpWidget(host(const WireSparkline(values: [70.0])));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a flat series does not divide by zero', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: WireSparkline(
        values: [70.0, 70.0, 70.0],
        marker: 70.0,
      ))));
      expect(tester.takeException(), isNull);
    });
  });

  group('WireStackBar', () {
    testWidgets('an empty breakdown renders as a bare track', (tester) async {
      await tester.pumpWidget(host(const WireStackBar(parts: [0, 0, 0])));
      expect(tester.takeException(), isNull);
    });

    testWidgets('segments are laid out in proportion', (tester) async {
      await tester.pumpWidget(host(const WireStackBar(parts: [50, 30, 20])));
      final flexes = tester
          .widgetList<Expanded>(find.byType(Expanded))
          .map((e) => e.flex)
          .toList();
      expect(flexes.length, 3);
      expect(flexes.first, greaterThan(flexes.last));
    });
  });

  group('WireField', () {
    testWidgets('shows a label and its value', (tester) async {
      await tester.pumpWidget(
          host(const WireField(label: 'Height', value: '163.0 cm')));
      expect(find.text('Height'), findsOneWidget);
      expect(find.text('163.0 cm'), findsOneWidget);
    });

    testWidgets('is tappable only when given a callback', (tester) async {
      await tester.pumpWidget(
          host(const WireField(label: 'Goal', value: 'Lose Weight')));
      expect(find.byType(InkWell), findsNothing);

      var tapped = false;
      await tester.pumpWidget(host(WireField(
          label: 'Goal', value: 'Lose Weight', onTap: () => tapped = true)));
      await tester.tap(find.byType(InkWell));
      expect(tapped, isTrue);
    });
  });

  group('WireButton', () {
    testWidgets('a button with no callback does not fire', (tester) async {
      await tester.pumpWidget(host(const WireButton(label: 'Save')));
      await tester.tap(find.text('Save'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('reports taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
          host(WireButton(label: 'Save', onPressed: () => taps++)));
      await tester.tap(find.text('Save'));
      expect(taps, 1);
    });
  });

  group('capitalise', () {
    test('leaves an empty string alone', () {
      expect(capitalise(''), '');
    });

    test('raises the first letter only', () {
      expect(capitalise('breakfast'), 'Breakfast');
      expect(capitalise('high-protein'), 'High-protein');
    });
  });
}
