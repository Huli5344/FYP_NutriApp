/// Insights — the Data Visualisation part of the app.
///
/// Everything on this screen comes from entries already on the device, so it
/// works with no connection like the rest of the diary. The arithmetic is in
/// logic.dart; this file only arranges the results.
///
/// One deliberate choice runs through it: averages are taken over days that
/// were actually logged, never over the whole window. Dividing a week's intake
/// by seven when three days were recorded reports roughly half of what someone
/// ate, and would make every summary look like a deficit.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  static const List<int> windows = [7, 14, 30];

  int _days = insightsWindowDays;
  UserProfile? _profile;
  List<DayTotal> _totals = [];
  TrendSummary? _trend;
  List<WeightEntry> _weights = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final profile =
        await LocalDb.instance.loadProfile() ?? UserProfile.fallback;
    final today = DateTime.now();
    final from = today.subtract(Duration(days: _days - 1));
    final entries = await LocalDb.instance.entriesForRange(from, today);
    final weights = await LocalDb.instance.weightLog();

    final totals = dailyTotals(entries, endDay: today, days: _days);

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _totals = totals;
      _trend = summariseTrend(totals, profile.targetKcal);
      _weights = weights;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _trend == null || _profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final t = _trend!;
    final profile = _profile!;

    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _windowPicker(),
          const SizedBox(height: 10),
          if (t.daysLogged == 0)
            const WireNote(
              'Nothing logged in this period yet. Add a meal and the charts '
              'here will fill in.',
            )
          else ...[
            _averagePanel(t),
            const SizedBox(height: 12),
            _caloriesChart(t),
            const SizedBox(height: 12),
            _consistencyPanel(t),
            const SizedBox(height: 12),
            _macroPanel(t, profile),
            const SizedBox(height: 12),
            _mealPanel(t),
          ],
          const SizedBox(height: 12),
          _weightPanel(profile),
          const SizedBox(height: 12),
          Text(
              'Averages cover the ${t.daysLogged} '
              '${t.daysLogged == 1 ? 'day' : 'days'} you recorded, not all '
              '${t.days}. A day counts as on target within '
              '${(onTargetTolerance * 100).round()}% either side of '
              '${t.target} kcal.',
              style: tMute),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _windowPicker() {
    return Row(
      children: [
        for (final option in windows) ...[
          GestureDetector(
            onTap: () {
              setState(() => _days = option);
              _load();
            },
            child: WireChip('$option days', filled: _days == option),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }

  Widget _averagePanel(TrendSummary t) {
    final diff = t.averageKcal - t.target;
    return WireCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${t.averageKcal}', style: tBig),
                    Text('average a day, against ${t.target}', style: tMute),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    diff == 0
                        ? 'On target'
                        : '${diff.abs()} ${diff > 0 ? 'over' : 'under'}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: diff > 0 ? AppColors.bad : AppColors.ink,
                    ),
                  ),
                  Text('Highest ${t.highest}', style: tMute),
                  Text('Lowest ${t.lowest}', style: tMute),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _caloriesChart(TrendSummary t) {
    // Over a long window every day cannot carry a label, so only a few are
    // kept. The bars stay one per day; it is the labels that thin out.
    final step = (_totals.length / 7).ceil();
    return WireCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Calories by day', style: tHead),
          const SizedBox(height: 10),
          WireVBars(
            values: [for (final d in _totals) d.kcal.toDouble()],
            labels: [
              for (var i = 0; i < _totals.length; i++)
                (i % step == 0 || i == _totals.length - 1)
                    ? DateFormat('d/M').format(_totals[i].day)
                    : '',
            ],
            target: t.target.toDouble(),
          ),
          const SizedBox(height: 8),
          Text(
              'The line is your ${t.target} kcal target. Bars above it are '
              'marked.',
              style: tMute),
        ],
      ),
    );
  }

  Widget _consistencyPanel(TrendSummary t) {
    return WireCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Consistency', style: tHead),
              WireChip('${t.adherencePercent}% on target'),
            ],
          ),
          const SizedBox(height: 10),
          WireBar(percent: t.adherencePercent),
          const SizedBox(height: 10),
          Row(
            children: [
              Stat(value: '${t.streak}', label: 'Day streak'),
              Stat(value: '${t.daysLogged}/${t.days}', label: 'Days logged'),
              Stat(value: '${t.daysOnTarget}', label: 'On target'),
              Stat(value: '${t.daysOver}', label: 'Over'),
              Stat(value: '${t.daysUnder}', label: 'Under'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _macroPanel(TrendSummary t, UserProfile profile) {
    final a = t.averageMacros;
    final target = t.macroTargets;
    // Compared by calories rather than grams, because a gram of fat carries
    // more than twice a gram of carbohydrate and a grams-based bar would make
    // fat look like a smaller share of intake than it is.
    final kcalFromCarbs = a.carbsG * 4;
    final kcalFromProtein = a.proteinG * 4;
    final kcalFromFat = a.fatG * 9;

    return WireCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Where your calories come from', style: tHead),
              WireChip(profile.goal),
            ],
          ),
          const SizedBox(height: 10),
          WireStackBar(
              parts: [kcalFromCarbs, kcalFromProtein, kcalFromFat]),
          const SizedBox(height: 8),
          _macroRow('Carbohydrate', a.carbsG, target.carbsG, last: false),
          _macroRow('Protein', a.proteinG, target.proteinG, last: false),
          _macroRow('Fat', a.fatG, target.fatG, last: true),
        ],
      ),
    );
  }

  Widget _macroRow(String label, double average, double target,
      {required bool last}) {
    final share = target <= 0 ? 0 : ((average / target) * 100).round();
    return WireRow(
      title: label,
      subtitle: '$share% of target',
      trailing: '${average.round()} / ${target.round()} g',
      last: last,
    );
  }

  Widget _mealPanel(TrendSummary t) {
    final totals = categoryTotals(_totals);
    final sum = totals.values.fold<int>(0, (a, b) => a + b);
    return WireCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Calories by meal', style: tHead),
          const SizedBox(height: 10),
          WireStackBar(
              parts: [for (final c in categories) (totals[c] ?? 0).toDouble()]),
          const SizedBox(height: 8),
          for (final c in categories)
            WireRow(
              title: capitalise(c),
              subtitle: sum == 0
                  ? '0% of intake'
                  : '${(((totals[c] ?? 0) / sum) * 100).round()}% of intake',
              trailing: '${totals[c] ?? 0}',
              last: c == categories.last,
            ),
        ],
      ),
    );
  }

  Widget _weightPanel(UserProfile profile) {
    final live = _weights.where((w) => !w.deleted).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    final change = weightChange(_weights);
    final progress = progressTowardsTarget(_weights, profile.targetWeightKg);

    return WireCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Weight', style: tHead),
              if (profile.targetWeightKg != null)
                WireChip('Target ${profile.targetWeightKg} kg'),
            ],
          ),
          const SizedBox(height: 10),
          if (live.length < 2)
            // Said plainly rather than drawing a single point and calling it a
            // trend, which is what one measurement would amount to.
            const WireNote(
              'Log a second weight to see a trend. You can add one from the '
              'Profile tab.',
            )
          else ...[
            WireSparkline(
              values: [for (final w in live) w.kg],
              marker: profile.targetWeightKg,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Stat(value: '${live.last.kg} kg', label: 'Latest'),
                Stat(
                    value: change == null
                        ? '—'
                        : '${change > 0 ? '+' : ''}$change kg',
                    label: 'Change'),
                Stat(
                    value: progress == null ? '—' : '$progress%',
                    label: 'To target'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
                'From ${DateFormat('d MMM').format(live.first.recordedAt)} to '
                '${DateFormat('d MMM').format(live.last.recordedAt)}, '
                '${live.length} measurements.',
                style: tMute),
          ],
        ],
      ),
    );
  }
}
