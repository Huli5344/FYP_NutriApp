"""
Unit tests for the Diary and Recommendations module.

Run:  python -m unittest tests

These cover logic.py, which holds every rule the module calculates, plus the
server, the sync protocol and the admin panel.
"""

# ---------------------------------------------------------------------------
# Pin the tests to a throwaway SQLite file, BEFORE importing anything from the
# project.
#
# This is not a convenience. Many tests below call database.init(force=True),
# which drops every table; db.py reads .env.local at import time, and that
# file holds the Neon connection string. Run from the backend folder with
# .env.local present, the suite therefore pointed itself at the production
# database and dropped it once per test class.
#
# Setting the variables to empty strings is what stops it: load_env_files()
# only fills a key that is "not in os.environ", so a key already present --
# even empty -- is left alone, and _env_url() reads an empty string as
# "no URL configured", which means SQLite.
#
# Ordering is the whole trick, so nothing from the project may be imported
# above this block. The assertion underneath is what makes a future edit that
# moves an import fail here rather than against Neon.
# ---------------------------------------------------------------------------
import os
import tempfile

os.environ["DATABASE_URL"] = ""
os.environ["DATABASE_URL_UNPOOLED"] = ""

import db  # noqa: E402

assert not db.is_postgres(), (
    "The test suite is pointed at PostgreSQL. It calls init(force=True), "
    "which drops every table, so it must only ever run against a scratch "
    "SQLite file. Something set DATABASE_URL after this module began "
    "importing.")

db.SQLITE_PATH = os.path.join(tempfile.gettempdir(), "nutriapp_tests.db")

import unittest  # noqa: E402
from datetime import datetime  # noqa: E402

import logic  # noqa: E402


class TestCalorieCalculation(unittest.TestCase):
    """Calorie calculation."""

    def test_doubling_the_quantity_doubles_the_calories(self):
        food = {"kcal": 300, "carbs_g": 40, "protein_g": 20, "fat_g": 8}
        self.assertEqual(logic.scale_nutrition(food, 2)["kcal"], 600)

    def test_fractional_servings(self):
        food = {"kcal": 607, "carbs_g": 78, "protein_g": 34, "fat_g": 18}
        result = logic.scale_nutrition(food, 1.5)
        self.assertEqual(result["kcal"], 910)      # 910.5 rounds to even
        self.assertEqual(result["protein_g"], 51.0)

    def test_macros_scale_with_the_calories(self):
        food = {"kcal": 100, "carbs_g": 10, "protein_g": 5, "fat_g": 2}
        result = logic.scale_nutrition(food, 3)
        self.assertEqual(result["carbs_g"], 30.0)
        self.assertEqual(result["fat_g"], 6.0)


class TestCategorisation(unittest.TestCase):
    """Automatic meal categorisation."""

    def test_each_window_maps_to_its_category(self):
        cases = [("2026-09-17T08:00", "breakfast"), ("2026-09-17T13:05", "lunch"),
                 ("2026-09-17T19:30", "dinner"), ("2026-09-17T23:30", "snacks"),
                 ("2026-09-17T02:00", "snacks")]
        for stamp, expected in cases:
            with self.subTest(stamp=stamp):
                self.assertEqual(logic.categorise_by_time(stamp), expected)

    def test_window_boundaries(self):
        self.assertEqual(logic.categorise_by_time("2026-09-17T10:59"), "breakfast")
        self.assertEqual(logic.categorise_by_time("2026-09-17T11:00"), "lunch")
        self.assertEqual(logic.categorise_by_time("2026-09-17T15:59"), "lunch")
        self.assertEqual(logic.categorise_by_time("2026-09-17T16:00"), "dinner")

    def test_a_backdated_meal_uses_the_meal_time(self):
        # Recorded at midnight for a meal eaten at lunchtime: still lunch.
        self.assertEqual(logic.categorise_by_time(datetime(2026, 9, 17, 13, 0)), "lunch")

    def test_accepts_strings_and_datetimes_alike(self):
        self.assertEqual(logic.categorise_by_time(datetime(2026, 9, 17, 8, 0)), "breakfast")


class TestTagging(unittest.TestCase):
    """Dietary-type tagging."""

    def test_high_protein_threshold(self):
        self.assertIn("high-protein", logic.auto_tags(
            {"protein_g": 25, "carbs_g": 30, "fat_g": 10}))
        self.assertNotIn("high-protein", logic.auto_tags(
            {"protein_g": 24.9, "carbs_g": 30, "fat_g": 10}))

    def test_a_serving_can_earn_several_tags(self):
        tags = logic.auto_tags({"protein_g": 40, "carbs_g": 10, "fat_g": 3})
        self.assertIn("high-protein", tags)
        self.assertIn("low-carb", tags)
        self.assertIn("low-fat", tags)

    def test_no_tags_returns_an_empty_list(self):
        # Empty must be distinguishable from "not evaluated", because the
        # interface uses it to offer manual tagging.
        self.assertEqual(logic.auto_tags({"protein_g": 15, "carbs_g": 40, "fat_g": 15}), [])


class TestMealSplit(unittest.TestCase):
    """The allowance per meal."""

    def test_split_sums_exactly_to_the_target(self):
        for target in (1200, 1850, 1851, 2333, 3000):
            with self.subTest(target=target):
                self.assertEqual(sum(logic.split_target(target).values()), target)

    def test_dinner_takes_the_largest_share(self):
        parts = logic.split_target(2000)
        self.assertEqual(max(parts, key=parts.get), "dinner")

    def test_macro_targets_reconstruct_the_calories(self):
        target = 1850
        m = logic.macro_targets(target)
        kcal = m["carbs_g"] * 4 + m["protein_g"] * 4 + m["fat_g"] * 9
        self.assertLess(abs(kcal - target), 15)


class TestDailySummary(unittest.TestCase):
    """Daily summary and dashboard."""

    def entry(self, kcal, category, protein=10):
        return {"kcal": kcal, "carbs_g": 20.0, "protein_g": protein,
                "fat_g": 5.0, "category": category}

    def test_totals_and_remaining(self):
        s = logic.summarise_day(
            [self.entry(430, "breakfast"), self.entry(620, "lunch")], 1850)
        self.assertEqual(s["eaten"], 1050)
        self.assertEqual(s["remaining"], 800)
        self.assertFalse(s["over"])

    def test_remaining_goes_negative_when_over_target(self):
        # Clamping at zero would hide the overshoot from the user.
        s = logic.summarise_day([self.entry(2000, "dinner")], 1850)
        self.assertEqual(s["remaining"], -150)
        self.assertTrue(s["over"])

    def test_calories_group_by_category(self):
        s = logic.summarise_day(
            [self.entry(300, "breakfast"), self.entry(200, "breakfast"),
             self.entry(600, "dinner")], 1850)
        self.assertEqual(s["by_category"]["breakfast"], 500)
        self.assertEqual(s["by_category"]["dinner"], 600)
        self.assertEqual(s["by_category"]["lunch"], 0)

    def test_empty_day(self):
        s = logic.summarise_day([], 1850)
        self.assertEqual(s["eaten"], 0)
        self.assertEqual(s["remaining"], 1850)
        self.assertEqual(s["entry_count"], 0)

    def test_remaining_for_a_meal_never_goes_negative(self):
        s = logic.summarise_day([self.entry(900, "breakfast")], 1850)
        # Breakfast allows about 463 kcal; 900 was eaten.
        self.assertEqual(logic.remaining_for_meal(s, "breakfast"), 0)
        self.assertGreater(logic.remaining_for_meal(s, "dinner"), 0)


class TestSeededPoolIsBigEnough(unittest.TestCase):
    """The offline set must still fill the screen after filtering."""

    def test_every_diet_type_can_produce_a_full_list(self):
        import database
        pool = [{
            "id": f"local-{i}", "name": name, "kcal": kcal,
            "carbs_g": c, "protein_g": pr, "fat_g": f,
            "allergens": [a for a in allergens.split(",") if a],
            "diet_types": [d for d in diets.split(",") if d],
        } for i, (name, kcal, c, pr, f, mins, allergens, diets, ing)
            in enumerate(database.RECIPES, start=1)]

        for diet in ("balanced", "vegan", "vegetarian", "high-protein", "high-fibre"):
            with self.subTest(diet=diet):
                picks = logic.recommend(pool, ["peanut", "shellfish"], diet, 600,
                                        limit=logic.SHOWN_EXPANDED)
                self.assertEqual(len(picks), logic.SHOWN_EXPANDED)


class TestRecommendations(unittest.TestCase):
    """Retrieval and filtering."""

    def setUp(self):
        self.recipes = [
            {"id": 1, "name": "Satay chicken", "kcal": 600, "allergens": ["peanut"],
             "diet_types": ["high-protein"]},
            {"id": 2, "name": "Prawn fried rice", "kcal": 610, "allergens": ["shellfish"],
             "diet_types": []},
            {"id": 3, "name": "Chickpea curry", "kcal": 598, "allergens": [],
             "diet_types": ["vegetarian", "vegan"]},
            {"id": 4, "name": "Lentil soup", "kcal": 430, "allergens": ["gluten"],
             "diet_types": ["vegetarian", "vegan"]},
            {"id": 5, "name": "Beef stew", "kcal": 590, "allergens": [],
             "diet_types": ["high-protein"]},
        ]

    def big_pool(self):
        pool = []
        for i in range(20):
            r = dict(self.recipes[i % len(self.recipes)])
            r["id"] = f"r-{i}"
            r["kcal"] = 400 + i * 20
            pool.append(r)
        return pool

    def test_the_display_sizes_are_three_then_eight(self):
        self.assertEqual(logic.SHOWN_INITIALLY, 3)
        self.assertEqual(logic.MORE_STEP, 5)
        self.assertEqual(logic.SHOWN_EXPANDED, 8)

    def test_the_limit_is_respected(self):
        pool = self.big_pool()
        self.assertEqual(len(logic.recommend(pool, [], "balanced", 600,
                                             limit=logic.SHOWN_INITIALLY)), 3)
        self.assertEqual(len(logic.recommend(pool, [], "balanced", 600,
                                             limit=logic.SHOWN_EXPANDED)), 8)

    def test_expanding_keeps_the_first_three_in_place(self):
        # The reveal must append, not reshuffle, or the user loses their place.
        pool = self.big_pool()
        three = logic.recommend(pool, [], "balanced", 600, limit=logic.SHOWN_INITIALLY)
        eight = logic.recommend(pool, [], "balanced", 600, limit=logic.SHOWN_EXPANDED)
        self.assertEqual([r["id"] for r in eight[:3]], [r["id"] for r in three])

    def test_a_short_pool_returns_what_it_has_rather_than_failing(self):
        picks = logic.recommend(self.recipes, [], "balanced", 600)
        self.assertEqual(len(picks), len(self.recipes))

    def test_allergen_recipes_are_removed_entirely(self):
        picks = logic.recommend(self.recipes, ["peanut"], "balanced", 600)
        self.assertNotIn("Satay chicken", [p["name"] for p in picks])

    def test_exclusion_beats_a_perfect_calorie_match(self):
        # Satay is the closest fit to 600 kcal and must still not appear.
        picks = logic.recommend(self.recipes, ["peanut"], "balanced", 600)
        self.assertTrue(all("peanut" not in p["allergens"] for p in picks))

    def test_several_allergens_all_apply(self):
        picks = logic.recommend(self.recipes, ["peanut", "shellfish", "gluten"],
                                "balanced", 600)
        self.assertEqual({p["id"] for p in picks}, {3, 5})

    def test_matching_is_case_insensitive(self):
        self.assertFalse(logic.is_safe_for(self.recipes[0], ["PEANUT"]))

    def test_diet_type_filters_but_falls_back_rather_than_returning_nothing(self):
        vegan = logic.recommend(self.recipes, [], "vegan", 600)
        self.assertTrue(all("vegan" in p["diet_types"] for p in vegan))
        keto = logic.recommend(self.recipes, [], "keto", 600)   # nothing tagged keto
        self.assertTrue(len(keto) > 0)

    def test_closest_calorie_match_ranks_first(self):
        picks = logic.recommend(self.recipes, [], "balanced", 600)
        self.assertEqual(picks[0]["id"], 1)

    def test_recently_shown_meals_are_pushed_down(self):
        picks = logic.recommend(self.recipes, [], "balanced", 600, recent_ids={1})
        self.assertNotEqual(picks[0]["id"], 1)

    def test_a_zero_allowance_still_returns_suggestions(self):
        # The meal's allowance is used up, but the user may still want ideas.
        picks = logic.recommend(self.recipes, [], "balanced", 0)
        self.assertEqual(len(picks), len(self.recipes))



# External recipe service
# These run against saved copies of real TheMealDB responses in fixtures/, so
# they pass with no network access. What they cannot prove is that the live
# service still answers; use Test connection on the Recipe service screen.

import json
import os
from unittest import mock

import recipes_api


def fixture(name):
    with open(os.path.join(os.path.dirname(__file__), "fixtures", name)) as fh:
        return json.load(fh)


class TestMeasureParsing(unittest.TestCase):
    """The measure strings TheMealDB actually uses."""

    def test_simple_quantities(self):
        self.assertEqual(recipes_api.parse_measure("3 cups"), (3.0, "cup"))
        self.assertEqual(recipes_api.parse_measure("1/2 teaspoon"), (0.5, "tsp"))

    def test_vulgar_fractions(self):
        self.assertEqual(recipes_api.parse_measure("3/4 cup"), (0.75, "cup"))
        self.assertEqual(recipes_api.parse_measure("\u00bd tsp"), (0.5, "tsp"))

    def test_parenthesised_pack_size_wins(self):
        # "1 (12 oz.)" is one packet of twelve ounces, not one of something.
        self.assertEqual(recipes_api.parse_measure("1 (12 oz.)"), (12.0, "oz"))

    def test_bare_count_has_no_unit(self):
        self.assertEqual(recipes_api.parse_measure("2"), (2.0, None))

    def test_unparseable_measures_return_none(self):
        for junk in ("", "Some", "to taste", None):
            with self.subTest(junk=junk):
                self.assertEqual(recipes_api.parse_measure(junk), (None, None))


class TestAllergenDerivation(unittest.TestCase):
    """Applied to free-text ingredient lists."""

    def test_direct_matches(self):
        self.assertIn("shellfish", recipes_api.derive_allergens(["king prawns"]))
        self.assertIn("milk", recipes_api.derive_allergens(["double cream"]))

    def test_derivatives_are_caught(self):
        # The point of the keyword map: none of these name the allergen.
        self.assertIn("peanut", recipes_api.derive_allergens(["satay sauce"]))
        self.assertIn("fish", recipes_api.derive_allergens(["worcestershire sauce"]))
        self.assertIn("gluten", recipes_api.derive_allergens(["soy sauce"]))

    def test_false_positives_are_excluded(self):
        self.assertNotIn("milk", recipes_api.derive_allergens(["coconut milk"]))
        self.assertNotIn("gluten", recipes_api.derive_allergens(["rice flour"]))
        self.assertNotIn("nuts", recipes_api.derive_allergens(["nutmeg"]))

    def test_clean_ingredients_return_nothing(self):
        self.assertEqual(recipes_api.derive_allergens(["carrot", "onion"]), [])


class TestNutritionEstimation(unittest.TestCase):
    """TheMealDB publishes no nutrition data, so it is estimated locally."""

    def test_a_real_recipe_lands_in_a_plausible_range(self):
        meal = fixture("lookup_52772.json")["meals"][0]
        names, measures = recipes_api.extract_ingredients(meal)
        n = recipes_api.estimate_nutrition(names, measures)
        self.assertGreater(n["kcal"], 200)
        self.assertLess(n["kcal"], 900)

    def test_the_result_is_labelled_as_an_estimate(self):
        n = recipes_api.estimate_nutrition(["chicken breast"], ["200 g"])
        self.assertTrue(n["estimated"])
        self.assertIn(n["confidence"], ("good", "fair", "rough"))

    def test_confidence_falls_when_ingredients_are_unrecognised(self):
        known = recipes_api.estimate_nutrition(["chicken breast", "rice"], ["200 g", "1 cup"])
        unknown = recipes_api.estimate_nutrition(["achiote seed", "epazote"], ["1 tsp", "2"])
        self.assertEqual(known["confidence"], "good")
        self.assertEqual(unknown["confidence"], "rough")


class TestNormalisation(unittest.TestCase):
    """Turning a TheMealDB record into the shape this module uses."""

    def setUp(self):
        self.meal = recipes_api.normalise_meal(fixture("lookup_52772.json")["meals"][0])

    def test_ingredients_pair_with_measures_in_order(self):
        self.assertEqual(self.meal["ingredients"][0], "3/4 cup soy sauce")

    def test_empty_and_null_slots_are_dropped(self):
        self.assertEqual(len(self.meal["ingredients"]), 9)

    def test_id_is_namespaced_so_it_cannot_collide_with_local_recipes(self):
        self.assertEqual(self.meal["id"], "mdb-52772")
        self.assertEqual(self.meal["source"], "themealdb")

    def test_allergens_are_derived_from_the_ingredients(self):
        # soy sauce implies both soy and gluten; neither is declared.
        self.assertIn("soy", self.meal["allergens"])
        self.assertIn("gluten", self.meal["allergens"])


class TestRecommendationOverApiData(unittest.TestCase):
    """The safety rule must hold on external data, not just seeded data."""

    def test_allergen_exclusion_applies_to_api_meals(self):
        meal = recipes_api.normalise_meal(fixture("lookup_52772.json")["meals"][0])
        self.assertEqual(logic.recommend([meal], ["soy"], "balanced", 600), [])

    def test_an_unrelated_allergy_does_not_remove_it(self):
        meal = recipes_api.normalise_meal(fixture("lookup_52772.json")["meals"][0])
        self.assertEqual(len(logic.recommend([meal], ["peanut"], "balanced", 600)), 1)


class TestStringRecipeIds(unittest.TestCase):
    """Ids are strings once meals can come from two sources."""

    def test_mixed_sources_rank_together(self):
        meals = [
            {"id": "mdb-1", "name": "A", "kcal": 600, "allergens": [], "diet_types": []},
            {"id": "local-1", "name": "B", "kcal": 900, "allergens": [], "diet_types": []},
        ]
        self.assertEqual(logic.recommend(meals, [], "balanced", 600)[0]["id"], "mdb-1")

    def test_recently_shown_works_with_string_ids(self):
        meals = [
            {"id": "mdb-1", "name": "A", "kcal": 600, "allergens": [], "diet_types": []},
            {"id": "local-1", "name": "B", "kcal": 610, "allergens": [], "diet_types": []},
        ]
        picks = logic.recommend(meals, [], "balanced", 600, recent_ids={"mdb-1"})
        self.assertEqual(picks[0]["id"], "local-1")


class TestApiErrorHandling(unittest.TestCase):
    """Network failures must degrade, not crash."""

    def test_network_failure_raises_apierror(self):
        with mock.patch("urllib.request.urlopen", side_effect=OSError("no route")):
            with self.assertRaises(recipes_api.ApiError):
                recipes_api.call("categories.php", {}, use_cache=False)

    def test_malformed_response_raises_apierror(self):
        broken = mock.MagicMock()
        broken.read.return_value = b"<html>error</html>"
        broken.__enter__ = lambda s: broken
        broken.__exit__ = lambda *a: False
        with mock.patch("urllib.request.urlopen", return_value=broken):
            with self.assertRaises(recipes_api.ApiError):
                recipes_api.call("categories.php", {}, use_cache=False)

    def test_test_connection_reports_failure_without_raising(self):
        with mock.patch("urllib.request.urlopen", side_effect=OSError("unreachable")):
            result = recipes_api.test_connection()
        self.assertFalse(result["ok"])
        self.assertIn("unreachable", result["detail"])

    def test_duplicates_are_removed_across_categories(self):
        meal = fixture("lookup_52772.json")["meals"][0]
        calls = {"n": 0}

        def fake_fetch(category, limit=6, key=None):
            calls["n"] += 1
            return [recipes_api.normalise_meal(meal)], "api"

        with mock.patch.object(recipes_api, "fetch_by_category", fake_fetch):
            pool, origin = recipes_api.fetch_for_diet("balanced")
        self.assertGreater(calls["n"], 1)
        self.assertEqual(len(pool), 1)

    def test_all_categories_failing_raises(self):
        def always_fails(category, limit=6, key=None):
            raise recipes_api.ApiError("down")
        with mock.patch.object(recipes_api, "fetch_by_category", always_fails):
            with self.assertRaises(recipes_api.ApiError):
                recipes_api.fetch_for_diet("balanced")



# Offline sync

import uuid as _uuid
from datetime import timedelta, timezone

import sync


def stamp(offset_minutes=0):
    return (datetime.now(timezone.utc)
            + timedelta(minutes=offset_minutes)).isoformat(timespec="seconds")


def make_entry(eid=None, **kw):
    row = {"id": eid or str(_uuid.uuid4()), "food_name": "Chicken rice",
           "kcal": 607, "category": "lunch", "eaten_at": "2026-09-19T13:00",
           "updated_at": stamp(), "quantity": 1, "serving": "1 plate",
           "carbs_g": 78.0, "protein_g": 34.0, "fat_g": 18.0,
           "tags": "", "note": "", "source": "manual"}
    row.update(kw)
    return row


class TestClockSkew(unittest.TestCase):
    """A device with a wrong clock must not win every conflict forever."""

    def test_a_future_stamp_is_pulled_back_to_the_server_clock(self):
        sent = stamp(60)
        stored = sync.clamp_timestamp(sent)
        self.assertLess(sync.parse(stored), sync.parse(sent))

    def test_small_skew_is_tolerated(self):
        sent = stamp(2)                      # inside MAX_CLOCK_SKEW
        self.assertEqual(sync.clamp_timestamp(sent), sync.parse(sent).isoformat(timespec="seconds"))

    def test_a_past_stamp_is_left_alone(self):
        sent = stamp(-120)
        self.assertEqual(sync.clamp_timestamp(sent), sync.parse(sent).isoformat(timespec="seconds"))

    def test_an_unreadable_stamp_becomes_now_rather_than_failing(self):
        for junk in ("", None, "yesterday", 12345):
            with self.subTest(junk=junk):
                self.assertIsNotNone(sync.parse(sync.clamp_timestamp(junk)))


class TestConflictResolution(unittest.TestCase):
    """Last write wins, compared on updated_at."""

    def test_a_newer_edit_replaces_an_older_one(self):
        existing = make_entry(updated_at=stamp(-10))
        incoming = dict(existing, updated_at=stamp())
        self.assertTrue(sync.should_apply(incoming, existing))

    def test_an_older_edit_is_rejected(self):
        existing = make_entry(updated_at=stamp())
        incoming = dict(existing, updated_at=stamp(-10))
        self.assertFalse(sync.should_apply(incoming, existing))

    def test_an_unseen_row_is_always_applied(self):
        self.assertTrue(sync.should_apply(make_entry(), None))

    def test_an_identical_replay_is_a_no_op(self):
        # A client that pushes, loses the response and retries must not churn
        # server_seq and drag every other device into a pointless pull.
        row = make_entry()
        self.assertFalse(sync.should_apply(row, row))


class TestPushValidation(unittest.TestCase):
    """Rubbish from a client is rejected rather than stored."""

    def test_rows_missing_required_fields_are_invalid(self):
        self.assertFalse(sync.is_valid({"id": "x"}))
        self.assertFalse(sync.is_valid({"food_name": "no id"}))
        self.assertFalse(sync.is_valid("not a dict"))

    def test_a_complete_row_is_valid(self):
        self.assertTrue(sync.is_valid(make_entry()))

    def test_server_only_fields_cannot_be_set_by_a_client(self):
        # server_seq is the pull cursor; a client writing it would corrupt
        # every other device's idea of what it has already seen.
        cleaned = sync.clean(make_entry(server_seq=9999))
        self.assertNotIn("server_seq", cleaned)

    def test_the_deleted_flag_is_normalised_to_an_integer(self):
        self.assertEqual(sync.clean(make_entry(deleted=True))["deleted"], 1)
        self.assertEqual(sync.clean(make_entry())["deleted"], 0)


class TestSyncEndpoint(unittest.TestCase):
    """The push-and-pull round trip, against a real database."""

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.client = app.app.test_client()

        # Sync is per account now, so these need a real one. Registering
        # through the endpoint rather than inserting a row keeps the test
        # honest about the path a device actually takes.
        response = self.client.post("/api/register", json={
            "email": "sync-tests@example.com",
            "password": "a sufficiently long password",
            "name": "Sync Tests"})
        self.token = response.get_json()["token"]
        self.auth = {"Authorization": f"Bearer {self.token}"}

    def second_account(self):
        """A token for a different account, for the isolation checks."""
        response = self.client.post("/api/register", json={
            "email": "other-sync@example.com",
            "password": "a different long password",
            "name": "Other"})
        return {"Authorization": f"Bearer {response.get_json()['token']}"}

    def raw_post(self, payload, headers=None):
        return self.client.post(
            "/sync", json=payload,
            headers=self.auth if headers is None else headers)

    def post(self, since=0, changes=(), headers=None):
        return self.raw_post({"since": since, "changes": list(changes)},
                             headers).get_json()

    def test_a_pushed_entry_comes_back_on_a_pull(self):
        row = make_entry()
        result = self.post(0, [row])
        self.assertEqual(result["push"]["applied"], 1)
        self.assertEqual([c["id"] for c in result["changes"]], [row["id"]])

    def test_a_second_device_pulls_what_the_first_pushed(self):
        row = make_entry()
        self.post(0, [row])
        fresh = self.post(0)                       # a device that has seen nothing
        self.assertEqual(len(fresh["changes"]), 1)

    def test_the_cursor_stops_a_device_re_downloading_its_own_writes(self):
        first = self.post(0, [make_entry()])
        again = self.post(first["cursor"])
        self.assertEqual(again["changes"], [])

    def test_a_deletion_travels_as_a_tombstone(self):
        row = make_entry()
        self.post(0, [row])
        self.post(0, [dict(row, deleted=1, updated_at=stamp(1))])
        pulled = self.post(0)["changes"]
        self.assertEqual(len(pulled), 1)
        self.assertEqual(pulled[0]["deleted"], 1)

    def test_a_deleted_entry_is_hidden_from_the_diary(self):
        row = make_entry()
        self.post(0, [row])
        self.post(0, [dict(row, deleted=1, updated_at=stamp(1))])
        page = self.client.get("/diary").get_data(as_text=True)
        self.assertNotIn(row["food_name"], page)

    def test_a_deleted_entry_is_not_resurrected_by_the_next_pull(self):
        # The failure this design exists to prevent: a hard DELETE leaves the
        # server holding the row, which the next pull hands straight back.
        row = make_entry()
        self.post(0, [row])
        self.post(0, [dict(row, deleted=1, updated_at=stamp(1))])
        for c in self.post(0)["changes"]:
            if c["id"] == row["id"]:
                self.assertEqual(c["deleted"], 1)

    def test_an_invalid_row_does_not_block_the_valid_ones_beside_it(self):
        good = make_entry()
        result = self.post(0, [{"id": "broken"}, good])
        self.assertEqual(result["push"]["applied"], 1)
        self.assertEqual(result["push"]["invalid"], 1)

    def test_a_malformed_cursor_is_refused(self):
        response = self.raw_post({"since": "yesterday"})
        self.assertEqual(response.status_code, 400)

    def test_sync_without_a_token_is_refused(self):
        """Before the body is even looked at: no account, no data."""
        response = self.client.post("/sync", json={"since": 0})
        self.assertEqual(response.status_code, 401)

    def test_sync_with_an_unknown_token_is_refused(self):
        response = self.raw_post(
            {"since": 0}, headers={"Authorization": "Bearer not-a-real-token"})
        self.assertEqual(response.status_code, 401)

    def test_an_oversized_push_is_refused(self):
        response = self.raw_post({"since": 0, "changes": [make_entry()] * 501})
        self.assertEqual(response.status_code, 413)

    def test_another_account_cannot_see_these_entries(self):
        self.post(0, [make_entry()])
        theirs = self.post(0, headers=self.second_account())
        self.assertEqual(theirs["changes"], [])

    def test_another_account_cannot_overwrite_an_entry_by_its_id(self):
        """The one that has to hold.

        Entry ids are generated on the device, so a collision between two
        accounts is either a bug or an attack. If the upsert resolved on id
        alone, this push would rewrite the first account's row and take
        ownership of it.
        """
        row = make_entry()
        self.post(0, [row])
        self.post(0, [dict(row, food_name="Hijacked", updated_at=stamp(5))],
                  headers=self.second_account())

        mine = self.post(0)["changes"]
        self.assertEqual(len(mine), 1)
        self.assertEqual(mine[0]["food_name"], row["food_name"])

    def test_the_response_carries_the_server_clock(self):
        self.assertIsNotNone(sync.parse(self.post(0)["server_time"]))


class TestBasalMetabolicRate(unittest.TestCase):
    """Mifflin-St Jeor, against figures worked through by hand."""

    def test_male_matches_the_published_equation(self):
        # 10(80) + 6.25(180) - 5(30) + 5 = 800 + 1125 - 150 + 5
        self.assertEqual(
            logic.basal_metabolic_rate(30, 180, 80, "Male"), 1780)

    def test_female_matches_the_published_equation(self):
        # 10(58) + 6.25(163) - 5(23) - 161 = 580 + 1018.75 - 115 - 161
        self.assertEqual(
            logic.basal_metabolic_rate(23, 163, 58, "Female"), 1323)

    def test_unstated_sex_lands_between_the_two(self):
        male = logic.basal_metabolic_rate(30, 170, 70, "Male")
        female = logic.basal_metabolic_rate(30, 170, 70, "Female")
        either = logic.basal_metabolic_rate(30, 170, 70, None)
        self.assertLess(female, either)
        self.assertLess(either, male)

    def test_an_unrecognised_gender_is_treated_as_unstated(self):
        self.assertEqual(
            logic.basal_metabolic_rate(30, 170, 70, "Non-binary"),
            logic.basal_metabolic_rate(30, 170, 70, None))

    def test_never_negative_anywhere_in_the_accepted_range(self):
        # The equation stays positive across every input the forms accept, so
        # the floor is defensive rather than load-bearing. Checked at the
        # corners, and separately below with input the forms would reject.
        for age in (13, 120):
            for height in (90.0, 250.0):
                for weight in (25.0, 400.0):
                    for gender in ("Male", "Female", None):
                        self.assertGreater(
                            logic.basal_metabolic_rate(age, height, weight,
                                                       gender), 0)

    def test_the_floor_holds_for_input_the_forms_would_reject(self):
        self.assertEqual(logic.basal_metabolic_rate(500, 90, 25, "Female"), 0)


class TestDailyTarget(unittest.TestCase):

    def test_activity_level_raises_the_target(self):
        base = dict(age=30, height_cm=175, weight_kg=75, goal="Maintain Weight")
        sedentary = logic.daily_target_for(activity_level="Sedentary", **base)
        active = logic.daily_target_for(activity_level="Very Active", **base)
        self.assertGreater(active, sedentary)

    def test_losing_weight_lowers_it_and_gaining_raises_it(self):
        base = dict(age=30, height_cm=175, weight_kg=75,
                    activity_level="Moderately Active")
        maintain = logic.daily_target_for(goal="Maintain Weight", **base)
        lose = logic.daily_target_for(goal="Lose Weight", **base)
        gain = logic.daily_target_for(goal="Gain Weight", **base)
        self.assertLess(lose, maintain)
        self.assertGreater(gain, maintain)

    def test_eat_healthier_is_a_maintenance_target(self):
        base = dict(age=30, height_cm=175, weight_kg=75,
                    activity_level="Moderately Active")
        self.assertEqual(logic.daily_target_for(goal="Eat Healthier", **base),
                         logic.daily_target_for(goal="Maintain Weight", **base))

    def test_a_deficit_never_drops_below_resting_burn(self):
        """The rule that matters most here.

        A small, sedentary person on a 500 kcal deficit comes out below what
        their body uses at rest. The formula has to refuse that.
        """
        bmr = logic.basal_metabolic_rate(25, 155, 48, "Female")
        target = logic.daily_target_for(
            age=25, height_cm=155, weight_kg=48, gender="Female",
            activity_level="Sedentary", goal="Lose Weight")
        self.assertGreaterEqual(target, bmr)

    def test_the_floor_applies_even_to_a_tiny_resting_burn(self):
        target = logic.daily_target_for(
            age=90, height_cm=140, weight_kg=35, gender="Female",
            activity_level="Sedentary", goal="Lose Weight")
        self.assertGreaterEqual(target, logic.MIN_DAILY_TARGET)

    def test_a_very_large_input_is_capped(self):
        target = logic.daily_target_for(
            age=20, height_cm=220, weight_kg=250, gender="Male",
            activity_level="Very Active", goal="Gain Weight")
        self.assertLessEqual(target, logic.MAX_DAILY_TARGET)

    def test_rounded_to_ten(self):
        target = logic.daily_target_for(
            age=23, height_cm=163, weight_kg=58, gender="Female",
            activity_level="Lightly Active", goal="Lose Weight")
        self.assertEqual(target % 10, 0)

    def test_an_unknown_activity_level_uses_the_default(self):
        base = dict(age=30, height_cm=175, weight_kg=75, goal="Maintain Weight")
        self.assertEqual(
            logic.daily_target_for(activity_level="Olympian", **base),
            logic.daily_target_for(activity_level="Moderately Active", **base))


class TestLabelNormalisation(unittest.TestCase):
    """The bug this whole layer exists to prevent.

    The setup form speaks in labels people recognise and the recipe data in
    allergen tokens. Without the translation the comparison in is_safe_for
    matches nothing, so a declared allergy filters out nothing at all.
    """

    def test_dairy_becomes_milk(self):
        self.assertEqual(logic.normalise_allergens(["Dairy"]), ["milk"])

    def test_plurals_become_the_singular_token(self):
        self.assertEqual(logic.normalise_allergens(["Peanuts"]), ["peanut"])
        self.assertEqual(logic.normalise_allergens(["Eggs"]), ["egg"])

    def test_tree_nuts_becomes_the_token_the_data_uses(self):
        self.assertEqual(logic.normalise_allergens(["Tree Nuts"]), ["nuts"])

    def test_every_form_label_maps_onto_a_real_allergen_token(self):
        """No chip may exist that cannot match anything.

        An option that can be selected and then changes nothing is worse than
        not offering it, because the user believes they are protected.
        """
        known = set(recipes_api.ALLERGEN_KEYWORDS)
        for label, token in logic.ALLERGEN_TOKENS.items():
            self.assertIn(token, known, f"{label} maps to unknown {token}")

    def test_every_preference_label_maps_onto_a_derivable_diet_token(self):
        derivable = {"vegan", "vegetarian", "pescatarian", "halal",
                     "high-protein", "high-fibre", "low-carb"}
        for label, token in logic.DIET_TOKENS.items():
            self.assertIn(token, derivable, f"{label} maps to unknown {token}")

    def test_normalised_allergens_actually_filter(self):
        """End to end: a label, through the map, to an excluded recipe."""
        recipe = {"id": "r1", "kcal": 500, "allergens": ["milk"],
                  "diet_types": []}
        self.assertFalse(
            logic.is_safe_for(recipe, logic.normalise_allergens(["Dairy"])))
        # And the failure mode it replaces: the raw label matches nothing.
        self.assertTrue(logic.is_safe_for(recipe, ["Dairy"]))

    def test_an_unknown_label_is_passed_through_lowercased(self):
        self.assertEqual(logic.normalise_allergens(["Lupin"]), ["lupin"])

    def test_results_are_sorted_and_deduplicated(self):
        self.assertEqual(
            logic.normalise_allergens(["Soy", "Dairy", "Soy"]),
            ["milk", "soy"])


class TestPrimaryDietType(unittest.TestCase):

    def test_no_preference_is_balanced(self):
        self.assertEqual(logic.primary_diet_type([]), "balanced")

    def test_the_most_restrictive_preference_wins(self):
        self.assertEqual(
            logic.primary_diet_type(["High protein", "Vegan"]), "vegan")
        self.assertEqual(
            logic.primary_diet_type(["Low carb", "Vegetarian"]), "vegetarian")

    def test_every_precedence_entry_is_a_real_token(self):
        tokens = set(logic.DIET_TOKENS.values())
        for candidate in logic.DIET_PRECEDENCE:
            self.assertIn(candidate, tokens)

    def test_every_token_appears_in_the_precedence_list(self):
        """Otherwise a preference could be chosen and never requested."""
        for token in logic.DIET_TOKENS.values():
            self.assertIn(token, logic.DIET_PRECEDENCE)


class TestBuildProfile(unittest.TestCase):

    def base(self, **overrides):
        args = dict(name="Wei Ling", age=23, height_cm=163.0, weight_kg=58.0,
                    activity_level="Lightly Active", goal="Lose Weight",
                    gender="Female", restrictions=["Dairy"],
                    preferences=["Pescatarian"])
        args.update(overrides)
        return logic.build_profile(**args)

    def test_raw_answers_are_kept_alongside_the_tokens(self):
        profile = self.base()
        self.assertEqual(profile["restrictions"], ["Dairy"])
        self.assertEqual(profile["allergens"], ["milk"])

    def test_the_target_is_calculated(self):
        profile = self.base()
        self.assertEqual(profile["target_kcal"],
                         profile["computed_target_kcal"])
        self.assertFalse(profile["target_is_manual"])

    def test_a_manual_target_overrides_the_calculation_without_losing_it(self):
        profile = self.base(manual_target_kcal=1600)
        self.assertEqual(profile["target_kcal"], 1600)
        self.assertTrue(profile["target_is_manual"])
        # The calculated figure survives, so the profile page can show both.
        self.assertNotEqual(profile["computed_target_kcal"], 1600)

    def test_the_diet_type_is_derived_from_the_preferences(self):
        self.assertEqual(self.base()["diet_type"], "pescatarian")


class TestDietDerivation(unittest.TestCase):

    def test_pork_rules_out_halal(self):
        self.assertNotIn("halal", recipes_api.derive_diet_types(
            ["Pork belly", "Soy sauce"]))

    def test_wine_rules_out_halal(self):
        self.assertNotIn("halal", recipes_api.derive_diet_types(
            ["Chicken thigh", "White wine"]))

    def test_wine_vinegar_does_not(self):
        """Vinegar made from wine no longer contains the alcohol."""
        self.assertIn("halal", recipes_api.derive_diet_types(
            ["Chicken thigh", "Red wine vinegar"]))

    def test_meat_rules_out_pescatarian_but_fish_does_not(self):
        self.assertNotIn("pescatarian", recipes_api.derive_diet_types(
            ["Beef mince", "Tomato"]))
        self.assertIn("pescatarian", recipes_api.derive_diet_types(
            ["Salmon fillet", "Broccoli"]))

    def test_a_beef_tomato_is_a_tomato(self):
        self.assertIn("pescatarian", recipes_api.derive_diet_types(
            ["Beef tomato", "Basil", "Mozzarella"]))

    def test_the_category_still_drives_vegan_and_vegetarian(self):
        tags = recipes_api.derive_diet_types(["Lentils", "Spinach"],
                                             category="Vegan")
        self.assertIn("vegan", tags)
        self.assertIn("vegetarian", tags)

    def test_high_protein_comes_from_the_estimate(self):
        self.assertIn("high-protein", recipes_api.derive_diet_types(
            ["Chicken breast"], protein_g=40))
        self.assertNotIn("high-protein", recipes_api.derive_diet_types(
            ["Chicken breast"], protein_g=10))


class TestSeedDataConsistency(unittest.TestCase):
    """The offline pool has to be tagged as carefully as the live one.

    recommend() falls back to "everything safe" when a diet filter matches
    nothing, which is graceful but silent: a preference that no offline recipe
    carries is simply ignored whenever the backend is unreachable.
    """

    def setUp(self):
        import database
        self.recipes = database.recipe_dicts(
            [dict(zip(("name", "kcal", "carbs_g", "protein_g", "fat_g",
                       "minutes", "allergens", "diet_types", "ingredients"), r),
                  id=i)
             for i, r in enumerate(database.RECIPES, start=1)])

    def test_stated_allergens_are_not_less_than_derived_ones(self):
        """A soy-sauce stir-fry has to declare gluten as well as soy."""
        import database
        for recipe, row in zip(self.recipes, database.RECIPES):
            names = [part.strip() for part in row[8].split("|") if part.strip()]
            derived = set(recipes_api.derive_allergens(names))
            missing = derived - set(recipe["allergens"])
            self.assertFalse(
                missing,
                f"{recipe['name']} omits {sorted(missing)}")

    def test_no_vegan_recipe_lists_an_animal_allergen(self):
        for recipe in self.recipes:
            if "vegan" in recipe["diet_types"]:
                clash = set(recipe["allergens"]) & {"egg", "milk", "fish",
                                                    "shellfish"}
                self.assertFalse(clash,
                                 f"{recipe['name']} is vegan but lists {clash}")

    def test_no_vegetarian_recipe_lists_fish_or_shellfish(self):
        for recipe in self.recipes:
            if "vegetarian" in recipe["diet_types"]:
                clash = set(recipe["allergens"]) & {"fish", "shellfish"}
                self.assertFalse(clash,
                                 f"{recipe['name']} is vegetarian but lists {clash}")

    def test_every_offered_preference_has_offline_recipes(self):
        for token in logic.DIET_TOKENS.values():
            matching = [r for r in self.recipes
                        if logic.matches_diet(r, token)]
            self.assertTrue(matching, f"no offline recipe is tagged {token}")

    def test_every_offered_preference_survives_a_common_allergy(self):
        """A vegan avoiding gluten must still be offered something."""
        for token in logic.DIET_TOKENS.values():
            picks = logic.recommend(self.recipes, ["gluten"], token, 600)
            self.assertTrue(picks, f"{token} plus a gluten allergy returns nothing")


class TestInsights(unittest.TestCase):

    def entry(self, day_offset, kcal, category="lunch"):
        when = datetime.now() - timedelta(days=day_offset)
        return {"kcal": kcal, "carbs_g": 10.0, "protein_g": 5.0, "fat_g": 2.0,
                "category": category, "eaten_at": when.isoformat(),
                "deleted": 0}

    def test_unlogged_days_are_present_with_zero_totals(self):
        """A gap in a chart and a day at zero must not look identical."""
        totals = logic.daily_totals([self.entry(0, 500)], days=7)
        self.assertEqual(len(totals), 7)
        self.assertEqual([t["entry_count"] for t in totals][:6], [0] * 6)
        self.assertEqual(totals[-1]["kcal"], 500)

    def test_entries_outside_the_window_are_ignored(self):
        totals = logic.daily_totals([self.entry(30, 900)], days=7)
        self.assertEqual(sum(t["kcal"] for t in totals), 0)

    def test_deleted_entries_are_ignored(self):
        entry = self.entry(0, 500)
        entry["deleted"] = 1
        totals = logic.daily_totals([entry], days=7)
        self.assertEqual(sum(t["kcal"] for t in totals), 0)

    def test_the_average_is_over_logged_days_not_the_whole_window(self):
        """The arithmetic choice that matters.

        Three logged days divided by seven reports roughly half of what the
        person ate, which would make every week look like a deficit.
        """
        entries = [self.entry(0, 2000), self.entry(1, 2000), self.entry(2, 2000)]
        trend = logic.summarise_trend(logic.daily_totals(entries, days=7), 2000)
        self.assertEqual(trend["days_logged"], 3)
        self.assertEqual(trend["average_kcal"], 2000)

    def test_an_empty_window_does_not_divide_by_zero(self):
        trend = logic.summarise_trend(logic.daily_totals([], days=7), 2000)
        self.assertEqual(trend["average_kcal"], 0)
        self.assertEqual(trend["adherence_percent"], 0)

    def test_a_day_within_tolerance_counts_as_on_target(self):
        entries = [self.entry(0, 2050)]       # 2.5% over a 2000 target
        trend = logic.summarise_trend(logic.daily_totals(entries, days=7), 2000)
        self.assertEqual(trend["days_on_target"], 1)
        self.assertEqual(trend["days_over"], 0)

    def test_a_day_outside_tolerance_counts_as_over(self):
        entries = [self.entry(0, 2600)]
        trend = logic.summarise_trend(logic.daily_totals(entries, days=7), 2000)
        self.assertEqual(trend["days_over"], 1)
        self.assertEqual(trend["days_on_target"], 0)

    def test_the_three_day_buckets_always_sum_to_the_logged_days(self):
        entries = [self.entry(0, 1200), self.entry(1, 2000), self.entry(2, 3000)]
        trend = logic.summarise_trend(logic.daily_totals(entries, days=7), 2000)
        self.assertEqual(
            trend["days_on_target"] + trend["days_over"] + trend["days_under"],
            trend["days_logged"])

    def test_a_streak_counts_back_from_the_last_logged_day(self):
        entries = [self.entry(0, 500), self.entry(1, 500), self.entry(2, 500)]
        totals = logic.daily_totals(entries, days=7)
        self.assertEqual(logic.logging_streak(totals), 3)

    def test_an_unlogged_today_does_not_break_the_streak(self):
        """Otherwise the streak collapses every morning before breakfast."""
        entries = [self.entry(1, 500), self.entry(2, 500)]
        totals = logic.daily_totals(entries, days=7)
        self.assertEqual(logic.logging_streak(totals), 2)

    def test_a_gap_does_break_the_streak(self):
        entries = [self.entry(0, 500), self.entry(2, 500), self.entry(3, 500)]
        totals = logic.daily_totals(entries, days=7)
        self.assertEqual(logic.logging_streak(totals), 1)

    def test_category_totals_sum_to_the_window_total(self):
        entries = [self.entry(0, 400, "breakfast"), self.entry(0, 600, "lunch"),
                   self.entry(1, 500, "dinner")]
        totals = logic.daily_totals(entries, days=7)
        self.assertEqual(sum(logic.category_totals(totals).values()), 1500)


class TestWeightTrend(unittest.TestCase):

    def weight(self, day_offset, kg):
        when = datetime.now() - timedelta(days=day_offset)
        return {"kg": kg, "recorded_at": when.isoformat(), "deleted": 0}

    def test_one_measurement_is_not_a_trend(self):
        self.assertIsNone(logic.weight_change([self.weight(0, 70)]))

    def test_change_is_measured_oldest_to_newest(self):
        log = [self.weight(0, 68.0), self.weight(10, 70.0)]
        self.assertEqual(logic.weight_change(log), -2.0)

    def test_deleted_measurements_are_ignored(self):
        stale = self.weight(10, 90.0)
        stale["deleted"] = 1
        log = [stale, self.weight(1, 70.0), self.weight(0, 69.0)]
        self.assertEqual(logic.weight_change(log), -1.0)

    def test_progress_is_a_share_of_the_distance_to_the_target(self):
        log = [self.weight(10, 70.0), self.weight(0, 68.0)]
        self.assertEqual(logic.progress_towards_target(log, 66.0), 50)

    def test_moving_the_wrong_way_reports_zero_rather_than_a_negative(self):
        log = [self.weight(10, 70.0), self.weight(0, 72.0)]
        self.assertEqual(logic.progress_towards_target(log, 66.0), 0)

    def test_overshooting_the_target_caps_at_a_hundred(self):
        log = [self.weight(10, 70.0), self.weight(0, 64.0)]
        self.assertEqual(logic.progress_towards_target(log, 66.0), 100)

    def test_no_target_means_no_progress_figure(self):
        log = [self.weight(10, 70.0), self.weight(0, 68.0)]
        self.assertIsNone(logic.progress_towards_target(log, None))

    def test_a_target_equal_to_the_start_is_not_a_percentage(self):
        log = [self.weight(10, 70.0), self.weight(0, 69.0)]
        self.assertIsNone(logic.progress_towards_target(log, 70.0))


class TestWeightAndProfilePushValidation(unittest.TestCase):

    def test_a_weight_needs_its_required_fields(self):
        self.assertFalse(sync.is_valid_weight({"id": "w1"}))

    def test_a_zero_or_negative_weight_is_refused(self):
        """SQLite would store it happily and poison every average from it."""
        for kg in (0, -5, 1):
            self.assertFalse(sync.is_valid_weight({
                "id": "w1", "kg": kg, "recorded_at": "2026-01-01",
                "updated_at": "2026-01-01T00:00:00+00:00"}))

    def test_an_implausible_weight_is_refused(self):
        self.assertFalse(sync.is_valid_weight({
            "id": "w1", "kg": 900, "recorded_at": "2026-01-01",
            "updated_at": "2026-01-01T00:00:00+00:00"}))

    def test_a_plausible_weight_is_accepted(self):
        self.assertTrue(sync.is_valid_weight({
            "id": "w1", "kg": 68.5, "recorded_at": "2026-01-01",
            "updated_at": "2026-01-01T00:00:00+00:00"}))

    def test_a_profile_needs_a_target(self):
        self.assertFalse(sync.is_valid_profile({
            "name": "A", "age": 30, "height_cm": 170, "weight_kg": 70,
            "updated_at": "2026-01-01T00:00:00+00:00"}))

    def test_a_profile_with_a_zero_target_is_refused(self):
        self.assertFalse(sync.is_valid_profile({
            "name": "A", "age": 30, "height_cm": 170, "weight_kg": 70,
            "target_kcal": 0, "updated_at": "2026-01-01T00:00:00+00:00"}))

    def test_cleaning_a_profile_drops_fields_a_client_may_not_set(self):
        cleaned = sync.clean_profile({
            "name": "A", "age": 30, "height_cm": 170, "weight_kg": 70,
            "target_kcal": 2000, "updated_at": "2026-01-01T00:00:00+00:00",
            "server_seq": 999, "dirty": 1, "id": "someone-else"})
        self.assertNotIn("server_seq", cleaned)
        self.assertNotIn("dirty", cleaned)
        self.assertNotIn("id", cleaned)

    def test_cleaning_a_weight_drops_the_client_only_flag(self):
        cleaned = sync.clean_weight({
            "id": "w1", "kg": 70, "recorded_at": "2026-01-01",
            "updated_at": "2026-01-01T00:00:00+00:00",
            "dirty": 1, "server_seq": 5})
        self.assertNotIn("dirty", cleaned)
        self.assertNotIn("server_seq", cleaned)


class TestMergedPaging(unittest.TestCase):
    """One cursor across three collections.

    Paging each table separately would advance the cursor past rows in another
    table that were never sent, and those rows would never be pulled again.
    """

    def rows(self, kind, seqs):
        return [(kind, {"server_seq": s}) for s in seqs]

    def test_rows_come_back_in_sequence_order_across_kinds(self):
        candidates = self.rows("changes", [1, 4]) + self.rows("weights", [2, 3])
        page, cursor, has_more = sync.page(candidates, page_size=10)
        self.assertEqual([row["server_seq"] for _, row in page], [1, 2, 3, 4])
        self.assertEqual(cursor, 4)
        self.assertFalse(has_more)

    def test_the_cursor_never_skips_a_row_in_another_table(self):
        candidates = self.rows("changes", [1, 2, 3]) + self.rows("weights", [4, 5])
        page, cursor, has_more = sync.page(candidates, page_size=2)
        self.assertEqual(cursor, 2)
        self.assertTrue(has_more)
        # Everything above the cursor is still waiting, whichever table it is in.
        self.assertEqual([row["server_seq"] for _, row in page], [1, 2])

    def test_an_empty_pull_reports_no_cursor(self):
        page, cursor, has_more = sync.page([], page_size=10)
        self.assertEqual(page, [])
        self.assertIsNone(cursor)
        self.assertFalse(has_more)


import accounts as accounts_module
import db as db_module


class TestPasswordHashing(unittest.TestCase):
    """What is stored must not be the password, and must not be reversible."""

    def test_the_password_is_not_in_the_stored_value(self):
        stored = accounts_module.hash_password("hunter2")
        self.assertNotIn("hunter2", stored)

    def test_a_password_verifies_against_its_own_hash(self):
        stored = accounts_module.hash_password("correct horse battery")
        self.assertTrue(
            accounts_module.verify_password("correct horse battery", stored))

    def test_a_wrong_password_does_not(self):
        stored = accounts_module.hash_password("correct horse battery")
        self.assertFalse(accounts_module.verify_password("wrong", stored))

    def test_the_same_password_hashes_differently_each_time(self):
        """Per-user salt. Without it, identical passwords share a digest and
        one cracked password reveals every account that reused it."""
        a = accounts_module.hash_password("same password")
        b = accounts_module.hash_password("same password")
        self.assertNotEqual(a, b)
        self.assertTrue(accounts_module.verify_password("same password", a))
        self.assertTrue(accounts_module.verify_password("same password", b))

    def test_the_cost_travels_with_the_digest(self):
        stored = accounts_module.hash_password("x", iterations=1000)
        self.assertTrue(stored.startswith("pbkdf2_sha256$1000$"))
        # Still verifies at the weaker cost it was created with...
        self.assertTrue(accounts_module.verify_password("x", stored))
        # ...and is flagged for rehashing at the current cost.
        self.assertTrue(accounts_module.needs_rehash(stored))
        self.assertFalse(
            accounts_module.needs_rehash(accounts_module.hash_password("x")))

    def test_a_corrupt_verifier_denies_access_rather_than_raising(self):
        for junk in ("", None, "garbage", "pbkdf2_sha256$notanumber$aa$bb",
                     "pbkdf2_sha256$1000$zz$yy", "md5$1$aa$bb"):
            self.assertFalse(accounts_module.verify_password("x", junk),
                             f"{junk!r} should not verify")

    def test_an_empty_password_never_verifies(self):
        stored = accounts_module.hash_password("something")
        self.assertFalse(accounts_module.verify_password("", stored))

    def test_registration_validation(self):
        self.assertEqual(
            accounts_module.validate_registration(
                "a@b.co", "a password long enough", "Name"), [])
        problems = accounts_module.validate_registration("nope", "short", "")
        self.assertEqual(len(problems), 3)

    def test_emails_are_compared_case_insensitively(self):
        self.assertEqual(accounts_module.normalise_email("  Wei.Ling@Example.COM "),
                         "wei.ling@example.com")


class TestPlaceholderTranslation(unittest.TestCase):
    """SQLite writes `?`, Postgres writes `%s`.

    Every query in this project is written with `?` and rewritten on the way
    out, so one body of SQL serves both engines.
    """

    def test_placeholders_become_percent_s(self):
        self.assertEqual(db_module.translate("SELECT * FROM t WHERE a=? AND b=?"),
                         "SELECT * FROM t WHERE a=%s AND b=%s")

    def test_a_question_mark_in_a_string_is_left_alone(self):
        self.assertEqual(db_module.translate("SELECT 'what? really', ?"),
                         "SELECT 'what? really', %s")

    def test_a_question_mark_in_a_quoted_identifier_is_left_alone(self):
        self.assertEqual(db_module.translate('SELECT "a?b" FROM t WHERE x=?'),
                         'SELECT "a?b" FROM t WHERE x=%s')

    def test_a_literal_percent_is_escaped(self):
        """psycopg binds client-side, so a bare % reads as a format directive."""
        self.assertEqual(db_module.translate("SELECT 50 % 7"), "SELECT 50 %% 7")

    def test_a_percent_inside_a_string_is_not_escaped(self):
        self.assertEqual(db_module.translate("SELECT * FROM t WHERE n LIKE 'a%'"),
                         "SELECT * FROM t WHERE n LIKE 'a%'")

    def test_comments_are_stripped_for_statement_splitting(self):
        self.assertEqual(
            db_module.strip_comments("CREATE TABLE t (a INT); -- note").strip(),
            "CREATE TABLE t (a INT);")


class TestApiNeverRedirectsToHtml(unittest.TestCase):
    """An API request must not be answered with a page.

    Found by running the real server rather than the test client: a signed-in
    user with no profile asked /api/foods and got a 302 to the setup page.
    The profile gate is for browsers -- it sends someone to create the target
    that the measuring pages measure against -- but an HTML redirect in answer
    to a JSON request is just a parse error at the other end. The app asks
    /api/me whether setup is done and decides for itself.
    """

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.client = app.app.test_client()
        token = self.client.post("/api/register", json={
            "email": "no-profile@example.com",
            "password": "a sufficiently long password",
            "name": "No Profile"}).get_json()["token"]
        self.auth = {"Authorization": f"Bearer {token}"}

    def test_api_me_works_without_a_profile(self):
        response = self.client.get("/api/me", headers=self.auth)
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.get_json()["has_profile"])

    def test_api_endpoints_answer_with_json_and_not_a_redirect(self):
        for path in ("/api/me", "/api/foods?q=rice", "/api/recipes"):
            response = self.client.get(path, headers=self.auth)
            self.assertNotEqual(
                response.status_code, 302,
                f"{path} redirected instead of answering")
            self.assertEqual(
                response.mimetype, "application/json",
                f"{path} answered with {response.mimetype}")

    def test_sync_works_without_a_profile(self):
        response = self.client.post("/sync", headers=self.auth,
                                    json={"since": 0})
        self.assertEqual(response.status_code, 200)

    def test_a_page_still_redirects_to_setup(self):
        """The gate itself must stay in place for the browser."""
        browser = self.client
        browser.post("/register", data={
            "email": "browser-gate@example.com",
            "password": "another long password", "name": "Gate"})
        response = browser.get("/")
        self.assertEqual(response.status_code, 302)
        self.assertIn("/profile/setup", response.headers["Location"])


class TestCustomFoods(unittest.TestCase):
    """Foods a user entered themselves, as a fourth synced collection.

    The risks are the ones every collection here has: another account's row
    must be untouchable, a deletion must not come back on the next pull, and
    a stale copy from a second device must not overwrite a newer one.
    """

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.client = app.app.test_client()
        self.database = database

    def register(self, email):
        body = self.client.post("/api/register", json={
            "email": email, "password": "testpass123", "name": "P"}).get_json()
        return {"Authorization": f"Bearer {body['token']}"}

    def food(self, **over):
        row = {"id": "cf-1", "name": "Ah Ma laksa", "serving": "1 bowl",
               "kcal": 640, "carbs_g": 58.2, "protein_g": 22.1, "fat_g": 31.4,
               "deleted": 0, "updated_at": "2026-11-13T02:00:00Z"}
        row.update(over)
        return row

    def sync(self, headers, foods=None, since=0):
        return self.client.post("/sync", headers=headers, json={
            "since": since, "changes": [], "weights": [],
            "custom_foods": foods or [], "profile": None}).get_json()

    # ------------------------------------------------------- round trip

    def test_a_custom_food_survives_a_round_trip(self):
        headers = self.register("a@test.com")
        self.assertEqual(self.sync(headers, [self.food()])["push"]["applied"], 1)
        back = self.sync(headers)["custom_foods"]
        self.assertEqual(len(back), 1)
        self.assertEqual(back[0]["name"], "Ah Ma laksa")
        self.assertEqual(back[0]["kcal"], 640)
        self.assertAlmostEqual(back[0]["carbs_g"], 58.2)

    def test_the_name_is_trimmed_and_a_blank_one_refused(self):
        headers = self.register("a@test.com")
        self.sync(headers, [self.food(name="  Spaced  ")])
        self.assertEqual(self.sync(headers)["custom_foods"][0]["name"], "Spaced")

        result = self.sync(headers, [self.food(id="cf-2", name="   ")])
        self.assertEqual(result["push"]["invalid"], 1)

    def test_missing_calories_are_refused(self):
        headers = self.register("a@test.com")
        row = self.food()
        del row["kcal"]
        self.assertEqual(self.sync(headers, [row])["push"]["invalid"], 1)

    def test_macros_default_to_zero_rather_than_failing(self):
        headers = self.register("a@test.com")
        row = self.food()
        for macro in ("carbs_g", "protein_g", "fat_g"):
            del row[macro]
        self.assertEqual(self.sync(headers, [row])["push"]["applied"], 1)
        back = self.sync(headers)["custom_foods"][0]
        self.assertEqual(back["carbs_g"], 0)

    def test_a_serving_defaults_when_left_out(self):
        headers = self.register("a@test.com")
        row = self.food()
        del row["serving"]
        self.sync(headers, [row])
        self.assertEqual(self.sync(headers)["custom_foods"][0]["serving"],
                         "1 serving")

    # ---------------------------------------------------------- deletion

    def test_a_deletion_travels_and_does_not_come_back_undeleted(self):
        headers = self.register("a@test.com")
        self.sync(headers, [self.food()])
        self.sync(headers, [self.food(deleted=1,
                                      updated_at="2026-11-13T03:00:00Z")])
        back = self.sync(headers)["custom_foods"]
        self.assertEqual(len(back), 1)
        self.assertEqual(back[0]["deleted"], 1)

    def test_deleting_a_food_leaves_diary_entries_alone(self):
        """An entry keeps its own figures, so past meals stay correct."""
        headers = self.register("a@test.com")
        self.sync(headers, [self.food()])
        self.client.post("/sync", headers=headers, json={
            "since": 0, "weights": [], "custom_foods": [], "profile": None,
            "changes": [{
                "id": "e-1", "food_id": "cf-1", "food_name": "Ah Ma laksa",
                "quantity": 1.0, "serving": "1 bowl", "kcal": 640,
                "carbs_g": 58.2, "protein_g": 22.1, "fat_g": 31.4,
                "category": "dinner", "tags": "", "note": "",
                "eaten_at": "2026-11-13T02:30:00", "source": "custom",
                "deleted": 0, "updated_at": "2026-11-13T02:31:00Z"}]})
        self.sync(headers, [self.food(deleted=1,
                                      updated_at="2026-11-13T03:00:00Z")])

        entries = self.client.post("/sync", headers=headers, json={
            "since": 0, "changes": [], "weights": [], "custom_foods": [],
            "profile": None}).get_json()["changes"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["kcal"], 640)
        self.assertEqual(entries[0]["deleted"], 0)

    # ------------------------------------------------------- separation

    def test_another_account_never_sees_it(self):
        mine = self.register("mine@test.com")
        theirs = self.register("theirs@test.com")
        self.sync(mine, [self.food()])
        self.assertEqual(self.sync(theirs)["custom_foods"], [])

    def test_a_shared_id_does_not_overwrite_the_other_account(self):
        """Ids are generated on the device, so a collision is possible."""
        mine = self.register("mine@test.com")
        theirs = self.register("theirs@test.com")
        self.sync(mine, [self.food(name="Mine")])
        self.sync(theirs, [self.food(name="Theirs",
                                     updated_at="2026-11-13T04:00:00Z")])
        self.assertEqual(self.sync(mine)["custom_foods"][0]["name"], "Mine")
        self.assertEqual(self.sync(theirs)["custom_foods"][0]["name"], "Theirs")

    def test_an_older_copy_does_not_overwrite_a_newer_one(self):
        headers = self.register("a@test.com")
        self.sync(headers, [self.food(name="Newer",
                                      updated_at="2026-11-13T04:00:00Z")])
        result = self.sync(headers, [self.food(name="Older",
                                               updated_at="2026-11-13T01:00:00Z")])
        self.assertEqual(result["push"]["skipped"], 1)
        self.assertEqual(self.sync(headers)["custom_foods"][0]["name"], "Newer")

    def test_it_shares_the_cursor_with_the_other_collections(self):
        """One sequence across all four, or paging loses rows."""
        headers = self.register("a@test.com")
        first = self.sync(headers, [self.food()])
        cursor = first["cursor"]
        self.assertEqual(self.sync(headers, since=cursor)["custom_foods"], [])

    def test_a_push_without_the_key_still_works(self):
        """An older build of the app sends no custom_foods field."""
        headers = self.register("a@test.com")
        response = self.client.post("/sync", headers=headers, json={
            "since": 0, "changes": [], "weights": [], "profile": None})
        self.assertEqual(response.status_code, 200)


class TestDeleteAccount(unittest.TestCase):
    """Deleting an account is the one action with no undo.

    So the tests are mostly about what must NOT happen: no deletion without
    the password, none with the wrong one, none without a token, and nothing
    of anyone else's touched when it does go ahead.
    """

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.client = app.app.test_client()
        self.database = database

    def register(self, email, password="testpass123", name="Person"):
        body = self.client.post("/api/register", json={
            "email": email, "password": password, "name": name}).get_json()
        return body["token"], {"Authorization": f"Bearer {body['token']}"}

    def log_a_meal(self, headers, entry_id):
        self.client.post("/sync", headers=headers, json={
            "since": 0, "weights": [], "profile": None, "changes": [{
                "id": entry_id, "food_id": "F05100112",
                "food_name": "Chicken rice", "quantity": 1.0,
                "serving": "1 plate", "kcal": 643, "carbs_g": 84.1,
                "protein_g": 29.7, "fat_g": 20.9, "category": "lunch",
                "tags": "", "note": "", "eaten_at": "2026-11-11T12:30:00",
                "source": "manual", "deleted": 0,
                "updated_at": "2026-11-11T12:31:00Z"}]})

    def count(self, table, user_id=None):
        conn = self.database.connect()
        try:
            if user_id is None:
                sql, args = f"SELECT COUNT(*) c FROM {table}", ()
            else:
                sql = f"SELECT COUNT(*) c FROM {table} WHERE user_id=?"
                args = (user_id,)
            return conn.execute(sql, args).fetchone()["c"]
        finally:
            conn.close()

    def user_id_of(self, headers):
        return self.client.get("/api/me", headers=headers).get_json()["user"]["id"]

    # ---------------------------------------------------------- refusals

    def test_no_token_is_refused(self):
        self.register("a@test.com")
        response = self.client.post("/api/account/delete",
                                    json={"password": "testpass123"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.count("users"), 1)

    def test_missing_password_is_refused(self):
        _, headers = self.register("a@test.com")
        response = self.client.post("/api/account/delete", json={},
                                    headers=headers)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.count("users"), 1)

    def test_wrong_password_is_refused(self):
        _, headers = self.register("a@test.com")
        response = self.client.post("/api/account/delete",
                                    json={"password": "wrongpass123"},
                                    headers=headers)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.count("users"), 1)

    def test_a_refusal_leaves_the_session_working(self):
        """A mistyped password must not half-delete anything."""
        _, headers = self.register("a@test.com")
        self.log_a_meal(headers, "aaaa1111-0000-4000-8000-000000000001")
        self.client.post("/api/account/delete",
                         json={"password": "wrongpass123"}, headers=headers)
        self.assertEqual(self.client.get("/api/me", headers=headers).status_code,
                         200)
        self.assertEqual(self.count("entries"), 1)

    # ------------------------------------------------------------ success

    def test_the_account_and_its_rows_are_gone(self):
        _, headers = self.register("a@test.com")
        self.log_a_meal(headers, "aaaa1111-0000-4000-8000-000000000001")
        self.assertEqual(self.count("users"), 1)

        response = self.client.post("/api/account/delete",
                                    json={"password": "testpass123"},
                                    headers=headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.count("users"), 0)
        self.assertEqual(self.count("entries"), 0)
        self.assertEqual(self.count("sessions"), 0)

    def test_every_device_is_signed_out(self):
        """Sessions go with the account, so a second phone cannot carry on."""
        _, phone = self.register("a@test.com")
        tablet = self.client.post("/api/login", json={
            "email": "a@test.com", "password": "testpass123"}).get_json()
        tablet_headers = {"Authorization": f"Bearer {tablet['token']}"}
        self.assertEqual(
            self.client.get("/api/me", headers=tablet_headers).status_code, 200)

        self.client.post("/api/account/delete",
                         json={"password": "testpass123"}, headers=phone)

        self.assertEqual(
            self.client.get("/api/me", headers=phone).status_code, 401)
        self.assertEqual(
            self.client.get("/api/me", headers=tablet_headers).status_code, 401)

    def test_the_email_can_be_used_again(self):
        _, headers = self.register("a@test.com")
        self.client.post("/api/account/delete",
                         json={"password": "testpass123"}, headers=headers)
        again = self.client.post("/api/register", json={
            "email": "a@test.com", "password": "different123", "name": "New"})
        self.assertEqual(again.status_code, 201)

    # -------------------------------------------------- nobody else's data

    def test_another_account_is_untouched(self):
        """The whole point of the per-user scoping, at its most destructive."""
        _, mine = self.register("mine@test.com")
        _, theirs = self.register("theirs@test.com")
        self.log_a_meal(mine, "aaaa1111-0000-4000-8000-000000000001")
        self.log_a_meal(theirs, "bbbb2222-0000-4000-8000-000000000002")
        their_id = self.user_id_of(theirs)

        self.client.post("/api/account/delete",
                         json={"password": "testpass123"}, headers=mine)

        self.assertEqual(self.count("users"), 1)
        self.assertEqual(self.count("entries", their_id), 1)
        self.assertEqual(
            self.client.get("/api/me", headers=theirs).status_code, 200)

    def test_a_shared_entry_id_does_not_take_the_other_copy(self):
        """Two accounts can legitimately hold the same entry id.

        Ids are generated on the device, so a collision is possible, and the
        composite key (user_id, id) is what keeps the rows apart. A delete
        scoped only by id would take both.
        """
        shared = "cccc3333-0000-4000-8000-000000000003"
        _, mine = self.register("mine@test.com")
        _, theirs = self.register("theirs@test.com")
        self.log_a_meal(mine, shared)
        self.log_a_meal(theirs, shared)
        their_id = self.user_id_of(theirs)

        self.client.post("/api/account/delete",
                         json={"password": "testpass123"}, headers=mine)

        self.assertEqual(self.count("entries", their_id), 1)

    def test_it_works_without_a_profile(self):
        """Someone who abandoned setup must still be able to delete."""
        _, headers = self.register("a@test.com")
        response = self.client.post("/api/account/delete",
                                    json={"password": "testpass123"},
                                    headers=headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.count("users"), 0)


class TestHealthCheckCostsNothing(unittest.TestCase):
    """The keep-warm ping must not open a database connection.

    A free host sleeps after fifteen idle minutes, so something has to poll it
    to keep a demo reachable. Neon's free plan bills compute by the hour and
    suspends after five idle minutes, with no way to switch that off, so a
    poll that touched the database would keep the compute awake around the
    clock: roughly 180 CU-hours a month against an allowance of 100. The
    database would suspend itself two thirds of the way through the month.

    The test proves it the only way that cannot drift -- by making a
    connection impossible and checking the route still answers.
    """

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.client = app.app.test_client()

    def test_ping_answers_with_the_database_unreachable(self):
        import database

        def refuse():
            raise AssertionError(
                "/api/ping opened a database connection. See "
                "DB_FREE_ENDPOINTS in app.py -- this costs real money on a "
                "metered plan and will suspend the database mid-month.")

        original = database.connect
        database.connect = refuse
        try:
            response = self.client.get("/api/ping")
        finally:
            database.connect = original

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["ok"])

    def test_ping_needs_no_token(self):
        self.assertEqual(self.client.get("/api/ping").status_code, 200)

    def test_health_does_check_the_database(self):
        """The other half: /api/health is the one that costs something."""
        response = self.client.get("/api/health")
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertIn(body["database"], ("sqlite", "postgres"))
        self.assertIsInstance(body["foods"], int)

    def test_health_is_reachable_without_an_account(self):
        """It is for checking a deployment before anyone has signed up."""
        response = self.client.get("/api/health")
        self.assertNotEqual(response.status_code, 401)

    def test_health_reports_nothing_about_any_user(self):
        """It is public, so it must not describe the people using it."""
        body = self.client.get("/api/health").get_json()
        for leak in ("accounts", "users", "emails", "user_count"):
            self.assertNotIn(leak, body)


class TestEnvFileLoading(unittest.TestCase):
    """`neon env pull` writes .env.local; the backend has to read it.

    It writes two URLs, and they are not interchangeable: the pooled one for
    the application, the direct one for schema changes.
    """

    def test_values_are_parsed_from_an_env_file(self):
        import tempfile
        body = ("# comment\n"
                'DATABASE_URL="postgresql://pooled"\n'
                "export DATABASE_URL_UNPOOLED=postgresql://direct\n"
                "EMPTY=\n"
                "NOT_AN_ASSIGNMENT\n")
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, ".env.local")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(body)
            values = db_module._parse_env_file(path)
        self.assertEqual(values["DATABASE_URL"], "postgresql://pooled")
        self.assertEqual(values["DATABASE_URL_UNPOOLED"], "postgresql://direct")
        self.assertEqual(values["EMPTY"], "")
        self.assertNotIn("NOT_AN_ASSIGNMENT", values)

    def test_a_missing_file_is_not_an_error(self):
        self.assertEqual(db_module._parse_env_file("/nonexistent/.env"), {})

    def _with_env(self, **values):
        """Set environment variables, returning what they were."""
        saved = {k: os.environ.get(k) for k in values}
        for key, value in values.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        return saved

    def _restore(self, saved):
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_migrations_prefer_the_unpooled_url(self):
        saved = self._with_env(DATABASE_URL="postgresql://host-pooler/db",
                               DATABASE_URL_UNPOOLED="postgresql://host/db")
        try:
            self.assertEqual(db_module.database_url(),
                             "postgresql://host-pooler/db")
            self.assertEqual(db_module.migration_url(), "postgresql://host/db")
        finally:
            self._restore(saved)

    def test_migrations_fall_back_to_the_only_url_available(self):
        saved = self._with_env(DATABASE_URL="postgresql://only/db",
                               DATABASE_URL_UNPOOLED=None)
        try:
            self.assertEqual(db_module.migration_url(), "postgresql://only/db")
        finally:
            self._restore(saved)

    def test_a_pooled_url_is_recognised(self):
        self.assertTrue(db_module.looks_pooled(
            "postgresql://u@ep-x-pooler.aws.neon.tech/db"))
        self.assertFalse(db_module.looks_pooled(
            "postgresql://u@ep-x.aws.neon.tech/db"))
        self.assertFalse(db_module.looks_pooled(None))


class TestUrlSelectionIsSymmetric(unittest.TestCase):
    """Either connection string alone must be enough.

    The bug this pins: is_postgres() read DATABASE_URL only, while the
    migration path connected over DATABASE_URL_UNPOOLED. Configure just the
    unpooled one -- which anyone pasting by hand may well do -- and schema
    creation opened a Postgres connection while render_schema still emitted
    SQLite types, so Postgres rejected `AUTOINCREMENT`.
    """

    URL = "postgresql://u:p@host/db"
    POOLED = "postgresql://u:p@host-pooler/db"

    def setUp(self):
        self.saved = {k: os.environ.get(k)
                      for k in ("DATABASE_URL", "DATABASE_URL_UNPOOLED")}

    def tearDown(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def configure(self, pooled=None, unpooled=None):
        for key, value in (("DATABASE_URL", pooled),
                           ("DATABASE_URL_UNPOOLED", unpooled)):
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_both_set(self):
        self.configure(pooled=self.POOLED, unpooled=self.URL)
        self.assertTrue(db_module.is_postgres())
        self.assertEqual(db_module.database_url(), self.POOLED)
        self.assertEqual(db_module.migration_url(), self.URL)

    def test_only_pooled_set(self):
        self.configure(pooled=self.POOLED)
        self.assertTrue(db_module.is_postgres())
        self.assertEqual(db_module.database_url(), self.POOLED)
        self.assertEqual(db_module.migration_url(), self.POOLED)

    def test_only_unpooled_set(self):
        """The configuration that produced the AUTOINCREMENT error."""
        self.configure(unpooled=self.URL)
        self.assertTrue(db_module.is_postgres())
        self.assertEqual(db_module.database_url(), self.URL)
        self.assertEqual(db_module.migration_url(), self.URL)

    def test_neither_set_means_sqlite(self):
        self.configure()
        self.assertFalse(db_module.is_postgres())
        self.assertIsNone(db_module.database_url())
        self.assertIsNone(db_module.migration_url())

    def test_a_blank_value_counts_as_unset(self):
        self.configure(pooled="   ", unpooled=None)
        self.assertFalse(db_module.is_postgres())

    def test_the_schema_dialect_matches_the_connection(self):
        """The invariant that was violated.

        Whenever a Postgres URL is configured by any route, the rendered
        schema must be the Postgres one -- never SQLite's AUTOINCREMENT.
        """
        import database as database_module
        for pooled, unpooled in ((self.POOLED, self.URL),
                                 (self.POOLED, None),
                                 (None, self.URL)):
            self.configure(pooled=pooled, unpooled=unpooled)
            rendered = db_module.render_schema(database_module.SCHEMA)
            self.assertNotIn(
                "AUTOINCREMENT", rendered,
                f"SQLite syntax rendered for Postgres "
                f"(pooled={pooled!r}, unpooled={unpooled!r})")
            self.assertIn("GENERATED BY DEFAULT AS IDENTITY", rendered)

        self.configure()
        rendered = db_module.render_schema(database_module.SCHEMA)
        self.assertIn("AUTOINCREMENT", rendered)


if __name__ == "__main__":
    unittest.main(verbosity=2)


# ---------------------------------------------------------------------------
# The admin panel.
#
# The panel can read every account and block any of them, so the tests that
# matter most are the ones about who is refused. A rendering bug shows itself
# the first time somebody clicks; a gate that is open shows itself much later,
# or not at all.
# ---------------------------------------------------------------------------


class TestAdminAccessGate(unittest.TestCase):
    """Who can open /admin, and what everyone else sees instead."""

    # Every page in the blueprint. Listed rather than discovered, so a route
    # added without a thought about access makes this list wrong on purpose.
    PAGES = [
        "/admin/", "/admin/users", "/admin/preferences",
        "/admin/section/dietary-goals", "/admin/section/food-database",
        "/admin/section/categories-and-tags",
        "/admin/section/rules-and-metrics", "/admin/section/reports",
        "/admin/section/security-log", "/admin/section/roles-and-access",
        "/admin/section/recipe-api",
    ]

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.app = app.app
        self.database = database
        self.client = app.app.test_client()

    def register(self, email, password="testpass123", name="Person"):
        body = self.client.post("/api/register", json={
            "email": email, "password": password, "name": name}).get_json()
        return body["user"]["id"]

    def make_admin(self, user_id, value=True):
        conn = self.database.connect()
        try:
            self.database.admin_set_admin(conn, user_id, value)
        finally:
            conn.close()

    def sign_in(self, client, email, password="testpass123"):
        return client.post("/login",
                           data={"email": email, "password": password})

    def test_every_route_is_listed_in_this_test(self):
        """The gate is tested by path, so an untested path is a hole.

        Flask knows every route it registered; this compares that against the
        list above, so a page added to the blueprint without being added here
        fails rather than quietly going untested.
        """
        registered = {
            str(rule) for rule in self.app.url_map.iter_rules()
            if rule.endpoint.startswith("admin.")
            and "GET" in (rule.methods or set())
            and "<" not in str(rule)        # detail pages take an id
        }
        self.assertEqual(registered, set(self.PAGES))

    def test_anonymous_is_sent_to_sign_in(self):
        for path in self.PAGES:
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 302)
                self.assertTrue(
                    response.headers["Location"].startswith("/login"))

    def test_an_ordinary_account_gets_404_not_403(self):
        """404, so the panel's existence is not confirmed to non-staff.

        403 would say "this exists and you are not on the list", which is a
        fact worth not handing out. To an ordinary account the panel is
        absent, not forbidden.
        """
        self.register("plain@test.com")
        with self.app.test_client() as client:
            self.sign_in(client, "plain@test.com")
            for path in self.PAGES:
                with self.subTest(path=path):
                    self.assertEqual(client.get(path).status_code, 404)

    def test_an_administrator_reaches_every_page(self):
        admin_id = self.register("boss@test.com")
        self.make_admin(admin_id)
        with self.app.test_client() as client:
            self.sign_in(client, "boss@test.com")
            for path in self.PAGES:
                with self.subTest(path=path):
                    self.assertEqual(client.get(path).status_code, 200)

    def test_an_administrator_needs_no_profile(self):
        """A staff account that never used the app as a diary still gets in.

        The app sends anyone without a profile to the setup screen, because
        its other pages measure against a target. The panel measures nothing,
        so it is exempt -- without this, an administrator would have to invent
        a weight goal before they could look at the user list.
        """
        admin_id = self.register("boss@test.com")
        self.make_admin(admin_id)
        with self.app.test_client() as client:
            self.sign_in(client, "boss@test.com")
            response = client.get("/admin/", follow_redirects=False)
            self.assertEqual(response.status_code, 200)

    def test_revoking_admin_closes_the_panel_on_the_next_request(self):
        """Not at the next sign-in: on the next click."""
        admin_id = self.register("boss@test.com")
        self.make_admin(admin_id)
        with self.app.test_client() as client:
            self.sign_in(client, "boss@test.com")
            self.assertEqual(client.get("/admin/").status_code, 200)
            self.make_admin(admin_id, False)
            self.assertEqual(client.get("/admin/").status_code, 404)

    def test_an_ordinary_account_cannot_post_an_action(self):
        """The gate covers POST, not only the pages it is visible on."""
        victim = self.register("boss@test.com")
        self.make_admin(victim)
        self.register("plain@test.com")

        with self.app.test_client() as client:
            self.sign_in(client, "plain@test.com")
            response = client.post("/admin/users/action", data={
                "action": "disable", "user_id": victim})
            self.assertEqual(response.status_code, 404)

        conn = self.database.connect()
        try:
            row = conn.execute("SELECT disabled, is_admin FROM users"
                               " WHERE id=?", (victim,)).fetchone()
        finally:
            conn.close()
        self.assertEqual(row["disabled"], 0)
        self.assertEqual(row["is_admin"], 1)

    def test_an_anonymous_post_cannot_promote_anyone(self):
        plain = self.register("plain@test.com")
        response = self.client.post("/admin/users/action", data={
            "action": "promote", "user_id": plain})
        self.assertEqual(response.status_code, 302)

        conn = self.database.connect()
        try:
            row = conn.execute("SELECT is_admin FROM users WHERE id=?",
                               (plain,)).fetchone()
        finally:
            conn.close()
        self.assertEqual(row["is_admin"], 0)


class TestBlockingAnAccount(unittest.TestCase):
    """Blocking has to stop sign-in, not just change a pill in the panel."""

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.app = app.app
        self.database = database
        self.client = app.app.test_client()

    def register(self, email, password="testpass123", name="Person"):
        body = self.client.post("/api/register", json={
            "email": email, "password": password, "name": name}).get_json()
        return body["user"]["id"], body["token"]

    def block(self, user_id, value=True):
        conn = self.database.connect()
        try:
            self.database.admin_set_disabled(conn, user_id, value)
        finally:
            conn.close()

    def test_a_blocked_account_cannot_sign_in_through_the_api(self):
        user_id, _ = self.register("blocked@test.com")
        self.block(user_id)
        response = self.client.post("/api/login", json={
            "email": "blocked@test.com", "password": "testpass123"})
        self.assertEqual(response.status_code, 403)
        self.assertIsNone(response.get_json().get("token"))

    def test_the_refusal_says_blocked_rather_than_wrong_password(self):
        """Vagueness protects nobody once the password has been accepted.

        The generic "email or password is incorrect" exists so an attacker
        cannot learn which addresses are registered. That reason is spent by
        the time the password has been verified, and telling a blocked person
        their password is wrong sends them into a reset loop that cannot
        possibly help.
        """
        user_id, _ = self.register("blocked@test.com")
        self.block(user_id)
        body = self.client.post("/api/login", json={
            "email": "blocked@test.com", "password": "testpass123"}).get_json()
        self.assertIn("blocked", body["error"].lower())

    def test_a_wrong_password_on_a_blocked_account_stays_vague(self):
        """Blocking must not turn the login into an account-existence oracle."""
        user_id, _ = self.register("blocked@test.com")
        self.block(user_id)
        response = self.client.post("/api/login", json={
            "email": "blocked@test.com", "password": "wrongpassword"})
        self.assertEqual(response.status_code, 401)
        self.assertNotIn("blocked", response.get_json()["error"].lower())

    def test_blocking_signs_out_every_device(self):
        """The half that makes a block take effect at all.

        Without it the account keeps working on every device already signed
        in, for up to thirty days, while the panel shows it as blocked.
        """
        user_id, token = self.register("blocked@test.com")
        headers = {"Authorization": f"Bearer {token}"}
        self.assertEqual(self.client.get("/api/me", headers=headers)
                         .status_code, 200)

        self.block(user_id)
        self.assertEqual(self.client.get("/api/me", headers=headers)
                         .status_code, 401)

    def test_an_existing_token_is_refused_even_if_its_session_survives(self):
        """Belt and braces: the token path checks the flag itself.

        admin_set_disabled deletes the sessions, so normally there is no token
        left to present. This sets the flag directly, leaving the session in
        place, to prove the check in user_for_token is load-bearing on its own
        -- it is the backstop for any future path that disables an account
        without going through admin_set_disabled.
        """
        user_id, token = self.register("blocked@test.com")
        headers = {"Authorization": f"Bearer {token}"}

        conn = self.database.connect()
        try:
            conn.execute("UPDATE users SET disabled = 1 WHERE id = ?",
                         (user_id,))
            conn.commit()
            still_there = conn.execute(
                "SELECT COUNT(*) c FROM sessions WHERE user_id=?",
                (user_id,)).fetchone()["c"]
        finally:
            conn.close()
        self.assertEqual(still_there, 1)        # the session was not deleted

        self.assertEqual(self.client.get("/api/me", headers=headers)
                         .status_code, 401)

    def test_blocking_actually_deletes_the_session_rows(self):
        """Asserted directly, because 401 alone does not prove it.

        Blocking is defended twice over: the session rows are deleted, and
        user_for_token refuses a blocked account even if a token survives.
        Either one on its own makes /api/me return 401 -- so a test that only
        checks the status code passes with one of them removed, and the first
        version of this class had exactly that hole.

        This one looks at the sessions table. Its pair,
        test_an_existing_token_is_refused_even_if_its_session_survives, sets
        the flag without deleting anything and checks the other half. Between
        them, removing either defence fails a test.
        """
        user_id, _ = self.register("blocked@test.com")

        conn = self.database.connect()
        try:
            before = conn.execute(
                "SELECT COUNT(*) c FROM sessions WHERE user_id=?",
                (user_id,)).fetchone()["c"]
        finally:
            conn.close()
        self.assertEqual(before, 1)

        self.block(user_id)

        conn = self.database.connect()
        try:
            after = conn.execute(
                "SELECT COUNT(*) c FROM sessions WHERE user_id=?",
                (user_id,)).fetchone()["c"]
        finally:
            conn.close()
        self.assertEqual(after, 0)

    def test_blocking_does_not_delete_anybody_elses_sessions(self):
        blocked, _ = self.register("blocked@test.com")
        other, _ = self.register("fine@test.com")
        self.block(blocked)

        conn = self.database.connect()
        try:
            left = conn.execute(
                "SELECT COUNT(*) c FROM sessions WHERE user_id=?",
                (other,)).fetchone()["c"]
        finally:
            conn.close()
        self.assertEqual(left, 1)

    def test_unblocking_restores_sign_in(self):
        user_id, _ = self.register("blocked@test.com")
        self.block(user_id)
        self.block(user_id, False)
        response = self.client.post("/api/login", json={
            "email": "blocked@test.com", "password": "testpass123"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["token"])

    def test_blocking_one_account_leaves_the_others_alone(self):
        blocked, _ = self.register("blocked@test.com")
        _, other_token = self.register("fine@test.com")
        self.block(blocked)
        response = self.client.get(
            "/api/me", headers={"Authorization": f"Bearer {other_token}"})
        self.assertEqual(response.status_code, 200)


class TestAdminCannotLockEveryoneOut(unittest.TestCase):
    """The two clicks that would close the panel permanently."""

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.app = app.app
        self.database = database
        self.client = app.app.test_client()

    def register(self, email, password="testpass123", name="Person"):
        body = self.client.post("/api/register", json={
            "email": email, "password": password, "name": name}).get_json()
        return body["user"]["id"]

    def make_admin(self, user_id):
        conn = self.database.connect()
        try:
            self.database.admin_set_admin(conn, user_id, True)
        finally:
            conn.close()

    def flag(self, user_id, column):
        conn = self.database.connect()
        try:
            return conn.execute(f"SELECT {column} FROM users WHERE id=?",
                                (user_id,)).fetchone()[column]
        finally:
            conn.close()

    def test_the_last_administrator_cannot_be_demoted(self):
        """Demoting them leaves a panel nobody can open.

        The only way back would be the command line against the production
        database, which on a free host is a worse afternoon than this check is
        worth avoiding.
        """
        admin_id = self.register("boss@test.com")
        self.make_admin(admin_id)
        with self.app.test_client() as client:
            client.post("/login", data={"email": "boss@test.com",
                                        "password": "testpass123"})
            client.post("/admin/users/action", data={
                "action": "demote", "user_id": admin_id})
        self.assertEqual(self.flag(admin_id, "is_admin"), 1)

    def test_demotion_is_allowed_once_there_is_a_second_administrator(self):
        first = self.register("boss@test.com")
        second = self.register("deputy@test.com", name="Deputy")
        self.make_admin(first)
        self.make_admin(second)
        with self.app.test_client() as client:
            client.post("/login", data={"email": "boss@test.com",
                                        "password": "testpass123"})
            client.post("/admin/users/action", data={
                "action": "demote", "user_id": second})
        self.assertEqual(self.flag(second, "is_admin"), 0)
        self.assertEqual(self.flag(first, "is_admin"), 1)

    def test_an_administrator_cannot_block_themselves(self):
        """Blocking yourself also deletes your sessions.

        So the click that did it would sign you out of the only page that can
        undo it -- and if you were the only administrator, nothing could.
        """
        admin_id = self.register("boss@test.com")
        self.make_admin(admin_id)
        with self.app.test_client() as client:
            client.post("/login", data={"email": "boss@test.com",
                                        "password": "testpass123"})
            client.post("/admin/users/action", data={
                "action": "disable", "user_id": admin_id})
        self.assertEqual(self.flag(admin_id, "disabled"), 0)

    def test_an_administrator_can_block_somebody_else(self):
        admin_id = self.register("boss@test.com")
        other = self.register("plain@test.com")
        self.make_admin(admin_id)
        with self.app.test_client() as client:
            client.post("/login", data={"email": "boss@test.com",
                                        "password": "testpass123"})
            client.post("/admin/users/action", data={
                "action": "disable", "user_id": other})
        self.assertEqual(self.flag(other, "disabled"), 1)


class TestAdminPagesShowRealData(unittest.TestCase):
    """The panel's whole purpose: these are counts of rows, not fixtures."""

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.app = app.app
        self.database = database
        self.client = app.app.test_client()

        body = self.client.post("/api/register", json={
            "email": "boss@test.com", "password": "testpass123",
            "name": "Boss Person"}).get_json()
        self.admin_id = body["user"]["id"]
        conn = self.database.connect()
        try:
            self.database.admin_set_admin(conn, self.admin_id, True)
        finally:
            conn.close()

    def as_admin(self):
        client = self.app.test_client()
        client.post("/login", data={"email": "boss@test.com",
                                    "password": "testpass123"})
        return client

    def page(self, path):
        return self.as_admin().get(path).get_data(as_text=True)

    def test_a_new_account_appears_on_the_user_list(self):
        before = self.page("/admin/users")
        self.assertNotIn("newcomer@test.com", before)

        self.client.post("/api/register", json={
            "email": "newcomer@test.com", "password": "testpass123",
            "name": "New Comer"})

        after = self.page("/admin/users")
        self.assertIn("newcomer@test.com", after)
        self.assertIn("New Comer", after)

    def test_an_account_without_a_profile_is_shown_as_such(self):
        """These are exactly the accounts an admin is looking for.

        A LEFT JOIN is what keeps them visible; an inner join would drop
        every account that registered and never finished setup, which is the
        most interesting row on the page.
        """
        self.client.post("/api/register", json={
            "email": "quitter@test.com", "password": "testpass123",
            "name": "Quit Early"})
        body = self.page("/admin/users")
        self.assertIn("Quit Early", body)
        self.assertIn("Setup not finished", body)

    def test_none_of_the_original_seeded_users_survived(self):
        """The panel shipped with five fictional people in it.

        They were the point of the integration: an admin panel showing
        invented accounts is a screenshot, not a tool. If any of these names
        can appear on the page, the seed data came along with the templates.
        """
        body = self.page("/admin/users")
        for ghost in ("Aisha Rahman", "Marcus Tan", "Nur Izzati",
                      "Daniel Lim", "Mei Ling Wong", "supa_"):
            with self.subTest(ghost=ghost):
                self.assertNotIn(ghost, body)

    def test_the_search_box_escapes_like_wildcards(self):
        """Unescaped, a search for '%' lists every account.

        Which is not a data leak here -- the admin may list them anyway -- but
        it is the same escaping bug that makes '_' match any character, and a
        search box that silently ignores its own input is a search box nobody
        can trust.
        """
        self.client.post("/api/register", json={
            "email": "someone@test.com", "password": "testpass123",
            "name": "Some One"})
        conn = self.database.connect()
        try:
            self.assertEqual(self.database.admin_user_count(conn, "%"), 0)
            self.assertEqual(self.database.admin_user_count(conn, "a_c"), 0)
            self.assertEqual(self.database.admin_user_count(conn, "someone"), 1)
        finally:
            conn.close()

    def test_the_overview_counts_move_when_a_meal_is_logged(self):
        body = self.client.post("/api/register", json={
            "email": "eater@test.com", "password": "testpass123",
            "name": "Eater"}).get_json()
        headers = {"Authorization": f"Bearer {body['token']}"}

        conn = self.database.connect()
        try:
            before = self.database.admin_overview(conn)["entries"]
        finally:
            conn.close()

        self.client.post("/sync", headers=headers, json={
            "since": 0, "weights": [], "profile": None, "custom_foods": [],
            "changes": [{
                "id": "bbbb2222-0000-4000-8000-000000000001",
                "food_id": None, "food_name": "Laksa", "quantity": 1.0,
                "serving": "1 bowl", "kcal": 701, "carbs_g": 62.3,
                "protein_g": 24.8, "fat_g": 38.1, "category": "dinner",
                "tags": "", "note": "", "eaten_at": "2026-11-12T19:00:00",
                "source": "manual", "deleted": 0,
                "updated_at": "2026-11-12T19:01:00Z"}]})

        conn = self.database.connect()
        try:
            after = self.database.admin_overview(conn)["entries"]
        finally:
            conn.close()
        self.assertEqual(after, before + 1)
        self.assertIn("Laksa", self.page("/admin/"))

    def test_a_deleted_meal_stops_being_counted(self):
        """Tombstones are rows, but they are not food anybody ate."""
        body = self.client.post("/api/register", json={
            "email": "eater@test.com", "password": "testpass123",
            "name": "Eater"}).get_json()
        headers = {"Authorization": f"Bearer {body['token']}"}
        entry = {
            "id": "cccc3333-0000-4000-8000-000000000001",
            "food_id": None, "food_name": "Laksa", "quantity": 1.0,
            "serving": "1 bowl", "kcal": 701, "carbs_g": 62.3,
            "protein_g": 24.8, "fat_g": 38.1, "category": "dinner",
            "tags": "", "note": "", "eaten_at": "2026-11-12T19:00:00",
            "source": "manual", "deleted": 0,
            "updated_at": "2026-11-12T19:01:00Z"}
        self.client.post("/sync", headers=headers, json={
            "since": 0, "weights": [], "profile": None, "custom_foods": [],
            "changes": [entry]})

        conn = self.database.connect()
        try:
            with_entry = self.database.admin_overview(conn)["entries"]
        finally:
            conn.close()

        self.client.post("/sync", headers=headers, json={
            "since": 0, "weights": [], "profile": None, "custom_foods": [],
            "changes": [{**entry, "deleted": 1,
                         "updated_at": "2026-11-12T20:00:00Z"}]})

        conn = self.database.connect()
        try:
            after_delete = self.database.admin_overview(conn)["entries"]
        finally:
            conn.close()
        self.assertEqual(after_delete, with_entry - 1)

    def test_the_rules_page_shows_the_effective_values(self):
        """The page is a form now, so the values are in the inputs.

        Still read at render time rather than typed into the template: an
        unedited database shows logic.py's own defaults, so a change to a
        constant changes the page.
        """
        import logic
        body = self.page("/admin/section/rules-and-metrics")
        self.assertIn(f'name="min_daily_target"', body)
        self.assertIn(f'value="{logic.MIN_DAILY_TARGET}"', body)
        self.assertIn(f'value="{logic.MAX_DAILY_TARGET}"', body)
        for level in logic.ACTIVITY_MULTIPLIERS:
            with self.subTest(level=level):
                self.assertIn(level, body)
                self.assertIn(f'name="activity.{level}"', body)

    def test_the_sessions_page_lists_a_real_sign_in(self):
        self.client.post("/api/register", json={
            "email": "phone@test.com", "password": "testpass123",
            "name": "Phone Owner"})
        body = self.page("/admin/section/security-log")
        self.assertIn("phone@test.com", body)

    def test_an_expired_session_is_not_listed_as_a_way_in(self):
        import accounts
        self.client.post("/api/register", json={
            "email": "stale@test.com", "password": "testpass123",
            "name": "Stale Session"})
        conn = self.database.connect()
        try:
            conn.execute(
                "UPDATE sessions SET expires_at = ? WHERE user_id ="
                " (SELECT id FROM users WHERE email = ?)",
                ("2020-01-01T00:00:00+00:00", "stale@test.com"))
            conn.commit()
        finally:
            conn.close()
        body = self.page("/admin/section/security-log")
        self.assertNotIn("stale@test.com", body)

    def test_an_unknown_user_id_redirects_rather_than_crashing(self):
        response = self.as_admin().get("/admin/users/no-such-account")
        self.assertEqual(response.status_code, 302)


class TestDestructiveInitIsRefusedOnPostgres(unittest.TestCase):
    """The guard on init(force=True).

    This exists because the accident happened. Running `python -m unittest
    tests` from the backend folder pointed the suite at Neon -- db.py loads
    .env.local at import -- and every test class that called
    init(force=True) dropped the production tables.

    Two defences, and a test for each: init() refuses the destructive path
    against Postgres unless explicitly told otherwise, and tests.py pins
    itself to a scratch SQLite file before importing anything.
    """

    FAKE = ("postgresql://nutri:secret@ep-example-123.ap-southeast-1"
            ".aws.neon.tech/nutriapp?sslmode=require")

    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in
                      ("DATABASE_URL", "DATABASE_URL_UNPOOLED",
                       "NUTRIAPP_ALLOW_DESTRUCTIVE")}

    def tearDown(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def point_at_postgres(self):
        os.environ["DATABASE_URL"] = self.FAKE
        os.environ["DATABASE_URL_UNPOOLED"] = self.FAKE
        os.environ.pop("NUTRIAPP_ALLOW_DESTRUCTIVE", None)

    def test_force_is_refused_against_postgres(self):
        import database
        self.point_at_postgres()
        with self.assertRaises(RuntimeError) as caught:
            database.init(force=True)
        self.assertIn("Refusing to drop every table", str(caught.exception))

    def test_the_refusal_happens_before_connecting(self):
        """So an unreachable database still explains itself.

        The host above does not exist. If the check ran after connect(), this
        would be a connection error naming nothing useful -- which is what
        the first version of the guard did.
        """
        import database
        self.point_at_postgres()
        with self.assertRaises(RuntimeError) as caught:
            database.init(force=True)
        message = str(caught.exception)
        self.assertIn("ep-example-123", message)
        self.assertIn(".env.local", message)

    def test_the_refusal_does_not_print_the_password(self):
        import database
        self.point_at_postgres()
        with self.assertRaises(RuntimeError) as caught:
            database.init(force=True)
        self.assertNotIn("secret", str(caught.exception))

    def test_an_explicit_opt_in_is_honoured(self):
        """Rebuilding a database on purpose has to stay possible.

        The guard is against doing it by accident, not against doing it. With
        the variable set, init() gets past the check and fails on the
        connection instead -- which is as far as this test can go without a
        real Postgres to drop.
        """
        import database
        self.point_at_postgres()
        os.environ["NUTRIAPP_ALLOW_DESTRUCTIVE"] = "1"
        with self.assertRaises(Exception) as caught:
            database.init(force=True)
        self.assertNotIn("Refusing to drop", str(caught.exception))

    def test_init_without_force_is_not_blocked(self):
        """What Render's build step runs. It must never be refused."""
        import database
        self.point_at_postgres()
        with self.assertRaises(Exception) as caught:
            database.init()
        self.assertNotIn("Refusing to drop", str(caught.exception))

    def test_force_still_works_against_sqlite(self):
        """Where it is free, and where every other test relies on it."""
        import database
        self.assertFalse(db.is_postgres())
        database.init(force=True)
        conn = database.connect()
        try:
            self.assertEqual(database.admin_user_count(conn), 0)
        finally:
            conn.close()

    def test_this_suite_is_pinned_to_sqlite(self):
        """The guard at the top of this file, asserted as a test.

        If a future edit moves an import above that block, or something sets
        DATABASE_URL during collection, this fails rather than the tests
        quietly running against a real database.
        """
        self.assertFalse(db.is_postgres())
        self.assertNotIn("module.db", db.SQLITE_PATH)


class TestEditableRules(unittest.TestCase):
    """Administrator-edited calorie rules.

    The point of the feature is that a saved change reaches the calculation.
    A test that only checks the row was written would pass with the rules
    stored and never read, which is the failure worth catching.
    """

    def setUp(self):
        import app
        import database
        database.init(force=True)
        app.app.config["TESTING"] = True
        self.app = app.app
        self.database = database
        self.client = app.app.test_client()

        body = self.client.post("/api/register", json={
            "email": "boss@test.com", "password": "testpass123",
            "name": "Boss"}).get_json()
        conn = self.database.connect()
        try:
            self.database.admin_set_admin(conn, body["user"]["id"], True)
        finally:
            conn.close()

    def as_admin(self):
        client = self.app.test_client()
        client.post("/login", data={"email": "boss@test.com",
                                    "password": "testpass123"})
        return client

    def form(self, **overrides):
        """A complete, valid rules form, with any field replaced."""
        import logic
        rules = logic.default_rules()
        data = {"min_daily_target": rules["min_daily_target"],
                "max_daily_target": rules["max_daily_target"],
                "insights_window_days": rules["insights_window_days"]}
        for level, value in rules["activity"].items():
            data[f"activity.{level}"] = value
        for goal, value in rules["goal_adjustments"].items():
            data[f"goal.{goal}"] = value
        for meal, value in rules["meal_split"].items():
            data[f"meal.{meal}"] = value
        for goal, split in rules["macro_splits"].items():
            for i, share in enumerate(split):
                data[f"macro.{goal}.{i}"] = share
        for i, share in enumerate(rules["default_macro_split"]):
            data[f"macro.default.{i}"] = share
        data.update(overrides)
        return data

    def stored(self):
        conn = self.database.connect()
        try:
            return self.database.load_rules(conn)
        finally:
            conn.close()

    # --- storage ----------------------------------------------------------

    def test_a_fresh_database_uses_the_built_in_defaults(self):
        import logic
        self.assertEqual(self.stored(), logic.default_rules())

    def test_saving_a_rule_changes_what_is_loaded(self):
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(min_daily_target=1500))
        self.assertEqual(self.stored()["min_daily_target"], 1500)

    def test_restore_defaults_removes_the_override(self):
        import logic
        client = self.as_admin()
        client.post("/admin/section/rules-and-metrics",
                    data=self.form(min_daily_target=1500))
        client.post("/admin/section/rules-and-metrics", data={"action": "reset"})
        self.assertEqual(self.stored(), logic.default_rules())

    def test_a_rule_added_later_keeps_its_default(self):
        """Overrides are merged key by key, not swapped in wholesale.

        A blob written before a rule existed must not make that rule come
        back missing, or every reader of it breaks after an upgrade.
        """
        conn = self.database.connect()
        try:
            conn.execute(
                "INSERT INTO settings (key, value, updated_at) "
                "VALUES ('rules', '{\"min_daily_target\": 1400}', '2026-01-01')")
            conn.commit()
        finally:
            conn.close()
        rules = self.stored()
        self.assertEqual(rules["min_daily_target"], 1400)
        self.assertIn("activity", rules)
        self.assertIn("Sedentary", rules["activity"])

    def test_an_unreadable_stored_value_falls_back_to_defaults(self):
        """Better quietly correct figures than every target in the app failing."""
        import logic
        conn = self.database.connect()
        try:
            conn.execute("INSERT INTO settings (key, value, updated_at)"
                         " VALUES ('rules', 'not json', '2026-01-01')")
            conn.commit()
        finally:
            conn.close()
        self.assertEqual(self.stored(), logic.default_rules())

    # --- the part that matters: it reaches the calculation ----------------

    def test_an_edited_goal_adjustment_changes_a_real_users_target(self):
        import logic
        who = dict(age=30, height_cm=175.0, weight_kg=80.0,
                   activity_level="Moderately Active", goal="Lose Weight",
                   gender="Male")
        before = logic.daily_target_for(**who)

        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(**{"goal.Lose Weight": -250}))

        after = logic.daily_target_for(rules=self.stored(), **who)
        self.assertNotEqual(before, after)
        self.assertAlmostEqual(after, before + 250, delta=10)

    def test_an_edited_floor_raises_a_target_that_was_below_it(self):
        import logic
        # Someone small enough that the deficit would otherwise take them low.
        who = dict(age=60, height_cm=150.0, weight_kg=45.0,
                   activity_level="Sedentary", goal="Lose Weight",
                   gender="Female")
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(min_daily_target=1800))
        after = logic.daily_target_for(rules=self.stored(), **who)
        self.assertGreaterEqual(after, 1800)

    def test_the_profile_form_accepts_a_target_the_new_rules_allow(self):
        """The manual-target check must follow the edited limits, not the
        built-in ones, or the form rejects a value the rules now permit."""
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(max_daily_target=5500))
        client = self.app.test_client()
        client.post("/api/register", json={
            "email": "eater@test.com", "password": "testpass123",
            "name": "Eater"})
        client.post("/login", data={"email": "eater@test.com",
                                    "password": "testpass123"})
        response = client.post("/profile/setup", data={
            "name": "Eater", "age": 30, "gender": "Male", "height_cm": 180,
            "weight_kg": 85, "activity_level": "Very Active",
            "goal": "Build Muscle", "target_weight_kg": 88,
            "target_kcal": 5200}, follow_redirects=True)
        self.assertNotIn("must be between", response.get_data(as_text=True))

    # --- validation -------------------------------------------------------

    def test_the_floor_cannot_be_set_below_1200(self):
        """The one bound that is not a preference.

        It is the lowest intake the app will ever recommend, and the people
        it affects do not see this page.
        """
        before = self.stored()["min_daily_target"]
        response = self.as_admin().post(
            "/admin/section/rules-and-metrics",
            data=self.form(min_daily_target=400), follow_redirects=True)
        self.assertEqual(self.stored()["min_daily_target"], before)
        self.assertIn("between 1200", response.get_data(as_text=True))

    def test_the_maximum_must_exceed_the_minimum(self):
        before = self.stored()
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(min_daily_target=2400,
                                            max_daily_target=2000))
        self.assertEqual(self.stored(), before)

    def test_meal_shares_that_do_not_add_up_are_refused(self):
        before = self.stored()["meal_split"]
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(**{"meal.breakfast": 0.9}))
        self.assertEqual(self.stored()["meal_split"], before)

    def test_macro_shares_that_do_not_add_up_are_refused(self):
        before = self.stored()["macro_splits"]["Lose Weight"]
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(**{"macro.Lose Weight.0": 0.9}))
        self.assertEqual(self.stored()["macro_splits"]["Lose Weight"], before)

    def test_a_value_that_is_not_a_number_is_refused(self):
        before = self.stored()
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(**{"activity.Sedentary": "fast"}))
        self.assertEqual(self.stored(), before)

    def test_nothing_is_saved_when_any_field_is_invalid(self):
        """Validated as a whole: a form with one bad field writes nothing.

        Several of these values only mean anything relative to each other, so
        a partial save could leave a combination nobody chose.
        """
        before = self.stored()
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(min_daily_target=400,
                                            **{"goal.Lose Weight": -300}))
        self.assertEqual(self.stored(), before)

    def test_limits_are_enforced_server_side_not_just_in_the_form(self):
        """The form's min/max attributes are a convenience, nothing more."""
        import logic
        candidate = logic.default_rules()
        candidate["min_daily_target"] = 100
        candidate["activity"]["Sedentary"] = 99
        _, errors = logic.validate_rules(candidate)
        self.assertEqual(len(errors), 2)

    # --- access -----------------------------------------------------------

    def test_an_ordinary_account_cannot_change_the_rules(self):
        before = self.stored()
        self.client.post("/api/register", json={
            "email": "plain@test.com", "password": "testpass123",
            "name": "Plain"})
        with self.app.test_client() as client:
            client.post("/login", data={"email": "plain@test.com",
                                        "password": "testpass123"})
            response = client.post("/admin/section/rules-and-metrics",
                                   data=self.form(min_daily_target=2000))
            self.assertEqual(response.status_code, 404)
        self.assertEqual(self.stored(), before)

    def test_an_anonymous_post_cannot_change_the_rules(self):
        before = self.stored()
        self.client.post("/admin/section/rules-and-metrics",
                         data=self.form(min_daily_target=2000))
        self.assertEqual(self.stored(), before)

    def test_an_edited_rule_reaches_a_target_stored_through_the_app(self):
        """End to end, through HTTP, not through logic.py directly.

        The other tests in this class prove storage works and that logic.py
        honours a rules mapping it is handed. Neither proves app.py actually
        hands it one -- which is the link that breaks if somebody adds a new
        call to build_profile and forgets the argument. This drives the real
        setup form and reads the target back out of the database.
        """
        self.as_admin().post("/admin/section/rules-and-metrics",
                             data=self.form(**{"goal.Lose Weight": -100}))

        client = self.app.test_client()
        body = client.post("/api/register", json={
            "email": "eater@test.com", "password": "testpass123",
            "name": "Eater"}).get_json()
        client.post("/login", data={"email": "eater@test.com",
                                    "password": "testpass123"})
        client.post("/profile/setup", data={
            "name": "Eater", "age": 30, "gender": "Male", "height_cm": 175,
            "weight_kg": 80, "activity_level": "Moderately Active",
            "goal": "Lose Weight", "target_weight_kg": 75},
            follow_redirects=True)

        conn = self.database.connect()
        try:
            stored = conn.execute(
                "SELECT computed_target_kcal FROM profile WHERE user_id = ?",
                (body["user"]["id"],)).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(stored, "the profile was not saved")

        import logic
        who = dict(age=30, height_cm=175.0, weight_kg=80.0,
                   activity_level="Moderately Active", goal="Lose Weight",
                   gender="Male")
        with_edit = logic.daily_target_for(rules=self.stored(), **who)
        with_default = logic.daily_target_for(**who)

        self.assertNotEqual(with_edit, with_default,
                            "the fixture does not distinguish the two")
        self.assertEqual(stored["computed_target_kcal"], with_edit)
