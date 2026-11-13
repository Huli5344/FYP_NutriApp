"""Fill an account with a few weeks of plausible history, for testing Insights.

    python tools/seed_history.py --url https://your-service.onrender.com \\
        --email you@example.com --password yourpassword --days 28

    python tools/seed_history.py ... --clear      # remove it again

Insights only has something to show after a week or two of logging, and
waiting two weeks to find out whether a chart draws correctly is not a test
plan. This writes the history through the real `/sync` endpoint as the real
account, so the app pulls it down the way it pulls anything else -- the same
code path, the same validation, the same conflict rules. Nothing is inserted
behind the app's back, and nothing about the app changes to accommodate it.

Every row it writes is tagged, in the entry note and in the weight note, so
`--clear` can find them again and tombstone them. Your own entries are never
touched, because they do not carry the tag.

This is a testing tool and lives in tools/ with the other checks. It is not
reachable from the app, and the app has no idea it exists.
"""

import argparse
import json
import random
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

# Stamped on everything this writes, so --clear can find it. Visible in the
# app's note field, which is deliberate: seeded data should be obvious.
TAG = "[seeded]"

# Real HPB foods with their published per-serving figures, so the macro
# breakdown and the calorie totals are plausible rather than invented.
MEALS = [
    ("breakfast", "Kaya toast", "2 slice(s)", 187, 23.6, 4.1, 8.4),
    ("breakfast", "Teh", "1 cup(s)", 119, 16.4, 3.1, 4.6),
    ("breakfast", "Mee siam", "1 plate(s)", 483, 73.9, 12.6, 15.2),
    ("lunch", "Roasted chicken rice", "1 plate(s)", 643, 84.1, 29.7, 20.9),
    ("lunch", "Economic rice (1 vegetable, 1 fish)", "1 plate(s)", 599,
     78.2, 24.1, 20.3),
    ("lunch", "Ban mian (soup)", "1 bowl(s)", 602, 76.4, 28.9, 19.1),
    ("dinner", "Laksa", "1 bowl(s)", 701, 62.3, 24.8, 38.1),
    ("dinner", "Char kway teow", "1 plate(s)", 744, 76.1, 23.0, 38.2),
    ("dinner", "Yong tau foo (clear soup)", "1 bowl(s)", 578, 55.2, 34.7, 22.4),
    ("snack", "Banana, raw", "1 whole", 89, 22.8, 1.1, 0.3),
    ("snack", "Soya bean curd", "1 bowl(s)", 142, 24.1, 5.2, 2.9),
]


def call(url, path, token, payload):
    request = urllib.request.Request(
        f"{url.rstrip('/')}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})},
        method="POST")
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:300]
        raise SystemExit(f"{path} returned {error.code}: {body}")
    except urllib.error.URLError as error:
        raise SystemExit(
            f"Could not reach {url}: {error.reason}\\n"
            f"If it is a free host it may be asleep -- open {url}/api/ping "
            f"in a browser, wait for it to answer, then try again.")


def sign_in(url, email, password):
    body = call(url, "/api/login", None,
                {"email": email, "password": password})
    token = body.get("token")
    if not token:
        raise SystemExit("Signed in but got no token back.")
    return token


def build(days, start_weight, drift):
    """A run of days, each with two or three meals and one weight."""
    entries, weights = [], []
    today = datetime.now()
    random.seed(days)  # same history for the same arguments, so reruns match

    for ago in range(days, 0, -1):
        day = today - timedelta(days=ago)

        # One or two days in the run get skipped. A diary with no gaps is not
        # a realistic test of a chart that has to cope with them.
        if random.random() < 0.12:
            continue

        for slot in ("breakfast", "lunch", "dinner", "snack"):
            options = [m for m in MEALS if m[0] == slot]
            if not options or (slot == "snack" and random.random() < 0.5):
                continue
            _, name, serving, kcal, carbs, protein, fat = random.choice(options)
            hour = {"breakfast": 8, "lunch": 12, "dinner": 19, "snack": 16}[slot]
            eaten = day.replace(hour=hour, minute=random.randint(0, 50),
                                second=0, microsecond=0)
            quantity = random.choice([1.0, 1.0, 1.0, 0.5, 1.5])
            entries.append({
                "id": str(uuid.uuid4()),
                "food_id": None,
                "food_name": name,
                "quantity": quantity,
                "serving": serving,
                "kcal": round(kcal * quantity),
                "carbs_g": round(carbs * quantity, 1),
                "protein_g": round(protein * quantity, 1),
                "fat_g": round(fat * quantity, 1),
                "category": slot,
                "tags": "",
                "note": TAG,
                "eaten_at": eaten.isoformat(timespec="seconds"),
                "source": "manual",
                "deleted": 0,
                "updated_at": eaten.astimezone(timezone.utc)
                                   .isoformat(timespec="seconds"),
            })

        # One weight per day, which is what the app now enforces too.
        kg = start_weight + drift * (days - ago) + random.uniform(-0.3, 0.3)
        recorded = day.replace(hour=7, minute=30, second=0, microsecond=0)
        weights.append({
            "id": str(uuid.uuid4()),
            "kg": round(kg, 1),
            "recorded_at": recorded.isoformat(timespec="seconds"),
            "note": TAG,
            "deleted": 0,
            "updated_at": recorded.astimezone(timezone.utc)
                                  .isoformat(timespec="seconds"),
        })

    return entries, weights


def push(url, token, entries, weights):
    """In batches: the server refuses more than 500 rows in one push."""
    sent = 0
    batch = 200
    while entries or weights:
        chunk_entries, entries = entries[:batch], entries[batch:]
        chunk_weights, weights = weights[:batch], weights[batch:]
        result = call(url, "/sync", token, {
            "since": 0, "changes": chunk_entries, "weights": chunk_weights,
            "custom_foods": [], "profile": None})
        sent += result["push"]["applied"]
        if result["push"]["invalid"]:
            print(f"  {result['push']['invalid']} row(s) rejected by the "
                  f"server")
    return sent


def pull_all(url, token):
    """Everything on the account, paging until the cursor stops moving."""
    entries, weights, since = [], [], 0
    while True:
        body = call(url, "/sync", token, {
            "since": since, "changes": [], "weights": [],
            "custom_foods": [], "profile": None})
        entries.extend(body.get("changes") or [])
        weights.extend(body.get("weights") or [])
        cursor = body.get("cursor", since)
        if not body.get("has_more") or cursor == since:
            return entries, weights
        since = cursor


def clear(url, token):
    entries, weights = pull_all(url, token)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")

    dead_entries = [
        {**row, "deleted": 1, "updated_at": now}
        for row in entries
        if row.get("note") == TAG and not row.get("deleted")
    ]
    dead_weights = [
        {**row, "deleted": 1, "updated_at": now}
        for row in weights
        if row.get("note") == TAG and not row.get("deleted")
    ]
    for row in dead_entries + dead_weights:
        row.pop("server_seq", None)
        row.pop("user_id", None)

    if not dead_entries and not dead_weights:
        print("Nothing seeded on this account.")
        return

    push(url, token, dead_entries, dead_weights)
    print(f"Removed {len(dead_entries)} entries and {len(dead_weights)} "
          f"weights.")
    print("In the app: Profile tab -> Sync now, to see them disappear.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="the server's base URL")
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--days", type=int, default=28)
    parser.add_argument("--weight", type=float, default=76.0,
                        help="starting weight in kg")
    parser.add_argument("--drift", type=float, default=-0.04,
                        help="kg per day; negative loses, positive gains")
    parser.add_argument("--clear", action="store_true",
                        help="remove seeded rows instead of adding them")
    args = parser.parse_args()

    token = sign_in(args.url, args.email, args.password)

    if args.clear:
        clear(args.url, token)
        return 0

    entries, weights = build(args.days, args.weight, args.drift)
    print(f"Writing {len(entries)} entries and {len(weights)} weights "
          f"across {args.days} days...")
    applied = push(args.url, token, entries, weights)
    print(f"Server applied {applied} rows.")
    print()
    print("In the app: Profile tab -> Sync now.")
    print("  (Pulling down on Discover fetches recipes, it does not sync.")
    print("   Sync also runs when the app launches or returns to the")
    print("   foreground, so backgrounding and reopening works too.)")
    print()
    print("Remove it later with the same command plus --clear.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
