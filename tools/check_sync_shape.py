"""Does every field the server sends have somewhere to land on the device?

    python tools/check_sync_shape.py nutriapp/lib/db.dart

The server and the phone keep the same three tables -- entries, weights,
profile -- but not the same columns. The server stores every account's rows,
so each one carries a `user_id`; the phone holds exactly one account, so its
tables have no such column. The server also adds `server_seq`, its own cursor.

Hand sqflite a map containing a column the table does not have and it throws
"no column named user_id". `Api.sync()` catches everything and reports it as
a network failure, on the reasoning that being offline is the normal case for
a food diary -- so this particular exception reached the user as "you appear
to be offline" and pulling from the server never worked at all. It stayed
invisible for weeks because nothing pulled: every device had created its own
data locally. The first device that needed a pull was one that had just been
cleared by signing out.

So this script drives the real server, reads the real payloads, parses the
real CREATE TABLE statements out of db.dart, and checks that every key is
either a column on the device or one the client is known to drop.
"""

import re
import sys
from pathlib import Path

# Keys the client deliberately leaves behind, with why.
DROPPED = {
    "user_id": "the device holds one account, so its rows need no owner",
    "server_seq": "the server's cursor, tracked separately in `meta`",
}

failures = []
checks = 0


def check(label, ok, detail=""):
    global checks
    checks += 1
    if not ok:
        failures.append(f"{label}{': ' + detail if detail else ''}")


def local_columns(dart_source):
    """Column names per table, from the CREATE TABLE statements in db.dart."""
    tables = {}
    pattern = r"CREATE TABLE (?:IF NOT EXISTS )?(\w+) \((.*?)\n\s*\)"
    for match in re.finditer(pattern, dart_source, re.S):
        name, body = match.group(1), match.group(2)
        columns = []
        for line in body.splitlines():
            line = line.strip().rstrip(",")
            if (not line or line.startswith("--")
                    or line.upper().startswith(
                        ("PRIMARY", "FOREIGN", "UNIQUE", "CHECK"))):
                continue
            columns.append(line.split()[0])
        tables[name] = set(columns)
    return tables


def server_payloads():
    """What /sync actually returns, from the real Flask app."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))
    import database
    import app as flaskapp

    database.init(force=True)
    flaskapp.app.config["TESTING"] = True
    client = flaskapp.app.test_client()

    token = client.post("/api/register", json={
        "email": "shapecheck@test.com",
        "password": "testpass123",
        "name": "Shape",
    }).get_json()["token"]
    headers = {"Authorization": f"Bearer {token}"}

    entry = {
        "id": "aaaa1111-0000-4000-8000-000000000001",
        "food_id": "F05100112", "food_name": "Roasted chicken rice",
        "quantity": 1.0, "serving": "1 plate(s) = 363g", "kcal": 643,
        "carbs_g": 84.11, "protein_g": 29.67, "fat_g": 20.94,
        "category": "lunch", "tags": "", "note": "",
        "eaten_at": "2026-11-10T12:30:00", "source": "manual",
        "deleted": 0, "updated_at": "2026-11-10T12:31:00Z",
    }
    weight = {
        "id": "bbbb2222-0000-4000-8000-000000000001", "kg": 66.0,
        "recorded_at": "2026-11-10", "deleted": 0,
        "updated_at": "2026-11-10T12:31:00Z",
    }
    custom_food = {
        "id": "cccc3333-0000-4000-8000-000000000001", "name": "Ah Ma laksa",
        "serving": "1 bowl", "kcal": 640, "carbs_g": 58.2, "protein_g": 22.1,
        "fat_g": 31.4, "deleted": 0, "updated_at": "2026-11-10T12:31:00Z",
    }
    profile = {
        "name": "Shape", "email": "shapecheck@test.com", "age": 20,
        "gender": "female", "height_cm": 180.0, "weight_kg": 66.0,
        "activity_level": "moderately_active", "goal": "gain_weight",
        "target_weight_kg": None, "preferences": "", "restrictions": "",
        "allergens": "", "diet_types": "", "diet_type": "",
        "computed_target_kcal": 2760, "target_kcal": 2760,
        "target_is_manual": 0, "updated_at": "2026-11-10T08:00:00Z",
    }
    client.post("/sync", headers=headers, json={
        "since": 0, "changes": [entry], "weights": [weight],
        "custom_foods": [custom_food], "profile": profile})

    # Pull as a device that knows nothing -- the sign-out/sign-in case.
    body = client.post("/sync", headers=headers, json={
        "since": 0, "changes": [], "weights": [], "custom_foods": [],
        "profile": None}).get_json()

    foods = body.get("custom_foods") or []
    return {
        "entries": body["changes"][0] if body.get("changes") else None,
        "weights": body["weights"][0] if body.get("weights") else None,
        "custom_foods": foods[0] if foods else None,
        "profile": body.get("profile"),
    }


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1

    dart = Path(sys.argv[1])
    tables = local_columns(dart.read_text(encoding="utf-8"))
    payloads = server_payloads()

    print(f"Local tables parsed from {dart.name}: "
          f"{', '.join(f'{t} ({len(c)})' for t, c in sorted(tables.items()))}")
    print()

    for table in ("entries", "weights", "custom_foods", "profile"):
        payload = payloads[table]
        check(f"the server returns a {table} row on a from-scratch pull",
              payload is not None)
        if payload is None:
            continue

        columns = tables.get(table)
        check(f"db.dart declares a local `{table}` table", bool(columns))
        if not columns:
            continue

        homeless = sorted(set(payload) - columns - set(DROPPED))
        check(f"every {table} field the server sends has a local column",
              not homeless,
              f"no column for {homeless} -- either add them to the local "
              f"table or add them to DROPPED with a reason")

        # The client must actually be dropping the ones it means to drop.
        for key in DROPPED:
            if key in payload:
                check(f"`{key}` is absent from the local {table} table",
                      key not in columns,
                      "it is in DROPPED, so the client strips it, which "
                      "would leave this column permanently empty")

        print(f"  {table}: server sends {len(payload)} fields, "
              f"device stores {len(columns)}, "
              f"dropped {sorted(set(payload) & set(DROPPED))}")

    # The filtering has to be in db.dart, not a comment about it.
    source = dart.read_text(encoding="utf-8")
    check("db.dart filters incoming rows against the real table columns",
          "PRAGMA table_info" in source and "_localRow(" in source,
          "applyRemote/applyRemoteWeight/applyRemoteProfile must build their "
          "row with _localRow, or an unknown key throws and sync reports it "
          "as a network failure")
    for fn in ("applyRemote", "applyRemoteWeight", "applyRemoteCustomFood",
               "applyRemoteProfile"):
        marker = f"Future<void> {fn}("
        if marker not in source:
            check(f"{fn} exists in db.dart", False,
                  "the server sends this collection, so something has to "
                  "apply it locally")
            continue
        body = source[source.index(marker):]
        body = body[:body.index("\n  }")]
        check(f"{fn} builds its row with _localRow",
              "_localRow(" in body,
              "it copies the server's map straight into insert()")

    print()
    print(f"{checks} checks")
    if failures:
        print(f"\n{len(failures)} problem(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
