"""

Manages the external recipe service and supplies the meals it recommends.
From https://www.themealdb.com/api.php

     Two calls per meal. filter.php returns only an id, a name and a thumbnail.
     Ingredients arrive only from lookup.php, so candidates are filtered first
     and then looked up individually. TheMealDB's own agent guidance asks for
     exactly this order and says not to present a recipe from a filter response
     alone.

  2. No nutrition. There is no calorie or macro field anywhere in
     the API, so figures are estimated locally from the ingredient list and
     labelled as estimates.

  3. No allergen field. Allergens are derived by matching ingredient text
     against a keyword map. TheMealDB states it is not an allergen
     certification service, so derived results are treated as a filter that can
     miss things.

"""

import json
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta

import database

BASE_URL = "https://www.themealdb.com/api/json/v1/{key}/"
DEV_KEY = "1"
MEAL_PAGE = "https://www.themealdb.com/meal/{id}"
ATTRIBUTION = "Recipe data and imagery: TheMealDB (https://www.themealdb.com/)"

TIMEOUT_SECONDS = 6
CACHE_TTL_HOURS = 24
MAX_LOOKUPS_PER_REQUEST = 14     # each candidate costs one call
USER_AGENT = "NutriApp-prototype/1.0 (student project)"

# Categories used to satisfy a diet type. TheMealDB has Vegan and Vegetarian
# categories, which is the only diet signal the API gives directly.
DIET_CATEGORIES = {
    "vegan": ["Vegan"],
    "vegetarian": ["Vegetarian", "Vegan"],
    "pescatarian": ["Seafood", "Vegetarian", "Vegan", "Side"],
    "halal": ["Chicken", "Beef", "Seafood", "Vegetarian", "Side"],
    "high-protein": ["Chicken", "Beef", "Seafood"],
    "high-fibre": ["Vegetarian", "Vegan", "Side"],
    "low-carb": ["Seafood", "Chicken", "Beef", "Side"],
    "balanced": ["Chicken", "Seafood", "Beef", "Pasta", "Vegetarian", "Side"],
}

# Diet derivation
# TheMealDB's only direct diet signal is its Vegan and Vegetarian categories.
# Pescatarian and halal are not stated anywhere, so they are derived the same
# way allergens are: by looking for ingredient words that rule a meal out.
#
# This establishes absence, not certification. A meal with no pork or alcohol
# in its ingredient list is not thereby halal — that depends on slaughter and
# handling, which no recipe database records. The tag means "nothing in the
# listed ingredients rules it out", and the interface says so.
MEAT_KEYWORDS = [
    "beef", "pork", "lamb", "mutton", "chicken", "turkey", "duck", "goose",
    "veal", "venison", "rabbit", "goat", "bacon", "ham", "gammon", "sausage",
    "chorizo", "pancetta", "prosciutto", "salami", "pepperoni", "steak",
    "mince", "lard", "liver", "kidney", "oxtail", "brisket", "pastrami",
    "bratwurst", "pepperami", "suet", "gelatin", "gelatine",
]

NON_HALAL_KEYWORDS = [
    "pork", "bacon", "ham", "gammon", "lard", "pancetta", "prosciutto",
    "chorizo", "salami", "pepperoni", "wine", "beer", "ale", "cider", "rum",
    "brandy", "sherry", "vodka", "whisky", "whiskey", "bourbon", "liqueur",
    "kirsch", "marsala", "vermouth", "sake", "stout", "lager", "alcohol",
    "gelatin", "gelatine",
]

# Checked before the keywords above, for the same reason the allergen map has
# a false-positive list: a beef tomato is a tomato, and vinegar made from wine
# no longer contains the alcohol.
DIET_FALSE_POSITIVES = {
    "meat": ["beef tomato", "beef tomatoes", "chicken stock cube",
             "beef stock cube"],
    "halal": ["wine vinegar", "red wine vinegar", "white wine vinegar",
              "rice wine vinegar", "cider vinegar", "apple cider vinegar",
              "non-alcoholic"],
}


# Allergen derivation
# Maps an allergen to the ingredient words that imply it, including
# derivatives. Matching is substring-based on normalised ingredient text.

ALLERGEN_KEYWORDS = {
    "peanut": ["peanut", "groundnut", "satay", "arachis"],
    "shellfish": ["prawn", "shrimp", "crab", "lobster", "crayfish", "langoustine",
                  "scampi", "clam", "mussel", "oyster", "scallop", "squid",
                  "calamari", "octopus", "cuttlefish", "conch", "shellfish",
                  "seafood", "belacan", "shrimp paste"],
    "fish": ["fish", "salmon", "tuna", "cod", "haddock", "anchov", "sardine",
             "mackerel", "trout", "herring", "sea bass", "seabass", "halibut",
             "tilapia", "snapper", "barramundi", "hake", "pollock", "kipper",
             "worcestershire", "oyster sauce", "nam pla", "bonito", "dashi",
             "caviar", "roe"],
    "milk": ["milk", "cheese", "butter", "cream", "yoghurt", "yogurt", "ghee",
             "whey", "casein", "custard", "creme fraiche", "mascarpone",
             "ricotta", "parmesan", "mozzarella", "cheddar", "paneer"],
    "egg": ["egg", "mayonnaise", "meringue", "aioli", "custard"],
    "soy": ["soy", "soya", "tofu", "edamame", "miso", "tempeh", "tamari",
            "hoisin", "teriyaki"],
    "gluten": ["flour", "bread", "pasta", "spaghetti", "noodle", "wheat",
               "barley", "rye", "couscous", "semolina", "breadcrumb", "pastry",
               "puff pastry", "filo", "tortilla", "cracker", "seitan", "malt",
               "beer", "soy sauce", "orzo", "lasagne", "macaroni", "penne",
               "linguine", "tagliatelle", "farfalle", "cake", "biscuit"],
    "nuts": ["almond", "cashew", "walnut", "pecan", "pistachio", "hazelnut",
             "macadamia", "brazil nut", "pine nut", "praline", "nutella",
             "marzipan"],
    "sesame": ["sesame", "tahini", "halva"],
}

# Words that would otherwise trigger a false positive. Checked before keywords.
FALSE_POSITIVES = {
    "milk": ["coconut milk", "almond milk", "soy milk", "soya milk", "oat milk",
             "rice milk", "milk thistle"],
    "gluten": ["rice flour", "corn flour", "cornflour", "gluten free",
               "gluten-free", "almond flour", "chickpea flour", "buckwheat",
               "rice noodle", "glass noodle"],
    "fish": ["fish sauce substitute"],
    "nuts": ["nutmeg", "coconut", "water chestnut", "butternut"],
}


def normalise(text):
    """Lower-case, strip accents and collapse whitespace for matching."""
    if not text:
        return ""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", text.lower().strip())


def derive_allergens(ingredients):
    """Allergen tokens implied by a list of ingredient names.

    Returns a sorted list. An empty list means nothing matched, which is not
    the same as the meal being safe.
    """
    found = set()
    for raw in ingredients:
        text = normalise(raw)
        if not text:
            continue
        for allergen, keywords in ALLERGEN_KEYWORDS.items():
            if any(fp in text for fp in FALSE_POSITIVES.get(allergen, [])):
                continue
            if any(k in text for k in keywords):
                found.add(allergen)
    return sorted(found)


def _mentions(ingredients, keywords, false_positives=()):
    """True when any ingredient matches a keyword and no exception applies."""
    for raw in ingredients:
        text = normalise(raw)
        if not text:
            continue
        if any(fp in text for fp in false_positives):
            continue
        if any(k in text for k in keywords):
            return True
    return False


def derive_diet_types(ingredients, category="", protein_g=0):
    """Diet tags a meal qualifies for, from its category and ingredients.

    Vegan and vegetarian come from TheMealDB's own category. Pescatarian and
    halal are established by the absence of disqualifying ingredients, which is
    weaker: see the note above the keyword lists. High protein is a threshold on
    the estimated figures, so it inherits their uncertainty.
    """
    tags = set()

    category = (category or "").strip()
    if category == "Vegan":
        tags.update(["vegan", "vegetarian"])
    elif category == "Vegetarian":
        tags.add("vegetarian")

    has_meat = _mentions(ingredients, MEAT_KEYWORDS,
                         DIET_FALSE_POSITIVES["meat"])
    if not has_meat:
        tags.add("pescatarian")

    if not _mentions(ingredients, NON_HALAL_KEYWORDS,
                     DIET_FALSE_POSITIVES["halal"]):
        tags.add("halal")

    if protein_g >= 25:
        tags.add("high-protein")

    return sorted(tags)


# Nutrition estimation
# kcal per 100 g, then carbs/protein/fat grams per 100 g, then the grams in one
# cup, one tablespoon and one countable unit where those differ from the
# defaults. Covers the ingredients that appear most often in TheMealDB.
DEFAULT_G_PER_CUP, DEFAULT_G_PER_TBSP, DEFAULT_G_PER_UNIT = 150.0, 15.0, 100.0

NUTRITION = {
    # name: (kcal, carbs, protein, fat, g_per_cup, g_per_tbsp, g_per_unit)
    "chicken breast": (165, 0, 31, 3.6, 140, 15, 174),
    "chicken thigh": (209, 0, 26, 11, 140, 15, 110),
    "chicken": (190, 0, 27, 8, 140, 15, 150),
    "beef": (250, 0, 26, 15, 150, 15, 150),
    "minced beef": (250, 0, 26, 15, 150, 15, 150),
    "lamb": (258, 0, 25, 17, 150, 15, 150),
    "pork": (242, 0, 27, 14, 150, 15, 150),
    "bacon": (541, 1.4, 37, 42, 150, 15, 25),
    "chorizo": (455, 2, 24, 38, 150, 15, 60),
    "sausage": (301, 2.5, 18, 24, 150, 15, 60),
    "salmon": (208, 0, 20, 13, 150, 15, 150),
    "tuna": (132, 0, 28, 1, 150, 15, 120),
    "cod": (82, 0, 18, 0.7, 150, 15, 150),
    "haddock": (90, 0, 20, 0.6, 150, 15, 150),
    "fish": (110, 0, 21, 3, 150, 15, 150),
    "prawn": (99, 0.2, 24, 0.3, 150, 15, 15),
    "shrimp": (99, 0.2, 24, 0.3, 150, 15, 15),
    "squid": (92, 3, 16, 1.4, 150, 15, 100),
    "egg": (155, 1.1, 13, 11, 150, 15, 50),
    "tofu": (144, 3, 17, 9, 150, 15, 100),
    "chickpea": (164, 27, 9, 2.6, 164, 15, 100),
    "lentil": (116, 20, 9, 0.4, 198, 15, 100),
    "black bean": (132, 24, 9, 0.5, 172, 15, 100),
    "kidney bean": (127, 23, 9, 0.5, 177, 15, 100),
    "rice": (130, 28, 2.7, 0.3, 185, 15, 100),
    "brown rice": (123, 26, 2.7, 1, 195, 15, 100),
    "pasta": (131, 25, 5, 1.1, 140, 15, 100),
    "spaghetti": (131, 25, 5, 1.1, 140, 15, 100),
    "noodle": (138, 25, 4.5, 2, 140, 15, 100),
    "bread": (265, 49, 9, 3.2, 150, 15, 30),
    "breadcrumb": (395, 72, 13, 5, 108, 15, 30),
    "flour": (364, 76, 10, 1, 120, 8, 100),
    "potato": (77, 17, 2, 0.1, 150, 15, 170),
    "sweet potato": (86, 20, 1.6, 0.1, 150, 15, 130),
    "onion": (40, 9, 1.1, 0.1, 160, 15, 110),
    "garlic": (149, 33, 6.4, 0.5, 136, 8, 3),
    "tomato": (18, 3.9, 0.9, 0.2, 180, 15, 123),
    "carrot": (41, 10, 0.9, 0.2, 128, 15, 61),
    "broccoli": (34, 7, 2.8, 0.4, 91, 15, 100),
    "spinach": (23, 3.6, 2.9, 0.4, 30, 15, 100),
    "mushroom": (22, 3.3, 3.1, 0.3, 70, 15, 20),
    "pepper": (26, 6, 1, 0.3, 149, 15, 120),
    "courgette": (17, 3.1, 1.2, 0.3, 124, 15, 200),
    "aubergine": (25, 6, 1, 0.2, 82, 15, 250),
    "cabbage": (25, 6, 1.3, 0.1, 89, 15, 100),
    "peas": (81, 14, 5.4, 0.4, 145, 15, 100),
    "corn": (86, 19, 3.3, 1.2, 154, 15, 100),
    "vegetables": (45, 9, 2, 0.3, 150, 15, 100),
    "avocado": (160, 9, 2, 15, 150, 15, 150),
    "lettuce": (15, 2.9, 1.4, 0.2, 47, 15, 100),
    "cucumber": (15, 3.6, 0.7, 0.1, 119, 15, 300),
    "lemon": (29, 9, 1.1, 0.3, 244, 15, 60),
    "lime": (30, 11, 0.7, 0.2, 244, 15, 45),
    "apple": (52, 14, 0.3, 0.2, 125, 15, 180),
    "banana": (89, 23, 1.1, 0.3, 150, 15, 118),
    "coconut milk": (230, 6, 2.3, 24, 240, 15, 100),
    "milk": (61, 4.8, 3.2, 3.3, 244, 15, 100),
    "cream": (340, 2.8, 2.1, 36, 238, 15, 100),
    "yoghurt": (61, 4.7, 3.5, 3.3, 245, 15, 100),
    "butter": (717, 0.1, 0.9, 81, 227, 14, 10),
    "cheese": (402, 1.3, 25, 33, 113, 15, 30),
    "parmesan": (431, 4.1, 38, 29, 100, 5, 20),
    "olive oil": (884, 0, 0, 100, 216, 13.5, 5),
    "oil": (884, 0, 0, 100, 218, 13.6, 5),
    "sugar": (387, 100, 0, 0, 200, 12.5, 4),
    "brown sugar": (380, 98, 0, 0, 220, 13, 4),
    "honey": (304, 82, 0.3, 0, 340, 21, 7),
    "soy sauce": (53, 5, 8, 0.1, 255, 16, 5),
    "fish sauce": (35, 4, 5, 0, 250, 16, 5),
    "vinegar": (18, 0.4, 0, 0, 240, 15, 5),
    "stock": (7, 0.9, 0.7, 0.2, 240, 15, 240),
    "water": (0, 0, 0, 0, 240, 15, 240),
    "wine": (83, 2.6, 0.1, 0, 235, 15, 150),
    "coconut": (354, 15, 3.3, 33, 80, 15, 100),
    "almond": (579, 22, 21, 50, 143, 15, 1.2),
    "cashew": (553, 30, 18, 44, 137, 15, 1.5),
    "peanut": (567, 16, 26, 49, 146, 16, 1),
    "sesame": (573, 23, 18, 50, 144, 9, 1),
    "tahini": (595, 21, 17, 54, 240, 15, 15),
    "cornstarch": (381, 91, 0.3, 0.1, 128, 8, 8),
    "ginger": (80, 18, 1.8, 0.8, 96, 6, 5),
    "chilli": (40, 9, 1.9, 0.4, 100, 8, 15),
    "coriander": (23, 3.7, 2.1, 0.5, 16, 2, 5),
    "parsley": (36, 6.3, 3, 0.8, 60, 4, 5),
    "basil": (23, 2.7, 3.2, 0.6, 24, 2, 5),
    "salt": (0, 0, 0, 0, 292, 18, 6),
    "black pepper": (251, 64, 10, 3.3, 100, 6, 2),
    "spice": (300, 50, 10, 8, 100, 6, 2),
    "paprika": (282, 54, 14, 13, 100, 7, 2),
    "cumin": (375, 44, 18, 22, 100, 6, 2),
    "curry powder": (325, 56, 14, 14, 100, 6, 2),
    "chocolate": (546, 61, 4.9, 31, 170, 15, 100),
}

# Fractions and unicode fraction characters that appear in measures.
UNICODE_FRACTIONS = {"½": ".5", "¼": ".25", "¾": ".75", "⅓": ".333",
                     "⅔": ".667", "⅛": ".125", "⅜": ".375", "⅝": ".625",
                     "⅞": ".875"}

UNIT_PATTERNS = [
    (r"\b(kgs?|kilograms?)\b", "kg"),
    (r"\b(g|gr|grams?|gms?)\b", "g"),
    (r"\b(lbs?|pounds?)\b", "lb"),
    (r"\b(oz|ounces?)\b", "oz"),
    (r"\b(ml|millilitres?|milliliters?)\b", "ml"),
    (r"\b(l|litres?|liters?)\b", "l"),
    (r"\b(tbsp|tbs|tablespoons?)\b", "tbsp"),
    (r"\b(tsp|teaspoons?)\b", "tsp"),
    (r"\b(cups?)\b", "cup"),
    (r"\b(cloves?)\b", "clove"),
    (r"\b(pinch|dash)\b", "pinch"),
]

# Grams for units that do not depend on the ingredient.
FIXED_GRAMS = {"kg": 1000.0, "g": 1.0, "lb": 453.6, "oz": 28.35,
               "ml": 1.0, "l": 1000.0, "pinch": 0.5, "clove": 3.0}

ASSUMED_SERVINGS = 4        # TheMealDB does not state a yield


def parse_measure(measure):
    """Turn a measure string into (quantity, unit). Unit may be None.

    Handles the shapes TheMealDB actually uses: "3/4 cup", "1/2 teaspoon",
    "4 Tablespoons", "2", "1 (12 oz.)", "3 cups", "½ tsp", "Some".
    """
    if not measure:
        return None, None
    text = measure.strip().lower()
    for ch, dec in UNICODE_FRACTIONS.items():
        text = text.replace(ch, dec)

    # "1 (12 oz.)" describes a 12 oz package; the parenthesised part wins.
    paren = re.search(r"\(([^)]*)\)", text)
    if paren and re.search(r"\d", paren.group(1)):
        text = paren.group(1)

    qty = None
    mixed = re.match(r"^\s*(\d+)\s+(\d+)\s*/\s*(\d+)", text)     # "1 1/2"
    frac = re.match(r"^\s*(\d+)\s*/\s*(\d+)", text)              # "3/4"
    # Also matches a bare leading dot: "½ tsp" becomes ".5 tsp" above.
    dec = re.match(r"^\s*(\d+(?:\.\d+)?|\.\d+)", text)         # "2", "1.5", ".5"
    if mixed:
        qty = int(mixed.group(1)) + int(mixed.group(2)) / int(mixed.group(3))
    elif frac:
        qty = int(frac.group(1)) / int(frac.group(2))
    elif dec:
        qty = float(dec.group(1))

    unit = None
    for pattern, name in UNIT_PATTERNS:
        if re.search(pattern, text):
            unit = name
            break

    if qty is None and unit is None:
        return None, None
    return (qty if qty is not None else 1.0), unit


def match_ingredient(name):
    """Find the nutrition entry for an ingredient name, longest match first."""
    text = normalise(name)
    if not text:
        return None, None
    best = None
    for key in NUTRITION:
        if key in text and (best is None or len(key) > len(best)):
            best = key
    return (best, NUTRITION[best]) if best else (None, None)


def grams_for(entry, qty, unit):
    """Convert a parsed measure into grams for one ingredient."""
    kcal, c, p, f, g_cup, g_tbsp, g_unit = entry
    if unit in FIXED_GRAMS:
        return qty * FIXED_GRAMS[unit]
    if unit == "cup":
        return qty * (g_cup or DEFAULT_G_PER_CUP)
    if unit == "tbsp":
        return qty * (g_tbsp or DEFAULT_G_PER_TBSP)
    if unit == "tsp":
        return qty * (g_tbsp or DEFAULT_G_PER_TBSP) / 3.0
    return qty * (g_unit or DEFAULT_G_PER_UNIT)      # countable, e.g. "2" eggs


def estimate_nutrition(ingredients, measures, servings=ASSUMED_SERVINGS):
    """Estimate per-serving calories and macros from an ingredient list.

    TheMealDB carries no nutrition data, so this is the only way to give
    recommendation something to rank on. It returns a confidence figure
    alongside the numbers, because an estimate presented without one would
    imply a precision that is not there.
    """
    totals = {"kcal": 0.0, "carbs_g": 0.0, "protein_g": 0.0, "fat_g": 0.0}
    recognised = 0
    counted = 0

    for name, measure in zip(ingredients, measures):
        if not name or not name.strip():
            continue
        counted += 1
        key, entry = match_ingredient(name)
        if not entry:
            continue
        recognised += 1
        qty, unit = parse_measure(measure)
        if qty is None:
            qty, unit = 1.0, None
        grams = grams_for(entry, qty, unit)
        grams = min(grams, 2000.0)          # guard against a misparsed measure
        kcal, c, p, f = entry[0], entry[1], entry[2], entry[3]
        totals["kcal"] += kcal * grams / 100.0
        totals["carbs_g"] += c * grams / 100.0
        totals["protein_g"] += p * grams / 100.0
        totals["fat_g"] += f * grams / 100.0

    coverage = (recognised / counted) if counted else 0.0
    per_serving = {
        "kcal": max(0, round(totals["kcal"] / servings)),
        "carbs_g": round(totals["carbs_g"] / servings, 1),
        "protein_g": round(totals["protein_g"] / servings, 1),
        "fat_g": round(totals["fat_g"] / servings, 1),
    }
    per_serving["coverage"] = round(coverage, 2)
    per_serving["confidence"] = ("good" if coverage >= 0.8
                                 else "fair" if coverage >= 0.6 else "rough")
    per_serving["estimated"] = True
    return per_serving


# HTTP with an on-disk cache
class ApiError(Exception):
    """Raised when the external service cannot be reached or returns junk."""


_stats = {"calls": 0, "cache_hits": 0, "errors": 0, "last_error": None,
          "last_call_ms": None, "last_call_at": None}


def stats():
    return dict(_stats)


def _cache_get(url):
    conn = database.connect()
    row = conn.execute("SELECT body, fetched_at FROM api_cache WHERE url=?", (url,)).fetchone()
    conn.close()
    if not row:
        return None
    age = datetime.now() - datetime.fromisoformat(row["fetched_at"])
    if age > timedelta(hours=CACHE_TTL_HOURS):
        return None
    return json.loads(row["body"])


def _cache_get_stale(url):
    """Ignore the TTL. Used when the API is down and stale beats nothing."""
    conn = database.connect()
    row = conn.execute("SELECT body FROM api_cache WHERE url=?", (url,)).fetchone()
    conn.close()
    return json.loads(row["body"]) if row else None


def _cache_put(url, payload):
    conn = database.connect()
    conn.execute(
        "INSERT INTO api_cache (url, body, fetched_at) VALUES (?,?,?) "
        "ON CONFLICT(url) DO UPDATE SET body=excluded.body, fetched_at=excluded.fetched_at",
        (url, json.dumps(payload), datetime.now().isoformat()))
    conn.commit()
    conn.close()


def call(endpoint, params, key=DEV_KEY, use_cache=True):
    """One request to TheMealDB, served from cache when it is still fresh."""
    url = BASE_URL.format(key=key) + endpoint + "?" + urllib.parse.urlencode(params)

    if use_cache:
        cached = _cache_get(url)
        if cached is not None:
            _stats["cache_hits"] += 1
            return cached, "cache"

    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError,
            json.JSONDecodeError) as exc:
        _stats["errors"] += 1
        _stats["last_error"] = f"{type(exc).__name__}: {exc}"
        raise ApiError(str(exc)) from exc

    _stats["calls"] += 1
    _stats["last_call_ms"] = int((time.time() - started) * 1000)
    _stats["last_call_at"] = datetime.now().isoformat(timespec="seconds")
    _cache_put(url, payload)
    return payload, "api"


# Normalising a TheMealDB record into Nutri App's recipe shape
def extract_ingredients(meal):
    """Pair strIngredientN with strMeasureN, in order, skipping empty slots."""
    names, measures = [], []
    for i in range(1, 21):
        name = (meal.get(f"strIngredient{i}") or "").strip()
        measure = (meal.get(f"strMeasure{i}") or "").strip()
        if name:
            names.append(name)
            measures.append(measure)
    return names, measures


def normalise_meal(meal):
    """Convert one lookup.php record into the dict the rest of the app uses."""
    names, measures = extract_ingredients(meal)
    nutrition = estimate_nutrition(names, measures)
    allergens = derive_allergens(names)

    category = (meal.get("strCategory") or "").strip()
    diet_types = derive_diet_types(names, category, nutrition["protein_g"])

    return {
        "id": f"mdb-{meal['idMeal']}",
        "source_id": meal["idMeal"],
        "name": meal.get("strMeal", "Untitled"),
        "kcal": nutrition["kcal"],
        "carbs_g": nutrition["carbs_g"],
        "protein_g": nutrition["protein_g"],
        "fat_g": nutrition["fat_g"],
        "estimated": True,
        "confidence": nutrition["confidence"],
        "coverage": nutrition["coverage"],
        "minutes": None,
        "allergens": allergens,
        "diet_types": diet_types,
        "ingredients": [f"{m} {n}".strip() for n, m in zip(names, measures)],
        "category": category,
        "area": (meal.get("strArea") or "").strip(),
        "thumb": meal.get("strMealThumb") or "",
        "page": MEAL_PAGE.format(id=meal["idMeal"]),
        "instructions": (meal.get("strInstructions") or "").strip(),
        "source": "themealdb",
    }


def fetch_by_category(category, limit=MAX_LOOKUPS_PER_REQUEST, key=DEV_KEY):
    """Filter to candidates, then look each one up for its ingredients.

    Two-stage by necessity: filter.php does not return ingredients, and
    TheMealDB's guidance is to look a meal up before presenting it rather than
    relying on the filter summary.
    """
    payload, origin = call("filter.php", {"c": category}, key=key)
    candidates = payload.get("meals") or []
    if not candidates:
        return [], origin

    meals, origins = [], {origin}
    for candidate in candidates[:limit]:
        try:
            detail, detail_origin = call("lookup.php", {"i": candidate["idMeal"]}, key=key)
        except ApiError:
            continue                        # skip this one, keep the rest
        origins.add(detail_origin)
        records = detail.get("meals") or []
        if records:
            meals.append(normalise_meal(records[0]))

    return meals, ("api" if "api" in origins else "cache")


def fetch_for_diet(diet_type, per_category=6, key=DEV_KEY):
    """Gather a pool of meals appropriate to a diet type."""
    categories = DIET_CATEGORIES.get(diet_type, DIET_CATEGORIES["balanced"])
    pool, seen, origins = [], set(), set()
    for category in categories:
        try:
            meals, origin = fetch_by_category(category, limit=per_category, key=key)
        except ApiError:
            continue
        for meal in meals:
            # De-duplicate across categories. Without this the same meal can be
            # ranked several times and fill the list with one repeated result.
            if meal["id"] in seen:
                continue
            seen.add(meal["id"])
            pool.append(meal)
        origins.add(origin)
    if not pool:
        raise ApiError("no meals returned from any category")
    return pool, ("api" if "api" in origins else "cache")


def fetch_one(source_id, key=DEV_KEY):
    """Full detail for a single meal, by TheMealDB id."""
    payload, origin = call("lookup.php", {"i": source_id}, key=key)
    records = payload.get("meals") or []
    if not records:
        raise ApiError(f"meal {source_id} not found")
    return normalise_meal(records[0]), origin


def test_connection(key=DEV_KEY):
    """Ping the service and report what happened. Used by the status screen."""
    started = time.time()
    try:
        payload, origin = call("categories.php", {}, key=key, use_cache=False)
        count = len(payload.get("categories") or [])
        return {"ok": True, "ms": int((time.time() - started) * 1000),
                "detail": f"{count} categories returned", "origin": origin}
    except ApiError as exc:
        return {"ok": False, "ms": int((time.time() - started) * 1000),
                "detail": str(exc), "origin": "none"}
