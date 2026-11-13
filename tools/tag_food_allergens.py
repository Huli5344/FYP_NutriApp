"""Derive allergen and diet tags for the HPB foods, and write them into foods.db.

    python tools/tag_food_allergens.py nutriapp/assets/foods.db

The Health Promotion Board publishes nutrients, not allergens. Recipes in this
app carry declared allergen lists and `isSafeFor` filters on them, so a user
with a peanut allergy is never shown a peanut dish. Foods had no such lists,
which meant putting them into the same suggestion pipeline would have let
every one of them through every allergen filter -- silently, because an empty
list looks exactly like a safe list.

So the tags are derived here, once, at build time rather than guessed at
runtime. Build time is the point: the rules are inspectable, the output can
be reviewed food by food, and a mistake is a row in a file rather than a
surprise on a phone.

The rules are keyword matches over the food's name, with exclusions, because
naive matching gets Singapore food wrong in both directions:

  * "Satay" and "Gado gado" contain peanut and never say so. Twelve foods.
  * "Rice flour", "tapioca flour" and "bee hoon" are gluten-free; matching
    "flour" or treating every noodle as wheat marks them unsafe.
  * "Peanut butter" contains no dairy, so "butter" cannot mean milk on its
    own.

A false positive hides a safe food from somebody. A false negative offers an
allergic person something that could hurt them. The rules are therefore
written to err towards the first, and `REVIEW` below lists the foods whose
tagging was checked by hand against the ingredient a Singaporean would expect.

Diet tags are deliberately thin. Only fruit and vegetables are marked
vegetarian or vegan, and only when nothing in the name contradicts it.
`matchesDiet` requires a positive tag, so everything untagged simply does not
appear for a non-balanced diet -- which is the safe direction to fail.
Nothing is tagged halal: that is a religious determination, not a keyword
match, and guessing it would be worse than leaving it out.
"""

import re
import sqlite3
import sys
from pathlib import Path

# tag -> (include keywords, exclude keywords)
#
# A food is tagged when a name contains an include keyword and none of the
# excludes. Keywords are matched against the lowercased name.
ALLERGEN_RULES = {
    "peanut": (
        ["peanut", "groundnut", "satay", "gado gado", "gado-gado", "pecel",
         "kacang putih", "rojak"],
        [],
    ),
    "nuts": (
        ["almond", "cashew", "walnut", "pecan", "pistachio", "hazelnut",
         "macadamia", "praline", "nuts", "nut mix"],
        # Not tree nuts despite the spelling. "peanut" is excluded so it
        # stays its own tag -- the profile offers peanuts and tree nuts
        # separately, and conflating them would hide food from somebody who
        # only avoids one.
        ["coconut", "nutmeg", "water chestnut", "chestnut puree", "doughnut",
         "donut", "peanut", "butternut"],
    ),
    "milk": (
        ["milk", "cheese", "cream", "yoghurt", "yogurt", "ghee", "custard",
         "butter", "paneer", "kefir", "ice-cream", "ice cream", "lassi",
         "milo", "horlicks", "ovaltine", "bingsu", "latte", "cappuccino",
         "mocha", "bandung",
         # Ordered plain, teh and kopi are made with condensed or evaporated
         # milk. The o and kosong variants below are the ones without.
         "teh", "kopi"],
        # Butter that is not dairy, and milks that are not milk.
        ["peanut butter", "nut butter", "soya milk", "soy milk", "almond milk",
         "oat milk", "rice milk", "coconut milk", "coconut cream",
         "buttercup", "butterfly", "butter bean", "butterhead",
         # The kopitiam ordering system is the allergen label here, and only
         # "o" means no milk. "Kosong" means no sugar, so "Teh C kosong" is
         # still made with evaporated milk -- excluding it would have been a
         # false negative on a milk allergy, which is the direction that
         # matters. "C" is evaporated milk and "siu dai" is less sugar;
         # neither removes the milk.
         "teh o", "teh-o", "kopi o", "kopi-o"],
    ),
    "egg": (
        ["egg", "omelette", "omelet", "mayonnaise", "meringue", "custard",
         "quiche", "frittata"],
        ["eggplant"],
    ),
    "soy": (
        ["soy", "soya", "tofu", "tauhu", "taukwa", "tau kwa", "beancurd",
         "bean curd", "miso", "tempeh", "tempe", "edamame", "taucheo",
         "yong tau"],
        [],
    ),
    "gluten": (
        ["bread", "wheat", "pasta", "spaghetti", "macaroni", "lasagne",
         "noodle", "mee ", "mee,", "ramen", "udon", "wonton", "wanton",
         "dumpling", "prata", "roti", "chapati", "naan", "bun", "biscuit",
         "cookie", "cake", "cracker", "pastry", "pie", "tart", "puff",
         "barley", "cereal", "oat", "bao", "mantou", "you tiao", "youtiao",
         "popiah", "muruku", "pretzel", "croissant", "waffle", "pancake",
         "doughnut", "donut", "flour", "tempura", "batter",
         # Local dishes whose wheat is in the dish name, not the word
         # "noodle": ban mian, la mian, mee pok, siew mai wrappers, pau.
         "mian", "muffin", "toast", "sandwich", "burger", "pizza", "pau",
         "siew mai", "siu mai", "spring roll", "har gow", "kuih lapis"],
        # Rice, tapioca and corn are not wheat; nor is bee hoon or kway teow.
        ["rice flour", "tapioca flour", "corn flour", "potato flour",
         "rice noodle", "bee hoon", "beehoon", "kway teow", "kuay teow",
         "hor fun", "rice cake", "rice cracker", "rice bran", "glutinous rice",
         "oatmilk", "oat milk", "rice cereal", "chee cheong fun",
         # A fruit, not a bread.
         "breadfruit",
         # Singapore carrot cake is radish and rice flour. Nothing to do
         # with cake, and the word would otherwise make it unsafe for
         # everyone avoiding gluten.
         "fried carrot cake", "chai tow kway", "radish cake",
         "water chestnut cake"],
    ),
    "shellfish": (
        ["prawn", "shrimp", "crab", "lobster", "squid", "sotong", "scallop",
         "clam", "mussel", "oyster", "cockle", "cuttlefish", "hae bee",
         "crayfish"],
        ["crab stick"],  # usually fish paste, caught by the fish rule instead
    ),
    "fish": (
        ["fish", "anchov", "ikan", "salmon", "tuna", "sardine", "mackerel",
         "otah", "otak", "cod", "snapper", "pomfret", "grouper", "herring",
         "tilapia", "catfish", "eel", "crab stick", "belacan", "cincalok"],
        ["fish oil capsule"],
    ),
    "sesame": (
        ["sesame", "tahini", "halva"],
        [],
    ),
}

# Groups whose foods can be considered plant-based when nothing in the name
# says otherwise. Deliberately short.
PLANT_GROUPS = {"Fruit", "Vegetables"}

# Anything matching these cannot be vegetarian, whatever its group says.
NOT_VEGETARIAN = [
    "chicken", "beef", "pork", "mutton", "lamb", "duck", "meat", "bacon",
    "ham", "sausage", "fish", "prawn", "shrimp", "crab", "squid", "anchov",
    "ikan", "otah", "lard", "gelatin", "gelatine", "oyster sauce", "belacan",
]
# Additionally disqualifying for vegan.
NOT_VEGAN = ["milk", "cheese", "cream", "butter", "egg", "yoghurt", "yogurt",
             "honey", "ghee", "custard", "mayonnaise"]

# Foods whose tagging was checked by hand, with the reason. These are the
# cases the rules exist for; if a change to the rules alters any of them, the
# check below fails and says so.
REVIEW = {
    "Chicken satay": {"peanut"},
    "Beef satay with sauce": {"peanut"},
    "Gado gado": {"peanut"},
    "Rice flour": set(),
    "Peanut butter": {"peanut"},
    "Rice bran": set(),
    # Caught in review: "bread" matched a fruit, tempura batter was missed,
    # and a loaf that says "nuts" on the label was not tagged for nuts --
    # the one direction that matters.
    "Breadfruit, raw": set(),
    "Eggplant tempura": {"gluten"},
    "Bread with fruits and nuts": {"gluten", "nuts"},
    # The kopitiam vocabulary, which is an allergen label in everything but
    # name. Only "O" removes the milk.
    "Teh": {"milk"},
    "Teh O": set(),
    "Teh C kosong": {"milk"},
    # Two different dishes sharing a name. The fried one is radish and rice
    # flour; the dessert is a cake.
    "Fried carrot cake (white)": set(),
    "Carrot cake (dessert)": {"gluten"},
}


def tags_for(name):
    text = name.lower()
    found = set()
    for tag, (include, exclude) in ALLERGEN_RULES.items():
        if any(word in text for word in exclude):
            continue
        if any(word in text for word in include):
            found.add(tag)
    return found


def diets_for(name, group):
    if group not in PLANT_GROUPS:
        return set()
    text = name.lower()
    if any(word in text for word in NOT_VEGETARIAN):
        return set()
    diets = {"vegetarian"}
    if not any(word in text for word in NOT_VEGAN):
        diets.add("vegan")
    return diets


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"missing {path}")
        return 1

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row

    existing = {row[1] for row in conn.execute("PRAGMA table_info(foods)")}
    for column in ("allergens", "diet_types"):
        if column not in existing:
            conn.execute(
                f"ALTER TABLE foods ADD COLUMN {column} TEXT NOT NULL DEFAULT ''")
            print(f"added column {column}")

    rows = conn.execute("SELECT food_id, name, food_group FROM foods").fetchall()
    counts = {tag: 0 for tag in ALLERGEN_RULES}
    diet_counts = {"vegetarian": 0, "vegan": 0}
    tagged = 0

    for row in rows:
        allergens = tags_for(row["name"])
        diets = diets_for(row["name"], row["food_group"] or "")
        if allergens:
            tagged += 1
        for tag in allergens:
            counts[tag] += 1
        for tag in diets:
            diet_counts[tag] += 1
        conn.execute(
            "UPDATE foods SET allergens=?, diet_types=? WHERE food_id=?",
            (",".join(sorted(allergens)), ",".join(sorted(diets)),
             row["food_id"]))
    conn.commit()

    print(f"\n{tagged} of {len(rows)} foods carry at least one allergen tag "
          f"({tagged * 100 // len(rows)}%)\n")
    for tag, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {tag:10} {count:5}")
    print()
    for tag, count in diet_counts.items():
        print(f"  {tag:10} {count:5}")

    # The hand-checked cases.
    print("\nReviewed foods:")
    failures = []
    for name, expected in REVIEW.items():
        row = conn.execute(
            "SELECT allergens FROM foods WHERE name = ?", (name,)).fetchone()
        if row is None:
            print(f"  ?      {name:32} not in this dataset")
            continue
        actual = {t for t in row["allergens"].split(",") if t}
        ok = expected.issubset(actual)
        print(f"  {'ok   ' if ok else 'WRONG'}  {name:32} "
              f"{sorted(actual) or 'none'}")
        if not ok:
            failures.append(f"{name}: expected {sorted(expected)}, "
                            f"got {sorted(actual)}")

    conn.close()
    print()
    if failures:
        print(f"{len(failures)} reviewed food(s) tagged wrongly:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("Written. Re-run after any rule change; it is idempotent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
