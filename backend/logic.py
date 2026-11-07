"""
Temp rules for the Diary and Recommendations.

Everything is calculated live here so it can be tested without starting a server
(same rules can move behind a REST API when the native client is built).
"""

from datetime import date, datetime, timedelta

# Configuration. In the full product these are set by an administrator.

# Share of the daily target allotted to each meal. Must sum to 1.0.
MEAL_SPLIT = {"breakfast": 0.25, "lunch": 0.30, "dinner": 0.35, "snacks": 0.10}

# (category, start_hour, end_hour) with start inclusive and end exclusive.
CATEGORY_WINDOWS = [("breakfast", 4, 11), ("lunch", 11, 16), ("dinner", 16, 22)]
FALLBACK_CATEGORY = "snacks"
CATEGORIES = [c for c, _, _ in CATEGORY_WINDOWS] + [FALLBACK_CATEGORY]

# Threshold rules for automatic dietary tagging, per serving.
TAG_RULES = [
    ("high-protein", lambda n: n["protein_g"] >= 25),
    ("low-protein", lambda n: n["protein_g"] < 8),
    ("high-carb", lambda n: n["carbs_g"] >= 60),
    ("low-carb", lambda n: n["carbs_g"] <= 20),
    ("high-fat", lambda n: n["fat_g"] >= 25),
    ("low-fat", lambda n: n["fat_g"] <= 5),
]

# Macro split as a share of total calories: carbs / protein / fat.
MACRO_SPLIT = (0.45, 0.30, 0.25)
KCAL_PER_G = {"carbs_g": 4, "protein_g": 4, "fat_g": 9}

# Discover opens with a short list and reveals the rest on request, so the
# first screen stays readable without a long scroll.
SHOWN_INITIALLY = 3
MORE_STEP = 5
SHOWN_EXPANDED = SHOWN_INITIALLY + MORE_STEP

# Kept as the default limit for callers that do not care about the split.
RECOMMENDATIONS_SHOWN = SHOWN_EXPANDED

# Days of history the insights page summarises, and how far from the target a
# day still counts as having hit it.
INSIGHTS_WINDOW_DAYS = 7
ON_TARGET_TOLERANCE = 0.10


# Goals
# Multiplier applied to resting burn for each activity level. Keyed by the
# label the setup form offers, so there is one spelling of each level rather
# than a form set and a logic set that can drift apart.
ACTIVITY_MULTIPLIERS = {
    "Sedentary": 1.20,
    "Lightly Active": 1.375,
    "Moderately Active": 1.55,
    "Very Active": 1.725,
}
DEFAULT_ACTIVITY_MULTIPLIER = 1.55

# Daily calorie change each goal implies. A 500 kcal deficit is about 0.45 kg
# a week, the rate normally considered sustainable. Surpluses are smaller
# because excess beyond roughly 300-400 kcal tends to be stored as fat rather
# than used for muscle.
GOAL_ADJUSTMENTS = {
    "Lose Weight": -500,
    "Maintain Weight": 0,
    "Gain Weight": 400,
    "Build Muscle": 300,
    "Eat Healthier": 0,
}

# Macro shares per goal, as carbs / protein / fat. Protein rises for muscle
# gain and for weight loss, where it protects lean mass.
GOAL_MACRO_SPLITS = {
    "Build Muscle": (0.40, 0.35, 0.25),
    "Lose Weight": (0.35, 0.35, 0.30),
    "Gain Weight": (0.50, 0.25, 0.25),
}

# Bounds on a generated target. The floor exists because the formula can
# produce an unsafely low number for a small, sedentary person on a deficit.
MIN_DAILY_TARGET = 1200
MAX_DAILY_TARGET = 4500

# Setup chip label to the allergen token recipes are tagged with. The two
# vocabularies are not the same: the form says "Dairy" because that is what
# people call it, the data says "milk" because that is the allergen. Without
# this map the comparison in is_safe_for silently finds nothing, and someone
# who declared a dairy allergy is shown cheese.
ALLERGEN_TOKENS = {
    "Peanuts": "peanut",
    "Tree Nuts": "nuts",
    "Dairy": "milk",
    "Eggs": "egg",
    "Gluten": "gluten",
    "Soy": "soy",
    "Fish": "fish",
    "Shellfish": "shellfish",
    "Sesame": "sesame",
}

DIET_TOKENS = {
    "Vegetarian": "vegetarian",
    "Vegan": "vegan",
    "Pescatarian": "pescatarian",
    "Halal": "halal",
    "High protein": "high-protein",
    "High fibre": "high-fibre",
    "Low carb": "low-carb",
}

# A recipe request takes one diet type, so a list has to be narrowed to one.
# The most restrictive wins: a vegan who also wants high protein is poorly
# served by a chicken breast, while the reverse costs only variety.
DIET_PRECEDENCE = ("vegan", "vegetarian", "pescatarian", "halal",
                   "high-protein", "high-fibre", "low-carb")



# Calorie calculation
def scale_nutrition(food, quantity):
    """Scale a food's per-serving values by a quantity.

    Foods are stored per serving rather than per 100 g, so a hawker plate and a
    40 g scoop of oats can share one table without a unit column that half the
    rows would ignore.
    """
    return {
        "kcal": round(food["kcal"] * quantity),
        "carbs_g": round(food["carbs_g"] * quantity, 1),
        "protein_g": round(food["protein_g"] * quantity, 1),
        "fat_g": round(food["fat_g"] * quantity, 1),
    }


# Automatic meal categorisation
def categorise_by_time(eaten_at):
    """Derive a meal category from when the food was eaten.

    Uses the time of the meal, not the time of logging, so recording yesterday's
    dinner at midnight still files it under dinner.
    """
    if isinstance(eaten_at, str):
        eaten_at = datetime.fromisoformat(eaten_at)
    hour = eaten_at.hour
    for name, start, end in CATEGORY_WINDOWS:
        if start <= hour < end:
            return name
    return FALLBACK_CATEGORY

# Dietary-type tagging
def auto_tags(nutrition):
    """Tags a serving earns from the threshold rules.

    Returns an empty list when nothing applies, not a placeholder. An
    empty result is what the interface uses to offer manual tagging, 
    has to be distinguishable from "not yet evaluated".
    """
    return [name for name, rule in TAG_RULES if rule(nutrition)]

# Daily summary and dashboard
def split_target(target_kcal, split=None):
    """Divide the daily target across meals, absorbing rounding drift.

    Rounding each share independently can leave the parts a few calories off the
    total, which reads as a bug on screen.
    """
    split = split or MEAL_SPLIT
    parts = {meal: round(target_kcal * share) for meal, share in split.items()}
    drift = target_kcal - sum(parts.values())
    if drift:
        parts[max(parts, key=lambda m: parts[m])] += drift
    return parts


def macro_targets(target_kcal, split=MACRO_SPLIT):
    """Grams of carbohydrate, protein and fat implied by a calorie target."""
    carbs, protein, fat = split
    return {
        "carbs_g": round(target_kcal * carbs / KCAL_PER_G["carbs_g"]),
        "protein_g": round(target_kcal * protein / KCAL_PER_G["protein_g"]),
        "fat_g": round(target_kcal * fat / KCAL_PER_G["fat_g"]),
    }


# Turning a profile into a calorie target
def basal_metabolic_rate(age, height_cm, weight_kg, gender=None):
    """Resting energy expenditure, by Mifflin-St Jeor.

    Chosen over Harris-Benedict because it is the more accurate of the two for
    contemporary populations. The equation is defined for male and female only;
    anyone who did not state a sex, or stated something else, gets the midpoint
    of the two constants rather than being pushed into one of them.
    """
    base = (10 * weight_kg) + (6.25 * height_cm) - (5 * age)
    constant = {"Male": 5.0, "Female": -161.0}.get(gender, -78.0)
    return max(0, round(base + constant))


def daily_target_for(age, height_cm, weight_kg, activity_level, goal,
                     gender=None):
    """The daily calorie target a profile's measurements and goal imply.

    Resting burn, scaled for activity, then adjusted for the goal. The result
    is never below resting burn: a deficit that takes someone under what their
    body uses at rest is the one outcome this must not produce, however the
    numbers come out.
    """
    bmr = basal_metabolic_rate(age, height_cm, weight_kg, gender)
    multiplier = ACTIVITY_MULTIPLIERS.get(activity_level,
                                          DEFAULT_ACTIVITY_MULTIPLIER)
    adjusted = (bmr * multiplier) + GOAL_ADJUSTMENTS.get(goal, 0)

    floor = max(bmr, MIN_DAILY_TARGET)
    clamped = min(max(adjusted, floor), MAX_DAILY_TARGET)

    # Rounded to ten, because a target presented as 1,847 implies a precision
    # the estimate does not have.
    return round(clamped / 10) * 10


def macro_split_for(goal):
    """Macro shares for a goal, falling back to the default split."""
    return GOAL_MACRO_SPLITS.get(goal, MACRO_SPLIT)


# Translating what setup collects into what the recipe data uses
def normalise_allergens(restrictions):
    """Allergen tokens for a set of chosen restriction labels.

    An unknown label is lowercased and passed through rather than dropped, so a
    restriction added to the form later still reaches the filter.
    """
    out = {ALLERGEN_TOKENS.get(label, str(label).strip().lower())
           for label in restrictions}
    return sorted(t for t in out if t)


def normalise_preferences(preferences):
    """Diet tokens for a set of chosen preference labels."""
    out = {DIET_TOKENS.get(label, str(label).strip().lower())
           for label in preferences}
    return sorted(t for t in out if t)


def primary_diet_type(preferences):
    """The single diet type to request meals for, from a list of preferences."""
    tokens = set(normalise_preferences(preferences))
    for candidate in DIET_PRECEDENCE:
        if candidate in tokens:
            return candidate
    return "balanced"


def build_profile(name, age, height_cm, weight_kg, activity_level, goal,
                  email="", gender=None, target_weight_kg=None,
                  preferences=(), restrictions=(), manual_target_kcal=None,
                  updated_at=None):
    """Assemble a stored profile from what the setup form collected.

    The one place raw answers become the normalised values the rest of the app
    reads, so nothing downstream can filter on an untranslated label.
    """
    computed = daily_target_for(age, height_cm, weight_kg, activity_level,
                                goal, gender)
    return {
        "name": name,
        "email": email,
        "age": age,
        "gender": gender,
        "height_cm": height_cm,
        "weight_kg": weight_kg,
        "activity_level": activity_level,
        "goal": goal,
        "target_weight_kg": target_weight_kg,
        "preferences": list(preferences),
        "restrictions": list(restrictions),
        "allergens": normalise_allergens(restrictions),
        "diet_types": normalise_preferences(preferences),
        "diet_type": primary_diet_type(preferences),
        "computed_target_kcal": computed,
        "target_kcal": manual_target_kcal or computed,
        "target_is_manual": manual_target_kcal is not None,
        "updated_at": updated_at,
    }


def summarise_day(entries, target_kcal, split=None):
    #Roll a day's entries into the figures the dashboard and diary show.
    # The macro split varies by goal, so it is a parameter rather than a
    # constant read from inside.

    totals = {"kcal": 0, "carbs_g": 0.0, "protein_g": 0.0, "fat_g": 0.0}
    by_category = {c: 0 for c in CATEGORIES}

    for e in entries:
        totals["kcal"] += e["kcal"]
        totals["carbs_g"] += e["carbs_g"]
        totals["protein_g"] += e["protein_g"]
        totals["fat_g"] += e["fat_g"]
        by_category[e["category"]] = by_category.get(e["category"], 0) + e["kcal"]

    return {
        "eaten": totals["kcal"],
        "target": target_kcal,
        "remaining": target_kcal - totals["kcal"],
        "over": totals["kcal"] > target_kcal,
        "percent": min(100, round(totals["kcal"] / target_kcal * 100)) if target_kcal else 0,
        "macros": {k: round(v, 1) for k, v in totals.items() if k != "kcal"},
        "macro_targets": macro_targets(target_kcal, split or MACRO_SPLIT),
        "by_category": by_category,
        "allowances": split_target(target_kcal),
        "entry_count": len(entries),
    }


def remaining_for_meal(summary, category):
    """Calories still available for one meal. Never negative."""
    return max(0, summary["allowances"].get(category, 0)
               - summary["by_category"].get(category, 0))




# Recommendation filtering and retrieval
def is_safe_for(recipe, allergens):
    """True when a recipe lists none of the user's recorded allergens.

    This is a hard exclusion applied before any ranking. A recipe that fails it
    is removed from the pool.
    """
    return not (set(a.lower() for a in allergens) & set(recipe["allergens"]))


def matches_diet(recipe, diet_type):
    """True when a recipe fits the chosen diet type."""
    if diet_type in (None, "balanced"):
        return True
    return diet_type in recipe["diet_types"]


def score_recipe(recipe, slot_target_kcal, recent_ids):
    """Rank a safe recipe. Higher is better.

    how close it lands to the calories left for the meal, and
    whether it was suggested recently.
    """
    if slot_target_kcal <= 0:
        fit = 0.0
    else:
        miss = abs(recipe["kcal"] - slot_target_kcal) / slot_target_kcal
        fit = max(0.0, 1.0 - miss)
    variety = 0.0 if recipe["id"] in recent_ids else 1.0
    return (fit * 0.7) + (variety * 0.3)


def recommend(recipes, allergens, diet_type, slot_target_kcal,
              recent_ids=(), limit=RECOMMENDATIONS_SHOWN):
    """Filter, then rank, then take the top few.

    unsafe recipes are dropped first, so someone with a peanut
    allergy cannot be shown a peanut dish even if it fits their calories.
    """
    safe = [r for r in recipes if is_safe_for(r, allergens)]
    on_diet = [r for r in safe if matches_diet(r, diet_type)]
    pool = on_diet or safe          # fall back rather than return nothing
    ranked = sorted(pool, key=lambda r: score_recipe(r, slot_target_kcal, recent_ids),
                    reverse=True)
    return ranked[:limit]


# Insights: summarising a run of days
def day_key(value):
    """Calendar day as a sortable key, the same spelling the database stores."""
    if isinstance(value, str):
        value = datetime.fromisoformat(value)
    return value.strftime("%Y-%m-%d")


def daily_totals(entries, end_day=None, days=INSIGHTS_WINDOW_DAYS):
    """One row per day across a window, oldest first.

    Days with nothing logged are present with zero totals rather than absent.
    A chart that skips them would show an unbroken run of good days to someone
    who simply stopped recording, which is the opposite of the truth.
    """
    end_day = end_day or date.today()
    if isinstance(end_day, datetime):
        end_day = end_day.date()

    ordered = []
    buckets = {}
    for offset in range(days - 1, -1, -1):
        day = end_day - timedelta(days=offset)
        row = {"day": day, "kcal": 0, "carbs_g": 0.0, "protein_g": 0.0,
               "fat_g": 0.0, "entry_count": 0,
               "by_category": {c: 0 for c in CATEGORIES}}
        buckets[day_key(day)] = row
        ordered.append(row)

    for e in entries:
        if e.get("deleted"):
            continue
        row = buckets.get(day_key(e["eaten_at"]))
        if row is None:                      # outside the window
            continue
        row["kcal"] += e["kcal"]
        row["carbs_g"] += e["carbs_g"]
        row["protein_g"] += e["protein_g"]
        row["fat_g"] += e["fat_g"]
        row["entry_count"] += 1
        category = e["category"]
        row["by_category"][category] = row["by_category"].get(category, 0) + e["kcal"]

    return ordered


def logging_streak(totals):
    """Consecutive days with at least one entry, counting back from the last.

    Today is allowed to be empty without breaking the run: a streak that
    collapses at breakfast every morning would be useless.
    """
    if not totals:
        return 0
    index = len(totals) - 1
    if totals[index]["entry_count"] == 0:
        index -= 1                           # today not logged yet
    streak = 0
    while index >= 0 and totals[index]["entry_count"] > 0:
        streak += 1
        index -= 1
    return streak


def summarise_trend(totals, target_kcal):
    """Averages and adherence across a window.

    The average is taken over days that were actually logged, not over the
    whole window. Dividing by seven when only three days were recorded reports
    an intake of roughly half what the person ate, which would make every
    summary look like a deficit.
    """
    logged = [d for d in totals if d["entry_count"] > 0]
    tolerance = target_kcal * ON_TARGET_TOLERANCE
    n = len(logged)

    on_target = sum(1 for d in logged if abs(d["kcal"] - target_kcal) <= tolerance)
    over = sum(1 for d in logged
               if d["kcal"] > target_kcal and abs(d["kcal"] - target_kcal) > tolerance)
    under = n - on_target - over

    def mean(field):
        return round(sum(d[field] for d in logged) / n, 1) if n else 0

    return {
        "days": len(totals),
        "days_logged": n,
        "target": target_kcal,
        "average_kcal": round(sum(d["kcal"] for d in logged) / n) if n else 0,
        "average_macros": {
            "carbs_g": mean("carbs_g"),
            "protein_g": mean("protein_g"),
            "fat_g": mean("fat_g"),
        },
        "macro_targets": macro_targets(target_kcal),
        "days_on_target": on_target,
        "days_over": over,
        "days_under": under,
        "streak": logging_streak(totals),
        "highest": max((d["kcal"] for d in logged), default=0),
        "lowest": min((d["kcal"] for d in logged), default=0),
        "adherence_percent": round(on_target / n * 100) if n else 0,
    }


def category_totals(totals):
    """Calories per meal across a window."""
    out = {c: 0 for c in CATEGORIES}
    for day in totals:
        for category, kcal in day["by_category"].items():
            out[category] = out.get(category, 0) + kcal
    return out


def weight_change(log):
    """Change between the first and last recorded measurement.

    None rather than zero when there is nothing to compare, so the page can say
    "log a second weight" instead of claiming no change.
    """
    live = sorted((w for w in log if not w.get("deleted")),
                  key=lambda w: w["recorded_at"])
    if len(live) < 2:
        return None
    return round(live[-1]["kg"] - live[0]["kg"], 1)


def progress_towards_target(log, target_kg):
    """How far a weight log has moved towards its target, as a percentage.

    None when there is no target, fewer than two measurements, or the starting
    weight already met it, since a share of zero progress needed is not a
    meaningful number.
    """
    if target_kg is None:
        return None
    live = sorted((w for w in log if not w.get("deleted")),
                  key=lambda w: w["recorded_at"])
    if len(live) < 2:
        return None

    start, current = live[0]["kg"], live[-1]["kg"]
    needed = target_kg - start
    if abs(needed) < 0.1:
        return None
    return max(0, min(100, round((current - start) / needed * 100)))
