/// Recommendations.
///
/// An endless list rather than a fixed handful. Recipes come first, then
/// single foods ordered by how near they land to the calories left for this
/// meal, and the next page loads as the bottom comes into view.
///
/// "Endless" is honest here rather than a trick: there are 2,647 suggestible
/// foods, each page is the next slice by calorie distance, and when they run
/// out the list says so instead of looping.
///
/// Two ways to get a different set, because they mean different things. Pull
/// down to refresh, which is where a thumb already is after scrolling. The
/// button at the bottom does the same thing and stays because a pull gesture
/// is invisible -- nothing on screen advertises it, and the button is what
/// tells someone the option exists.
library;

import 'package:flutter/material.dart';

import '../api.dart';
import '../db.dart';
import '../food_db.dart';
import '../logic.dart';
import '../models.dart';
import '../ui.dart';
import 'add_food_screen.dart';
import 'recipe_detail_screen.dart';

class DiscoverScreen extends StatefulWidget {
  final String? slot;
  const DiscoverScreen({super.key, this.slot});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  /// Suggestions placed on screen, in order. Grows; never reordered, because
  /// a list that rearranges itself under a thumb is unusable.
  final List<Recipe> _shown = [];

  /// Ids already placed. Pages are ranked independently, and a food can
  /// surface in two slices when its distance from the target ties.
  final Set<String> _seen = {};

  UserProfile? _profile;
  RecipeOrigin _origin = RecipeOrigin.local;
  String? _warning;
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;

  /// Whether the jump-to-top button is showing. It stays hidden near the
  /// top, where a button that scrolls to the top does nothing.
  bool _atTop = true;
  int _slotLeft = 0;
  int _hidden = 0;
  int _foodOffset = 0;
  int _foodTotal = 0;
  late String _slot;

  final _scroll = ScrollController();

  /// Raw rows fetched per page. More than appear, because the allergen and
  /// diet filters remove some of every slice.
  static const int _pageSize = 60;

  /// Start the next page while this much is still below the fold, so it
  /// arrives before the bottom does.
  static const double _loadAhead = 900;

  /// Roughly a screen and a half down, the jump-to-top button appears.
  static const double _showTopAfter = 900;

  @override
  void initState() {
    super.initState();
    _slot = widget.slot ?? categoriseByTime(DateTime.now());
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;

    // setState only when the answer actually changes. This runs on every
    // frame of every scroll, and rebuilding the list sixty times a second
    // to re-set a boolean that is already set would undo the point of
    // using a builder.
    final atTop = _scroll.position.pixels < _showTopAfter;
    if (atTop != _atTop) setState(() => _atTop = atTop);

    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < _loadAhead) _loadMore();
  }

  int get _target => _slotLeft == 0 ? 600 : _slotLeft;

  /// Refresh and return to the top.
  ///
  /// Pull-to-refresh only works from the top, and after scrolling through a
  /// few hundred suggestions the top is a long way back. This is the same
  /// refresh with the journey removed.
  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() => _loading = true);

    final profile =
        await LocalDb.instance.loadProfile() ?? UserProfile.fallback;
    final entries = await LocalDb.instance.entriesForDay(DateTime.now());
    final summary = summariseDay(entries, profile.targetKcal,
        split: macroSplitFor(profile.goal));
    final left = remainingForMeal(summary, _slot);

    final result = await Api.instance.recommendations(profile.dietType);
    final recent =
        refresh ? await LocalDb.instance.recentlyShown() : <String>{};

    // Single foods are suggested alongside recipes. Not everyone wants to
    // cook, and the 2,692 published foods are the part of this app with
    // figures that were measured rather than estimated.
    //
    // They go through exactly the same filter as recipes, which is only safe
    // because foods.db carries allergen and diet tags. An untagged food has
    // an empty allergen list, and an empty list passes every check -- a
    // peanut allergy would not have stopped a satay being offered.
    final target = left == 0 ? 600 : left;
    final foods = await FoodDb.instance
        .suggestions(targetKcal: target, limit: _pageSize);
    final total = await FoodDb.instance.suggestionCount();

    final candidates = [...result.recipes, ...foods];
    final ranked = recommend(
      candidates,
      profile.allergens,
      profile.dietType,
      target,
      recentIds: recent,
      limit: candidates.length,
    );

    if (refresh) {
      await LocalDb.instance.recordShown(ranked.take(20).map((r) => r.id));
    }

    if (!mounted) return;
    setState(() {
      _profile = profile;
      _shown
        ..clear()
        ..addAll(ranked);
      _seen
        ..clear()
        ..addAll(ranked.map((r) => r.id));
      _hidden =
          candidates.where((r) => !isSafeFor(r, profile.allergens)).length;
      _origin = result.origin;
      _warning = result.warning;
      _slotLeft = left;
      _foodOffset = _pageSize;
      _foodTotal = total;
      _exhausted = _foodOffset >= total;
      _loading = false;
    });
  }

  /// Fetch and append the next page.
  ///
  /// A slice can come back entirely filtered out -- someone avoiding gluten
  /// loses most of a run of noodle dishes -- so this keeps fetching until it
  /// has something to show or runs out. The attempt cap stops a profile that
  /// excludes nearly everything from walking the whole table in one go and
  /// freezing the scroll.
  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || _loading || _profile == null) return;
    setState(() => _loadingMore = true);

    final profile = _profile!;
    final fresh = <Recipe>[];
    var attempts = 0;

    while (fresh.isEmpty && !_exhausted && attempts < 5) {
      attempts++;
      final foods = await FoodDb.instance.suggestions(
        targetKcal: _target,
        limit: _pageSize,
        offset: _foodOffset,
      );
      _foodOffset += _pageSize;
      if (_foodOffset >= _foodTotal || foods.isEmpty) _exhausted = true;
      if (foods.isEmpty) break;

      _hidden += foods.where((r) => !isSafeFor(r, profile.allergens)).length;

      // Diet filtering is applied here rather than left to recommend().
      //
      // recommend() falls back to everything safe when nothing matches the
      // diet, which is right for a pool of 25 recipes -- better to suggest
      // something than nothing. Applied per page it goes wrong: only 282 of
      // 2,647 foods are tagged vegan, so most pages contain none, the
      // fallback fires, and a vegan quietly gets pages of everything else.
      // An empty page is the honest result; the loop just fetches the next
      // one.
      final onDiet = profile.dietType == 'balanced'
          ? foods
          : foods.where((r) => matchesDiet(r, profile.dietType)).toList();

      final ranked = recommend(
        onDiet,
        profile.allergens,
        profile.dietType,
        _target,
        limit: onDiet.length,
      );
      fresh.addAll(ranked.where((r) => !_seen.contains(r.id)));
    }

    if (!mounted) return;
    setState(() {
      _shown.addAll(fresh);
      _seen.addAll(fresh.map((r) => r.id));
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Discover')),
      // The same button as Home and Diary, in the same place, because
      // wanting to log something does not wait for the right tab.
      //
      // It reloads on the way back, which matters more here than elsewhere:
      // these suggestions are ranked against the calories left for this
      // meal, so logging one changes what should be suggested next.
      // Two buttons, and only one of them is loud. Adding food is the thing
      // people come here to do; getting back to the top is a convenience,
      // so it is smaller, quieter and sits to the left.
      //
      // This slot used to hold a refresh button. Pull-to-refresh covers
      // that, and after scrolling a long way the thing you actually want is
      // the way back -- the list is endless, so the top can be a long way
      // off. Refresh is still on the button at the end of the list.
      //
      // The heroTags are not decoration. Two FloatingActionButtons in one
      // Scaffold share the default tag, and Flutter throws on the next route
      // transition complaining that multiple heroes share it.
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Faded rather than removed, so the add button does not shift
          // sideways as this appears and disappears. IgnorePointer keeps the
          // invisible one from swallowing taps.
          AnimatedOpacity(
            opacity: _atTop ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            child: IgnorePointer(
              ignoring: _atTop,
              child: FloatingActionButton.small(
                heroTag: 'discover-scroll-top',
                onPressed: _scrollToTop,
                tooltip: 'Back to the top',
                backgroundColor: AppColors.surface,
                foregroundColor: AppColors.accent,
                shape: const CircleBorder(
                    side: BorderSide(color: AppColors.wire2)),
                child: const Icon(Icons.arrow_upward),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'discover-add',
            onPressed: () async {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AddFoodScreen()));
              _load();
            },
            tooltip: 'Add food',
            child: const Icon(Icons.add),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          // Always scrollable, so the list can be pulled down for a refresh
          // even when the suggestions do not fill the screen.
          physics: const AlwaysScrollableScrollPhysics(),
          // A builder rather than a list of children: this grows into the
          // hundreds, and the plain ListView would build every card whether
          // or not it is anywhere near the screen.
          itemCount: _shown.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) return _header();
            if (index <= _shown.length) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _recipeCard(_shown[index - 1]),
              );
            }
            return _footer();
          },
        ),
      ),
    );
  }

  Widget _header() {
    final profile = _profile!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text('For $_slot, about $_slotLeft kcal', style: tHead),
            ),
            WireChip('${_shown.length} shown'),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            WireChip(
              _origin == RecipeOrigin.api
                  ? 'Live from the recipe service'
                  : 'Offline meals',
              filled: _origin == RecipeOrigin.api,
            ),
          ],
        ),
        if (_warning != null) ...[
          const SizedBox(height: 8),
          WireNote(_warning!, warning: true),
        ],
        const SizedBox(height: 8),
        // Reads back the labels the user chose, not the internal tokens:
        // someone who ticked "Dairy" should not be told about "milk".
        if (profile.restrictions.isNotEmpty)
          WireNote(
            '${_listPhrase(profile.restrictions)} '
            '${profile.restrictions.length == 1 ? 'is' : 'are'} excluded from '
            'everything you see here. $_hidden '
            '${_hidden == 1 ? 'meal' : 'meals'} hidden so far.',
            warning: true,
          )
        else
          const WireNote(
            'You have no dietary restrictions recorded, so nothing is being '
            'filtered out. Add them on the Profile tab.',
          ),
        if (profile.dietType != 'balanced') ...[
          const SizedBox(height: 8),
          WireNote('Matched against your ${profile.dietType.replaceAll('-', ' ')} '
              'preference.'),
        ],
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _footer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_exhausted)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
                'That is every suggestion for $_slot. Pull down, or use the '
                'button below, for a different set.',
                style: tMute),
          ),
        Row(
          children: [
            Expanded(
              child: WireButton(
                label: 'Refresh',
                outlined: true,
                onPressed: () => _load(refresh: true),
              ),
            ),
          ],
        ),
        // Any, not first: the list mixes published figures with estimated
        // ones, so the caveat has to follow whether an estimate is on
        // screen rather than what happens to be at the top.
        if (_shown.any((r) => r.estimated)) ...[
          const SizedBox(height: 12),
          const Text(
              '* Calories are estimated from the ingredient list. '
              'TheMealDB publishes no nutrition data.',
              style: tMute),
        ],
        const SizedBox(height: 6),
        const Text(
            'Recipe data and imagery: TheMealDB (https://www.themealdb.com/)',
            style: tMute),
        const SizedBox(height: 40),
      ],
    );
  }

  /// "Dairy", "Dairy and Eggs", "Dairy, Eggs and Peanuts".
  static String _listPhrase(List<String> items) {
    if (items.length == 1) return items.first;
    return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
  }

  Widget _recipeCard(Recipe r) {
    return WireCard(
      onTap: () async {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => RecipeDetailScreen(
                    recipe: r, slot: _slot, profile: _profile!)));
        if (mounted) _load();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const WireBox(height: 78),
          const SizedBox(height: 8),
          Text(r.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            '${r.kcal} kcal${r.estimated ? '*' : ''}, ${r.proteinG} g protein'
            '${r.minutes != null ? ', ${r.minutes} min' : ''}'
            '${r.area != null ? ', ${r.area}' : ''}',
            style: tMute,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in r.dietTypes) WireChip(capitalise(d)),
              for (final a in r.allergens) WireChip('Lists $a', warning: true),
            ],
          ),
        ],
      ),
    );
  }
}
