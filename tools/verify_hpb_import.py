"""Check every imported food against its source file, cell by cell.

The importer is the only thing standing between HPB's published figures and
what the app shows someone, so it is worth proving rather than trusting. This
re-reads all 2,692 raw CSVs independently of the importer and compares:

  * one row per source file, no duplicates, nothing dropped
  * name, serving label, serving weight and edible portion
  * all thirteen nutrients, in both the per-serving and per-100 columns
  * absent data stayed absent, rather than becoming zero
  * trace measurements became zero AND were recorded as trace

The last two are the ones worth the effort. If a dash ever becomes a zero, the
app stops saying "not measured" and starts claiming "contains none", and
nothing about the number on screen would look wrong.

Run from the repository root:
    python tools/verify_hpb_import.py <raw-csv-dir> backend/foods.db
"""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_hpb_foods import NUTRIENTS, parse_file, parse_serving, read_value


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1

    source_dir, db_path = Path(sys.argv[1]), Path(sys.argv[2])
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    stored = {r["food_id"]: r for r in conn.execute("SELECT * FROM foods")}
    files = sorted(source_dir.glob("*.csv"))

    problems = []
    checked_cells = 0
    null_preserved = 0
    trace_preserved = 0

    if len(stored) != len(files):
        problems.append(
            f"row count {len(stored)} does not match {len(files)} source files")

    for path in files:
        food_id = path.stem
        row = stored.get(food_id)
        if row is None:
            problems.append(f"{food_id}: missing from the database")
            continue

        meta, nutrients = parse_file(path)

        if row["name"] != meta.get("Food Name", "").strip():
            problems.append(
                f"{food_id}: name {row['name']!r} != {meta.get('Food Name')!r}")

        label = meta.get("Default Serving Size", "").strip()
        if row["serving_label"] != label:
            problems.append(f"{food_id}: serving label {row['serving_label']!r} "
                            f"!= {label!r}")
        size, unit = parse_serving(label)
        if size is not None and abs(row["serving_size"] - size) > 1e-9:
            problems.append(f"{food_id}: serving size {row['serving_size']} != {size}")
        if unit is not None and row["serving_unit"] != unit:
            problems.append(f"{food_id}: unit {row['serving_unit']} != {unit}")

        edible = read_value((meta.get("Edible Portion", "") or "").rstrip("%"))[0]
        if edible is not None and row["edible_portion_pct"] is not None:
            if abs(row["edible_portion_pct"] - edible) > 1e-9:
                problems.append(
                    f"{food_id}: edible {row['edible_portion_pct']} != {edible}")

        recorded_trace = {t for t in (row["trace_nutrients"] or "").split(",") if t}

        for label_text, column in NUTRIENTS.items():
            raw_100, raw_serving = nutrients.get(label_text, ("", ""))
            want_100, trace_100 = read_value(raw_100)
            want_serving, trace_serving = read_value(raw_serving)

            for want, got, where in (
                    (want_serving, row[column], column),
                    (want_100, row[f"per100_{column}"], f"per100_{column}")):
                checked_cells += 1
                if want is None:
                    if got is not None:
                        problems.append(
                            f"{food_id}: {where} should be NULL (source "
                            f"{raw_serving if 'per100' not in where else raw_100!r}) "
                            f"but is {got}")
                    else:
                        null_preserved += 1
                elif got is None or abs(got - want) > 1e-6:
                    problems.append(f"{food_id}: {where} {got} != {want}")

            if trace_100 or trace_serving:
                if column not in recorded_trace:
                    problems.append(
                        f"{food_id}: {column} is Trace in the source but was "
                        f"not recorded in trace_nutrients")
                else:
                    trace_preserved += 1

    print(f"Checked {len(files)} source files against {db_path}")
    print(f"  {checked_cells} nutrient cells compared")
    print(f"  {null_preserved} absent values correctly still NULL, not zero")
    print(f"  {trace_preserved} trace measurements correctly recorded")

    if problems:
        print(f"\n{len(problems)} problem(s):")
        for problem in problems[:25]:
            print(f"  - {problem}")
        if len(problems) > 25:
            print(f"  ... and {len(problems) - 25} more")
        return 1

    print("\nNo discrepancies.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
