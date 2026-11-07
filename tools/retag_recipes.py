"""Re-derive allergens and diet_types for the local seed recipes.

Two problems this fixes, both of which made a user's stated restrictions less
protective offline than online.

Diet types: the offline recipes were tagged by hand before pescatarian and
halal existed. Choosing either preference would have filtered the offline pool
to nothing, which recommend() then papers over by falling back to everything
safe -- so the preference would be silently ignored whenever the app was
offline.

Allergens: six of the hand-written rows understated theirs. A stir-fry with
soy sauce was tagged soy but not gluten, though soy sauce contains wheat and
ALLERGEN_KEYWORDS has always known that. Someone avoiding gluten would have
been shown it.

Both are fixed by running the rows through the same derivation the API path
uses, so one rule tags both pools. The merge is a union in each case. Hand tags
are kept because the derivation cannot work out "high-fibre" from an ingredient
list; declared allergens are kept because an ingredient list can be incomplete,
and dropping a declared allergen is the one change here that could do harm.

Run from the repository root:
    python tools/retag_recipes.py backend/database.py
"""

import ast
import re
import sys
from pathlib import Path


def ingredient_names(pipe_joined):
    """Ingredient names without their measures.

    The seed format is "Salmon fillet 150 g", measure last; the keyword match
    only needs the words, and leaving the numbers in does no harm, so the
    string is passed through whole.
    """
    return [part.strip() for part in pipe_joined.split("|") if part.strip()]


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1

    target = Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(target.parent))
    import recipes_api  # noqa: E402  - needs the path set first

    source = target.read_text(encoding="utf-8")
    tree = ast.parse(source)

    node = None
    for statement in tree.body:
        if (isinstance(statement, ast.Assign)
                and any(getattr(t, "id", None) == "RECIPES"
                        for t in statement.targets)):
            node = statement
            break
    if node is None:
        print("No RECIPES assignment found in", target)
        return 1

    recipes = ast.literal_eval(node.value)

    lines = []
    changed = 0
    for row in recipes:
        (name, kcal, carbs, protein, fat, minutes, allergens, diets,
         ingredients) = row

        names = ingredient_names(ingredients)

        stated_allergens = {a for a in allergens.split(",") if a}
        merged_allergens = sorted(
            stated_allergens | set(recipes_api.derive_allergens(names)))

        existing = {d for d in diets.split(",") if d}
        derived = set(recipes_api.derive_diet_types(
            names,
            category="Vegan" if "vegan" in existing
            else ("Vegetarian" if "vegetarian" in existing else ""),
            protein_g=protein,
        ))
        merged_diets = set(existing | derived)

        # A hand tag can be wrong in the other direction too: one recipe was
        # marked vegan while listing egg noodles. The union above would keep
        # that, so a contradicted claim is removed here. Dropping a diet tag is
        # safe in a way dropping an allergen is not -- it narrows what the app
        # claims rather than what it warns about.
        animal = set(merged_allergens) & {"egg", "milk", "fish", "shellfish"}
        has_meat = recipes_api._mentions(
            names, recipes_api.MEAT_KEYWORDS,
            recipes_api.DIET_FALSE_POSITIVES["meat"])

        if animal or has_meat:
            merged_diets.discard("vegan")
        if {"fish", "shellfish"} & set(merged_allergens) or has_meat:
            merged_diets.discard("vegetarian")
            merged_diets.discard("vegan")
        if has_meat:
            merged_diets.discard("pescatarian")

        merged_diets = sorted(merged_diets)

        if (merged_diets != sorted(existing)
                or merged_allergens != sorted(stated_allergens)):
            changed += 1

        lines.append(
            "    ({!r}, {!r}, {!r}, {!r}, {!r}, {!r}, {!r}, {!r},\n"
            "     {!r}),".format(name, kcal, carbs, protein, fat, minutes,
                                 ",".join(merged_allergens),
                                 ",".join(merged_diets), ingredients))

    block = "RECIPES = [\n" + "\n".join(lines) + "\n]"

    # ast gives 1-based inclusive line numbers; slice the original source so
    # every other line in the file is left exactly as it was.
    all_lines = source.splitlines(keepends=True)
    before = "".join(all_lines[:node.lineno - 1])
    after = "".join(all_lines[node.end_lineno:])
    target.write_text(before + block + "\n" + after, encoding="utf-8")

    print(f"Retagged {changed} of {len(recipes)} recipes in {target.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
