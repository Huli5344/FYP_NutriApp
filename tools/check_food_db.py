"""Run the app's own food queries against the database the app ships.

    python tools/check_food_db.py nutriapp/assets/foods.db nutriapp/lib/food_db.dart

The SQL in food_db.dart is a string. `flutter analyze` does not look inside
it, the Dart type system does not look inside it, and a misspelt column shows
up as an empty search box on a phone. So the queries are lifted out of the
Dart source and run here against the file that is actually bundled -- which
also means a column renamed in the import script fails the check instead of
failing in somebody's hand.

Lifting rather than retyping is the point. A copy of the SQL kept here would
drift from the app within a week and then prove nothing.
"""

import re
import sqlite3
import sys
from pathlib import Path

failures = []
checks = 0


def check(label, condition, detail=""):
    global checks
    checks += 1
    if not condition:
        failures.append(f"{label}{': ' + detail if detail else ''}")


def extract(dart, pattern, what, raw=False):
    """Pull one fragment out of the Dart source.

    With raw=True the matched text comes back untouched, for a fragment that
    is code rather than a string -- the chain of .replaceAll calls, say.
    """
    match = re.search(pattern, dart, re.DOTALL)
    if not match:
        failures.append(f"could not find {what} in food_db.dart")
        return None
    if raw:
        return match.group(1)
    # Dart adjacent string literals concatenate; join them the same way.
    # Both quote styles appear, because a fragment containing a single quote
    # is written with double quotes.
    parts = re.findall(r"'([^']*)'|\"([^\"]*)\"", match.group(1))
    joined = "".join(a or b for a, b in parts)
    # Dart turns \\ into one backslash before SQLite ever sees it.
    return joined.replace("\\\\", "\\")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1

    db_path = Path(sys.argv[1])
    dart_path = Path(sys.argv[2])
    if not db_path.exists():
        print(f"missing {db_path} -- the asset is not in place")
        return 1

    dart = dart_path.read_text(encoding="utf-8")

    # ---------------------------------------------------------------- lift SQL
    list_columns = extract(
        dart, r"_listColumns\s*=\s*(.*?);", "the _listColumns list")
    empty_sql = extract(
        dart,
        r"if \(text\.isEmpty\) \{.*?db\.rawQuery\(\s*(.*?),\s*\[limit\]",
        "the empty-query search")
    search_sql = extract(
        dart,
        r"final rows = await db\.rawQuery\(\s*('SELECT \$_listColumns FROM foods '.*?),\s*\['%\$pattern%'",
        "the search query")
    escape_dart = extract(
        dart, r"static String _escapeLike\(String text\) => text\s*(.*?);",
        "the LIKE escaping", raw=True)
    by_id_sql = extract(
        dart,
        r"byId\(String foodId\).*?rawQuery\(\s*(.*?),\s*\[foodId\]",
        "the byId query")
    if failures:
        for failure in failures:
            print(f"  - {failure}")
        return 1

    # The Dart interpolates $_listColumns and binds ? parameters; do the same.
    empty_sql = empty_sql.replace("$_listColumns", list_columns)
    search_sql = search_sql.replace("$_listColumns", list_columns)
    by_id_sql = by_id_sql.replace("$_listColumns", list_columns)

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    # ------------------------------------------------------- the columns exist
    stored = {row[1] for row in conn.execute("PRAGMA table_info(foods)")}
    wanted = [c.strip() for c in list_columns.split(",") if c.strip()]
    missing = [c for c in wanted if c not in stored]
    check("every column _listColumns selects exists", not missing,
          f"missing {missing}")

    # --------------------------------------------------------- the empty query
    rows = conn.execute(empty_sql, [30]).fetchall()
    check("an empty search returns a starter list", len(rows) == 30,
          f"got {len(rows)}")
    names = [r["name"] for r in rows]
    check("the starter list is in name order", names == sorted(names))

    # -------------------------------------------------------- the real search
    # The escape pairs are read out of the Dart too: a list of
    # .replaceAll(a, b) calls, applied in the order they are written.
    pairs = re.findall(r"\.replaceAll\(r?'([^']*)',\s*r?'([^']*)'\)",
                       escape_dart or "")
    check("the LIKE escaping was found in the Dart", len(pairs) == 3,
          f"found {pairs}")

    def escape_like(text):
        for find, replace in pairs:
            text = text.replace(find, replace)
        return text

    def search(text, limit=30):
        pattern = escape_like(text)
        return conn.execute(
            search_sql, [f"%{pattern}%", f"{pattern}%", limit]).fetchall()

    hits = search("chicken rice")
    check("'chicken rice' finds something", len(hits) > 0)
    check("every hit actually contains the query",
          all("chicken rice" in r["name"].lower() for r in hits))

    hits = search("rice")
    check("'rice' fills the result list", len(hits) == 30, f"got {len(hits)}")

    # The CASE in the ORDER BY is the whole point of the query: a name that
    # begins with the query must come before one that merely contains it.
    #
    # Stated as "the foods whose names start with 'rice' are exactly the first
    # seven results", with the seven counted from the database rather than
    # written down here. The obvious version of this check -- scan the results
    # and assert no prefix match appears after a substring match -- passes an
    # inverted ORDER BY, because inverting it pushes every prefix match past
    # the limit and leaves nothing to be out of order. It did pass one.
    expected = [r["food_id"] for r in conn.execute(
        "SELECT food_id FROM foods WHERE lower(name) LIKE 'rice%' "
        "ORDER BY name")]
    check("there are prefix matches and substring matches to tell apart",
          0 < len(expected) < 30, f"{len(expected)} prefix matches")
    check("prefix matches come first, all of them, in name order",
          [r["food_id"] for r in hits[:len(expected)]] == expected,
          f"first {len(expected)} were "
          f"{[r['name'] for r in hits[:len(expected)]]}")
    check("the results after them are substring matches",
          all(not r["name"].lower().startswith("rice")
              for r in hits[len(expected):]))

    check("search is case insensitive",
          [r["food_id"] for r in search("TEH")] ==
          [r["food_id"] for r in search("teh")])

    check("a query with no match returns nothing, rather than everything",
          search("qqzzx") == [])

    # A user typing a space, or a stray % or _, must not turn into a wildcard
    # that matches the whole table.
    check("an underscore is a literal underscore, not a wildcard",
          len(search("chicken_rice")) == 0,
          "LIKE treats _ as any single character, so this matched "
          "'chicken rice' before the ESCAPE clause was added")
    check("a percent sign is a literal percent sign",
          len(search("%")) == 0)
    check("a backslash does not break the query",
          len(search(r"back\slash")) == 0)

    # ------------------------------------------------------------------ byId
    row = conn.execute(by_id_sql, ["F05100112"]).fetchone()
    check("byId finds a known food", row is not None)
    if row:
        check("byId returns the right food", row["name"] == "Roasted chicken rice",
              row["name"])
    check("byId on a missing id returns nothing",
          conn.execute(by_id_sql, ["NOPE"]).fetchone() is None)

    # ------------------------------------------------- what the model relies on
    total = conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0]
    check("all 2,692 HPB foods are present", total == 2692, f"got {total}")

    nulls = conn.execute(
        "SELECT COUNT(*) FROM foods WHERE energy_kcal IS NULL").fetchone()[0]
    check("every food has an energy figure", nulls == 0,
          f"{nulls} rows without one")

    blanks = conn.execute(
        "SELECT COUNT(*) FROM foods WHERE serving_label IS NULL "
        "OR serving_label = ''").fetchone()[0]
    check("every food has a serving label to show", blanks == 0,
          f"{blanks} rows without one")

    # Food.fromRow reads bulk_serving as a number and compares it to zero.
    odd = conn.execute(
        "SELECT COUNT(*) FROM foods WHERE bulk_serving NOT IN (0, 1)"
    ).fetchone()[0]
    check("bulk_serving is always 0 or 1", odd == 0)

    bulky = conn.execute(
        "SELECT COUNT(*) FROM foods WHERE bulk_serving = 1").fetchone()[0]
    check("some foods are flagged as bulk servings", bulky > 0)

    # FoodDb.detail nulls out `<name>` and `per100_<name>` for each suppressed
    # nutrient, so every name in that column must be a real column, twice.
    suppressed = set()
    for (value,) in conn.execute(
            "SELECT DISTINCT suppress_nutrients FROM foods "
            "WHERE suppress_nutrients <> ''"):
        suppressed.update(n for n in value.split(",") if n)
    unknown = [n for n in suppressed if n not in stored]
    check("every suppressed nutrient names a real column", not unknown,
          f"unknown: {unknown}")
    no_twin = [n for n in suppressed if f"per100_{n}" not in stored]
    check("every suppressed nutrient has a per100_ twin to null out too",
          not no_twin, f"no twin: {no_twin}")

    # An index, or every keystroke scans 2,692 rows on a phone.
    indexes = {row[0] for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'index'")}
    check("the name column is indexed", any("name" in i for i in indexes),
          f"indexes: {sorted(indexes)}")

    print(f"{checks} checks against {db_path.name} "
          f"({total} foods, {db_path.stat().st_size // 1024} KB)\n")
    print("Queries lifted from food_db.dart and run as written:")
    for label, sql in (("empty search", empty_sql), ("search", search_sql),
                       ("byId", by_id_sql)):
        print(f"  {label}: {sql[:72]}{'...' if len(sql) > 72 else ''}")

    print()
    if failures:
        print(f"{len(failures)} problem(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
