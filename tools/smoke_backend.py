"""Exercise every route end to end, on SQLite and on Postgres.

Uses Flask's test client, so it needs no port. The external recipe service is
unreachable from a sandbox, so the offline fallback is what gets covered --
which is the path that has to work anyway.

The checks that matter most are the last group: that one account cannot see,
change or delete another's data. Everything per-person is scoped by `user_id`,
and a scoping mistake is both easy to make and silent, so it is asserted from
the outside rather than trusted.

Run from the repository root:
    python tools/smoke_backend.py
    DATABASE_URL="postgresql://..." python tools/smoke_backend.py
"""

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

os.environ["NUTRIAPP_API"] = "off"        # force the offline recipe path
os.environ.setdefault("SECRET_KEY", "smoke-test-key")

import db as dbmod  # noqa: E402

TMPDIR = tempfile.mkdtemp(prefix="nutriapp-smoke-")
if not dbmod.is_postgres():
    dbmod.SQLITE_PATH = os.path.join(TMPDIR, "module.db")

import database  # noqa: E402
import app as flask_app  # noqa: E402

FOODS_DB = ROOT / "backend" / "foods.db"

failures = []
checks = 0


def check(label, condition, detail=""):
    global checks
    checks += 1
    if condition:
        print(f"  ok    {label}")
    else:
        failures.append(f"{label}{(' - ' + detail) if detail else ''}")
        print(f"  FAIL  {label} {detail}")


def main():
    engine = "Postgres" if dbmod.is_postgres() else "SQLite"
    print(f"\n=== Smoke test against {engine} ===\n")

    database.init(force=True)
    _load_foods()

    flask_app.app.config["TESTING"] = True

    print("Nothing is reachable without an account")
    anon = flask_app.app.test_client()
    for path in ("/", "/diary", "/discover", "/insights", "/profile", "/add"):
        response = anon.get(path)
        check(f"GET {path} redirects to sign-in",
              response.status_code == 302
              and "/login" in response.headers.get("Location", ""),
              f"{response.status_code} {response.headers.get('Location','')}")
    check("GET /login is public", anon.get("/login").status_code == 200)
    check("GET /register is public", anon.get("/register").status_code == 200)
    check("the API refuses without a token",
          anon.post("/sync", json={"since": 0}).status_code == 401)
    check("/api/ping stays public", anon.get("/api/ping").status_code == 200)

    print("\nRegistration rejects what it should")
    response = anon.post("/api/register", json={
        "email": "not-an-email", "password": "short", "name": ""})
    check("bad registration is a 400", response.status_code == 400,
          str(response.status_code))
    problems = (response.get_json() or {}).get("problems", [])
    check("all three problems are reported", len(problems) == 3, str(problems))

    print("\nRegistering through the API")
    response = anon.post("/api/register", json={
        "email": "Wei.Ling@Example.com", "password": "correct horse battery",
        "name": "Wei Ling"})
    check("registration succeeds", response.status_code == 201,
          str(response.status_code))
    payload = response.get_json()
    token = payload["token"]
    check("a token comes back", bool(token))
    check("the email was lowercased",
          payload["user"]["email"] == "wei.ling@example.com",
          payload["user"]["email"])
    check("the password hash is never serialised",
          "password_hash" not in payload["user"], str(payload["user"].keys()))

    response = anon.post("/api/register", json={
        "email": "wei.ling@example.com", "password": "another password",
        "name": "Imposter"})
    check("a duplicate email is refused", response.status_code == 400)

    print("\nSigning in")
    check("the wrong password is refused",
          anon.post("/api/login", json={"email": "wei.ling@example.com",
                                        "password": "wrong"}).status_code == 401)
    check("an unknown email is refused",
          anon.post("/api/login", json={"email": "nobody@example.com",
                                        "password": "whatever"}).status_code == 401)
    response = anon.post("/api/login", json={"email": "wei.ling@example.com",
                                             "password": "correct horse battery"})
    check("the right password signs in", response.status_code == 200)
    token = response.get_json()["token"]

    auth = {"Authorization": f"Bearer {token}"}
    check("a token identifies the user",
          anon.get("/api/me", headers=auth).get_json()["user"]["name"] == "Wei Ling")
    check("setup is not done yet",
          anon.get("/api/me", headers=auth).get_json()["has_profile"] is False)
    check("a made-up token is refused",
          anon.get("/api/me",
                   headers={"Authorization": "Bearer nonsense"}).status_code == 401)

    print("\nThe web prototype, as a signed-in browser")
    web = flask_app.app.test_client()
    response = web.post("/register", data={
        "email": "browser@example.com", "password": "another good password",
        "name": "Browser User"}, follow_redirects=True)
    check("browser registration lands on setup", response.status_code == 200)

    response = web.post("/profile/setup", data={
        "name": "Browser User", "age": "23", "gender": "Female",
        "height_cm": "163", "weight_kg": "58",
        "activity_level": "Lightly Active", "goal": "Lose Weight",
        "target_weight_kg": "54", "preferences": ["Pescatarian"],
        "restrictions": ["Dairy", "Peanuts"]}, follow_redirects=True)
    check("profile setup accepted", response.status_code == 200)

    for path in ("/", "/diary", "/discover", "/insights", "/profile", "/add",
                 "/insights?days=30", "/api-status"):
        check(f"GET {path}", web.get(path).status_code == 200)

    body = web.get("/discover").get_data(as_text=True)
    check("discover names the user's own restrictions", "Dairy" in body)

    print("\nThe food table is the HPB dataset")
    conn = database.connect()
    total = conn.execute("SELECT COUNT(*) c FROM foods").fetchone()["c"]
    milk = database.food_dict(database.food_by_id(conn, "F01030005"))
    conn.close()
    check("2,692 foods loaded", total == 2692, str(total))
    check("milk's contradictory trans fat is hidden",
          milk["trans_fat_g"] is None, str(milk["trans_fat_g"]))
    check("milk's other figures survive", milk["energy_kcal"] == 150.0,
          str(milk["energy_kcal"]))

    body = web.get("/add?q=chicken+rice").get_data(as_text=True)
    check("food search finds chicken rice", "chicken rice" in body.lower())

    print("\nLogging a food through the browser")
    response = web.post("/add", data={
        "food_id": "F05020050", "quantity": "1", "eaten_at": "",
        "category": "lunch", "note": "smoke test"}, follow_redirects=True)
    check("food logged", response.status_code == 200)
    check("the entry belongs to the browser user", _entry_count() == 1,
          str(_entry_count()))

    response = web.post("/profile/weight", data={"kg": "56"},
                        follow_redirects=True)
    check("weight logged", response.status_code == 200)

    print("\nSync is scoped to the token's user")
    response = anon.post("/sync", headers=auth,
                         json={"since": 0, "changes": [], "weights": [],
                               "profile": None})
    check("sync with a token works", response.status_code == 200)
    payload = response.get_json()
    check("the API user sees none of the browser user's entries",
          payload["changes"] == [], str(payload["changes"]))
    check("nor their weights", payload["weights"] == [], str(payload["weights"]))
    check("nor their profile", payload["profile"] is None)

    pushed = {
        "id": "api-entry-1", "food_name": "Pushed from the app", "kcal": 400,
        "carbs_g": 40.0, "protein_g": 20.0, "fat_g": 12.0, "category": "dinner",
        "eaten_at": "2026-11-02T19:00:00", "updated_at": "2026-11-02T11:00:00+00:00",
        "quantity": 1, "serving": "1 plate", "tags": "", "note": "",
        "source": "manual", "deleted": 0,
    }
    response = anon.post("/sync", headers=auth,
                         json={"since": 0, "changes": [pushed]})
    payload = response.get_json()
    check("the push applied", payload["push"]["applied"] == 1,
          str(payload["push"]))
    check("it comes back on the same pull", len(payload["changes"]) == 1)
    check("the server stamped the owner",
          payload["changes"][0].get("user_id") is not None)

    print("\nOne account cannot reach another's data")
    other = anon.post("/api/register", json={
        "email": "third@example.com", "password": "yet another password",
        "name": "Third"}).get_json()
    other_auth = {"Authorization": f"Bearer {other['token']}"}

    payload = anon.post("/sync", headers=other_auth,
                        json={"since": 0}).get_json()
    check("a third account's pull is empty", payload["changes"] == [],
          str(payload["changes"]))

    # The dangerous case: a client that knows another account's entry id and
    # pushes an edit for it. The server must treat that as its own new row,
    # not as an update to someone else's.
    hijack = dict(pushed)
    hijack["food_name"] = "Hijacked"
    hijack["updated_at"] = "2026-11-02T23:00:00+00:00"
    anon.post("/sync", headers=other_auth, json={"since": 0, "changes": [hijack]})

    conn = database.connect()
    rows = conn.execute(
        "SELECT user_id, food_name FROM entries WHERE id=?",
        ("api-entry-1",)).fetchall()
    conn.close()
    # Same primary key, so the second push collides. What must not happen is
    # the first user's row being rewritten with the second user's content.
    victim = [r for r in rows if r["food_name"] == "Hijacked"]
    check("a cross-account push does not rewrite the original",
          not victim or len(rows) > 1,
          f"rows for that id: {[dict(r) for r in rows]}")

    body = web.get("/profile").get_data(as_text=True)
    check("the browser user's profile still shows their own name",
          "Browser User" in body)
    check("and not another account's", "Wei Ling" not in body)

    print("\nSigning out")
    check("logout clears the session",
          web.get("/logout").status_code == 302)
    check("and the pages are protected again",
          web.get("/").status_code == 302)
    check("api logout revokes the token",
          anon.post("/api/logout", headers=auth).status_code == 200)
    check("the revoked token no longer works",
          anon.get("/api/me", headers=auth).status_code == 401)

    print(f"\n{checks - len(failures)}/{checks} checks passed on {engine}")
    if failures:
        print("\nFailures:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    return 0


def _load_foods():
    """Copy the imported food table in, so search has something to find."""
    import sqlite3
    if not FOODS_DB.exists():
        print(f"  (no {FOODS_DB}; run tools/import_hpb_foods.py first)")
        return
    source = sqlite3.connect(f"file:{FOODS_DB}?mode=ro", uri=True)
    source.row_factory = sqlite3.Row
    rows = source.execute("SELECT * FROM foods").fetchall()
    source.close()

    columns = [c for c in rows[0].keys()]
    conn = database.connect()
    conn.execute("DELETE FROM foods")
    conn.executemany(
        f"INSERT INTO foods ({','.join(columns)}) "
        f"VALUES ({','.join('?' for _ in columns)})",
        [[r[c] for c in columns] for r in rows])
    conn.commit()
    conn.close()


def _entry_count():
    conn = database.connect()
    n = conn.execute("SELECT COUNT(*) c FROM entries WHERE deleted=0").fetchone()["c"]
    conn.close()
    return n


if __name__ == "__main__":
    raise SystemExit(main())
