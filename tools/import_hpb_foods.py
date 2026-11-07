"""Import the HPB food composition data into the app's food database.

Input is the raw sgfoodid export: one CSV per food, 2,692 of them. Each file
holds key/value metadata, then a nutrient table with two columns, Per 100 and
Per Serving.

Three decisions worth stating, because they are what make the output safe to
show someone.

**Per-serving figures are taken from HPB's own column, not recomputed.** The
Per 100 column is per 100 g of *edible* portion, while the serving weight is
as-purchased and includes shell, bone and inedible parts. Multiplying the two
overstates anything with an edible portion below 100% -- 405 of these foods,
and by 8x on crayfish. HPB has already done that arithmetic correctly, so the
import reads its answer rather than repeating the mistake. `--verify` checks
the two against each other and reports any disagreement.

**"No data" and "zero" stay distinct.** A dash in the source means the
nutrient was never measured; `0` means it was measured as zero; `Trace` means
it was below the detection limit. These become NULL, 0.0, and 0.0 with the
nutrient recorded in `trace_nutrients`. Collapsing the dash to zero would have
the app claim a food contains no trans fat when nobody ever looked.

**Nothing published is altered.** Where HPB's own figures are internally
inconsistent -- full cream milk lists 68.82 g of trans fat alongside 2.89 g of
total fat, and propagates it to 172.05 g per glass -- the value is stored as
published and the nutrient is named in `suppress_nutrients`. The app hides that
one nutrient for that one food and shows everything else. Rewriting the number
to what it was probably meant to be would be inventing data.

Run from the repository root:
    python tools/import_hpb_foods.py <raw-csv-dir> backend/foods.db
    python tools/import_hpb_foods.py <raw-csv-dir> backend/foods.db --verify
"""

import csv
import os
import re
import sqlite3
import sys
from pathlib import Path

# Source label -> column name. Every file carries all thirteen.
NUTRIENTS = {
    "Energy (kcal)": "energy_kcal",
    "Protein (g)": "protein_g",
    "Total Fat (g)": "total_fat_g",
    "Saturated Fat (g)": "saturated_fat_g",
    "Trans Fat (g)": "trans_fat_g",
    "Carbohydrate (g)": "carbohydrate_g",
    "Sugar (g)": "sugar_g",
    "Added Sugar (g)": "added_sugar_g",
    "Dietary Fibre (g)": "dietary_fibre_g",
    "Sodium (mg)": "sodium_mg",
    "Potassium (mg)": "potassium_mg",
    "Calcium (mg)": "calcium_mg",
    "Iron (mg)": "iron_mg",
}

# A serving this large is a shopping quantity, not an eating occasion: a whole
# roast turkey, a whole lamb leg. Tapping one of these in a diary should not
# silently log four thousand calories, so they are flagged for the interface to
# ask about rather than having their published figures rewritten.
BULK_SERVING_KCAL = 1200

SCHEMA = """
CREATE TABLE foods (
    food_id             TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    description         TEXT,
    food_group          TEXT,
    food_subgroup       TEXT,

    -- Serving the per_* columns below describe.
    serving_label       TEXT NOT NULL,   -- "1 plate(s) = 480g", as published
    serving_size        REAL NOT NULL,   -- 480.0, as purchased
    serving_unit        TEXT NOT NULL,   -- g or ml
    alternative_serving TEXT,
    edible_portion_pct  REAL,

    -- As published by HPB. Per-serving accounts for the inedible portion;
    -- per-100 is per 100 g/ml of edible portion. They are not interconvertible
    -- without edible_portion_pct, which is why both are stored.
    energy_kcal         REAL, protein_g           REAL,
    total_fat_g         REAL, saturated_fat_g     REAL,
    trans_fat_g         REAL, carbohydrate_g      REAL,
    sugar_g             REAL, added_sugar_g       REAL,
    dietary_fibre_g     REAL, sodium_mg           REAL,
    potassium_mg        REAL, calcium_mg          REAL,
    iron_mg             REAL,

    per100_energy_kcal  REAL, per100_protein_g        REAL,
    per100_total_fat_g  REAL, per100_saturated_fat_g  REAL,
    per100_trans_fat_g  REAL, per100_carbohydrate_g   REAL,
    per100_sugar_g      REAL, per100_added_sugar_g    REAL,
    per100_dietary_fibre_g REAL, per100_sodium_mg     REAL,
    per100_potassium_mg REAL, per100_calcium_mg       REAL,
    per100_iron_mg      REAL,

    -- Nutrients measured below the detection limit, stored as 0.0. Listing
    -- them keeps "about zero" distinguishable from "exactly zero".
    trace_nutrients     TEXT DEFAULT '',
    -- Nutrients the interface must not display for this food, because the
    -- published figure is internally inconsistent.
    suppress_nutrients  TEXT DEFAULT '',
    -- Inconsistencies that are informational only; the values are shown.
    notes               TEXT DEFAULT '',
    -- 1 when the default serving is a shopping quantity, not a meal.
    bulk_serving        INTEGER NOT NULL DEFAULT 0,

    source_of_data      TEXT,
    last_updated        TEXT
);

CREATE INDEX foods_name ON foods(name);
CREATE INDEX foods_group ON foods(food_group);
CREATE INDEX foods_energy ON foods(energy_kcal);
"""


def parse_file(path):
    """One HPB CSV into (metadata, {label: (per100, per_serving)})."""
    meta, nutrients = {}, {}
    header_seen = False
    with open(path, encoding="utf-8-sig", newline="") as fh:
        for row in csv.reader(fh):
            if not row:
                continue
            first = row[0].strip()
            if not first:
                # The blank-first-cell row introduces the nutrient table.
                if len(row) >= 3 and row[1].strip().lower().startswith("per 100"):
                    header_seen = True
                continue
            if first.startswith(("Trace:", "Dash", "Per 100", "Per serving", "•")):
                continue
            if not header_seen:
                if len(row) >= 2:
                    meta[first] = row[1].strip()
            elif first in NUTRIENTS and len(row) >= 3:
                nutrients[first] = (row[1].strip(), row[2].strip())
    return meta, nutrients


def read_value(raw):
    """A published cell into (value, is_trace).

    A dash is absent data and becomes None, which must not be confused with a
    measured zero. `Trace` is a real measurement below the detection limit, so
    it becomes 0.0 and is recorded.
    """
    text = (raw or "").strip()
    if text in ("", "-", "--", "N.A.", "NA"):
        return None, False
    if text.lower().startswith("trace"):
        return 0.0, True
    try:
        return float(text.replace(",", "")), False
    except ValueError:
        return None, False


def parse_serving(label):
    """"1 plate(s) = 480g" -> (480.0, "g"). Returns (None, None) if absent."""
    match = re.search(r"=\s*([\d.]+)\s*(g|ml|kg|l)\b", label or "", re.I)
    if not match:
        return None, None
    size, unit = float(match.group(1)), match.group(2).lower()
    if unit == "kg":
        size, unit = size * 1000, "g"
    elif unit == "l":
        size, unit = size * 1000, "ml"
    return size, unit


# A fat fraction larger than the total fat it is part of is impossible, but
# most such rows are rounding on a food with almost no fat: beer reports 0.0 g
# total and 0.07 g saturated. Hiding saturated fat for beer would be absurd.
#
# The thresholds come from a visible gap in this data rather than from taste.
# Sorted by excess, every row up to 0.54 g is that kind of rounding, and the
# next is aloe vera at 5.7 g excess and 58x its total fat -- the same 5.8 g
# pasted into three unrelated vegetables. Requiring both a half-gram of excess
# and half again the total separates the two groups cleanly, and the rounding
# cases are still reported, as a note rather than a suppression.
FAT_SUPPRESS_EXCESS_G = 0.5      # per 100 g/ml
FAT_SUPPRESS_RATIO = 1.5


def check_consistency(per_100):
    """Which nutrients to hide, and which oddities only to note.

    Evaluated on the per-100 column rather than per-serving so a threshold
    means the same thing for a 9 g quail egg and a 3.8 kg turkey. Per-serving
    is a fixed multiple of per-100, so a nutrient inconsistent in one is
    inconsistent in the other.

    Hidden: a fat fraction impossibly larger than its total fat.

    Noted, and shown as published: the rounding cases above; sugar slightly
    over carbohydrate, which is ordinary on a packaged label; and energy that
    does not match the macronutrients, which happens legitimately where
    alcohol or fibre contribute.
    """
    suppress, notes = [], []

    total_fat = per_100.get("total_fat_g")
    for part in ("saturated_fat_g", "trans_fat_g"):
        value = per_100.get(part)
        if value is None or total_fat is None or value <= total_fat:
            continue
        excess = value - total_fat
        ratio = value / total_fat if total_fat > 0 else float("inf")
        if excess > FAT_SUPPRESS_EXCESS_G and ratio > FAT_SUPPRESS_RATIO:
            suppress.append(part)
        else:
            notes.append(f"{part}_rounding")

    sugar, carbs = per_100.get("sugar_g"), per_100.get("carbohydrate_g")
    if sugar is not None and carbs is not None and sugar > carbs + 0.5:
        notes.append("sugar_exceeds_carbohydrate")

    energy = per_100.get("energy_kcal")
    if energy is not None and energy > 0:
        implied = sum(
            (per_100.get(k) or 0) * kcal
            for k, kcal in (("carbohydrate_g", 4), ("protein_g", 4),
                            ("total_fat_g", 9)))
        if implied > 0 and abs(implied - energy) > max(25, energy * 0.35):
            notes.append("energy_mismatch")

    return suppress, notes


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    verify = "--verify" in sys.argv
    if len(args) != 2:
        print(__doc__)
        return 1

    source_dir, output = Path(args[0]), Path(args[1])
    files = sorted(p for p in source_dir.glob("*.csv"))
    if not files:
        print(f"No CSV files in {source_dir}")
        return 1

    if output.exists():
        output.unlink()
    conn = sqlite3.connect(output)
    conn.executescript(SCHEMA)

    imported = 0
    skipped = []
    disagreements = []
    stats = {"suppressed": 0, "trace": 0, "bulk": 0, "notes": 0,
             "no_data_cells": 0}

    for path in files:
        meta, nutrients = parse_file(path)
        name = meta.get("Food Name", "").strip()
        serving_label = meta.get("Default Serving Size", "").strip()
        size, unit = parse_serving(serving_label)

        if not name or size is None:
            skipped.append((path.name, name or "(no name)", serving_label))
            continue

        edible = read_value((meta.get("Edible Portion", "") or "").rstrip("%"))[0]

        per_serving, per_100, trace = {}, {}, []
        for label, column in NUTRIENTS.items():
            raw_100, raw_serving = nutrients.get(label, ("", ""))
            value_100, trace_100 = read_value(raw_100)
            value_serving, trace_serving = read_value(raw_serving)
            per_100[column] = value_100
            per_serving[column] = value_serving
            if trace_100 or trace_serving:
                trace.append(column)
            if value_serving is None:
                stats["no_data_cells"] += 1

        # HPB's own per-serving column is authoritative. This only reports
        # where recomputing from per-100 would have disagreed with it.
        if verify and edible is not None:
            a, b = per_100.get("energy_kcal"), per_serving.get("energy_kcal")
            if a is not None and b is not None:
                recomputed = a * size / 100.0 * edible / 100.0
                if abs(recomputed - b) > max(1.5, b * 0.02):
                    disagreements.append((name, b, round(recomputed, 1)))

        suppress, notes = check_consistency(per_100)
        bulk = (per_serving.get("energy_kcal") or 0) > BULK_SERVING_KCAL

        stats["suppressed"] += 1 if suppress else 0
        stats["trace"] += 1 if trace else 0
        stats["bulk"] += 1 if bulk else 0
        stats["notes"] += 1 if notes else 0

        row = {
            "food_id": path.stem,
            "name": name,
            "description": meta.get("Description", ""),
            "food_group": meta.get("Food Group", ""),
            "food_subgroup": meta.get("Food Subgroup", ""),
            "serving_label": serving_label,
            "serving_size": size,
            "serving_unit": unit,
            "alternative_serving": (
                meta.get("Alternative Serving Size(s)", "") or "").replace("-", "")
            if (meta.get("Alternative Serving Size(s)", "") or "").strip() == "-"
            else meta.get("Alternative Serving Size(s)", ""),
            "edible_portion_pct": edible,
            "trace_nutrients": ",".join(trace),
            "suppress_nutrients": ",".join(suppress),
            "notes": ",".join(notes),
            "bulk_serving": 1 if bulk else 0,
            "source_of_data": meta.get("Source of Data", ""),
            "last_updated": meta.get("Last Updated", ""),
        }
        row.update(per_serving)
        row.update({f"per100_{k}": v for k, v in per_100.items()})

        columns = list(row)
        conn.execute(
            f"INSERT INTO foods ({','.join(columns)}) "
            f"VALUES ({','.join('?' for _ in columns)})",
            [row[c] for c in columns])
        imported += 1

    conn.commit()

    print(f"Imported {imported} of {len(files)} foods into {output}")
    print(f"  {stats['suppressed']:>5} foods have a nutrient hidden as inconsistent")
    print(f"  {stats['notes']:>5} foods have an informational note, values shown")
    print(f"  {stats['trace']:>5} foods have at least one trace nutrient")
    print(f"  {stats['bulk']:>5} foods have a bulk default serving "
          f"(over {BULK_SERVING_KCAL} kcal)")
    print(f"  {stats['no_data_cells']:>5} nutrient cells had no data, stored as NULL")
    print(f"  {os.path.getsize(output) / 1024:.0f} KB on disk")

    if skipped:
        print(f"\n{len(skipped)} skipped:")
        for filename, name, label in skipped[:10]:
            print(f"  {filename}  {name[:40]:42} serving={label!r}")

    if verify:
        print(f"\nVerification: recomputed per-serving energy disagreed with "
              f"HPB's own column on {len(disagreements)} foods")
        for name, published, recomputed in disagreements[:10]:
            print(f"  {name[:44]:46} HPB={published} recomputed={recomputed}")

    conn.close()
    return 1 if skipped else 0


if __name__ == "__main__":
    raise SystemExit(main())
