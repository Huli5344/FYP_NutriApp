"""Load the imported food database into the app's database.

`import_hpb_foods.py` turns the raw HPB export into a standalone `foods.db`.
This copies that table into whichever database the backend is configured for --
Postgres in deployment, SQLite locally -- so the hosted database holds the food
dataset alongside the user data.

Kept separate from the importer on purpose. Parsing 2,692 source files is slow
and only has to happen when the source changes; loading the result into a
server is quick and may happen many times, against different environments.
It also means a bad load can be re-run from a known-good `foods.db` rather
than from the raw files again.

The load is a transaction: either the whole table is replaced or nothing is,
so an interrupted run cannot leave the app searching half a dataset.

Run from the repository root:
    python tools/load_foods.py backend/foods.db                  # local SQLite
    DATABASE_URL="postgresql://..." python tools/load_foods.py backend/foods.db
"""

import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import database  # noqa: E402
import db as dbmod  # noqa: E402

# Written explicitly rather than taken from the source file, so a column added
# to foods.db cannot silently fail to arrive, and so the insert order is fixed.
COLUMNS = (
    "food_id", "name", "description", "food_group", "food_subgroup",
    "serving_label", "serving_size", "serving_unit", "alternative_serving",
    "edible_portion_pct",
    "energy_kcal", "protein_g", "total_fat_g", "saturated_fat_g",
    "trans_fat_g", "carbohydrate_g", "sugar_g", "added_sugar_g",
    "dietary_fibre_g", "sodium_mg", "potassium_mg", "calcium_mg", "iron_mg",
    "per100_energy_kcal", "per100_protein_g", "per100_total_fat_g",
    "per100_saturated_fat_g", "per100_trans_fat_g", "per100_carbohydrate_g",
    "per100_sugar_g", "per100_added_sugar_g", "per100_dietary_fibre_g",
    "per100_sodium_mg", "per100_potassium_mg", "per100_calcium_mg",
    "per100_iron_mg",
    "trace_nutrients", "suppress_nutrients", "notes", "bulk_serving",
    "source_of_data", "last_updated",
)

BATCH = 500


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1

    source_path = Path(sys.argv[1])
    if not source_path.exists():
        print(f"{source_path} does not exist. Run import_hpb_foods.py first.")
        return 1

    source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
    source.row_factory = sqlite3.Row
    rows = source.execute(
        f"SELECT {','.join(COLUMNS)} FROM foods ORDER BY food_id").fetchall()
    source.close()

    target = "Postgres" if dbmod.is_postgres() else f"SQLite ({dbmod.SQLITE_PATH})"
    print(f"Loading {len(rows)} foods from {source_path.name} into {target}")

    # The schema may not exist yet on a fresh database. An older one is a
    # stop, not a traceback: the message says what to do about it.
    try:
        database.init()
    except database.SchemaOutOfDate as exc:
        print(f"\n{exc}")
        return 1

    conn = database.connect()
    try:
        before = conn.execute("SELECT COUNT(*) c FROM foods").fetchone()["c"]

        # Replace wholesale rather than upsert. A food removed from the source
        # should disappear here too, and an upsert would leave it behind
        # forever with no sign that it is stale.
        conn.execute("DELETE FROM foods")

        placeholders = ",".join("?" for _ in COLUMNS)
        statement = (f"INSERT INTO foods ({','.join(COLUMNS)}) "
                     f"VALUES ({placeholders})")
        for start in range(0, len(rows), BATCH):
            chunk = [[r[c] for c in COLUMNS] for r in rows[start:start + BATCH]]
            conn.executemany(statement, chunk)

        after = conn.execute("SELECT COUNT(*) c FROM foods").fetchone()["c"]
        if after != len(rows):
            raise RuntimeError(
                f"expected {len(rows)} rows after the load, found {after}")

        conn.commit()
    except Exception:
        conn.rollback()
        conn.close()
        raise

    # Read back through the same path the app uses, so the check covers the
    # suppression being applied rather than only the rows being present.
    conn = database.connect()
    hidden = conn.execute(
        "SELECT COUNT(*) c FROM foods WHERE suppress_nutrients != ''"
    ).fetchone()["c"]
    bulk = conn.execute(
        "SELECT COUNT(*) c FROM foods WHERE bulk_serving = 1").fetchone()["c"]
    sample = database.food_dict(
        database.food_by_id(conn, "F01030005"))        # full cream milk
    conn.close()

    print(f"  replaced {before} rows with {after}")
    print(f"  {hidden} foods have a nutrient hidden, {bulk} have a bulk serving")
    if sample:
        print(f"  spot check: {sample['name']} "
              f"{sample['energy_kcal']} kcal/serving, "
              f"trans_fat hidden = {sample['trans_fat_g'] is None}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
