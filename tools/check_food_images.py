"""Does every food group have a picture, and every picture a group?

    python tools/check_food_images.py nutriapp/assets/foods.db nutriapp/assets/food_groups

`Food.imageAsset` derives a filename from the food's group rather than
looking it up in a table, so adding a group to the dataset needs only a file
with the matching name -- and forgetting that file is silent. `Image.asset`
throws at paint time when a file is missing, which takes out whichever screen
happens to be showing that food. `FoodImage` catches it and draws a
placeholder so the app survives, which is the right behaviour and also means
nobody notices until a demonstration.

So the check is run here instead: slugify every group in the shipped
database the same way the Dart does, and compare against the files on disk.
It reports missing images and orphaned files, and is quiet when they match.

An empty directory is not a failure. The images are expected to arrive after
the code that uses them, and the placeholder path is deliberate.
"""

import re
import sqlite3
import sys
from pathlib import Path

FALLBACK = "fallback"


def slugify(group):
    """The same transformation as Food.imageAsset in models.dart."""
    slug = re.sub(r"[^a-z0-9]+", "-", group.lower())
    return re.sub(r"^-+|-+$", "", slug)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1

    db_path, images = Path(sys.argv[1]), Path(sys.argv[2])
    if not db_path.exists():
        print(f"missing {db_path}")
        return 1

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    groups = {}
    for group, count in conn.execute(
            "SELECT food_group, COUNT(*) FROM foods "
            "WHERE food_group IS NOT NULL AND TRIM(food_group) <> '' "
            "GROUP BY food_group ORDER BY COUNT(*) DESC"):
        groups[slugify(group)] = (group, count)

    ungrouped = conn.execute(
        "SELECT COUNT(*) FROM foods "
        "WHERE food_group IS NULL OR TRIM(food_group) = ''").fetchone()[0]

    present = ({p.stem for p in images.glob("*.webp")}
               if images.is_dir() else set())

    print(f"{len(groups)} food groups in {db_path.name}, "
          f"{len(present)} images in {images}\n")

    missing = []
    for slug, (name, count) in groups.items():
        mark = "ok     " if slug in present else "MISSING"
        if slug not in present:
            missing.append(slug)
        print(f"  {mark} {slug + '.webp':40} {count:5} foods   {name}")

    if ungrouped:
        mark = "ok     " if FALLBACK in present else "MISSING"
        if FALLBACK not in present:
            missing.append(FALLBACK)
        print(f"  {mark} {FALLBACK + '.webp':40} {ungrouped:5} foods   "
              f"(no group recorded)")
    elif FALLBACK not in present:
        missing.append(FALLBACK)
        print(f"  MISSING {FALLBACK + '.webp':40}       "
              f"used when a future dataset adds a group")

    orphans = sorted(present - set(groups) - {FALLBACK})
    for slug in orphans:
        print(f"  EXTRA   {slug + '.webp':40}       "
              f"no food group matches this name")

    print()
    if not present:
        print(f"No images yet. {len(groups) + 1} to make, 1200x675 WebP, "
              f"named exactly as listed above.")
        print("The app runs without them -- FoodImage draws a placeholder.")
        return 0

    if missing or orphans:
        print(f"{len(missing)} missing, {len(orphans)} orphaned.")
        if orphans:
            print("An orphan is usually a typo in the filename: the slug has "
                  "to match the group exactly, lowercased with every run of "
                  "non-alphanumeric characters turned into one hyphen.")
        return 1

    print("Every group has an image and every image has a group.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
