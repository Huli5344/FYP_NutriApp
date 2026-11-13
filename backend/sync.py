"""
Offline-first sync rules.

Pure functions only, so the awkward cases can be tested without a server, a
database or a second device. `app.py` holds the endpoint; this file holds the
decisions it makes.

The model, in one paragraph. Every diary entry carries a client-generated UUID,
an `updated_at` stamp written by whichever device last changed it, a `deleted`
tombstone, and a `server_seq` assigned by the server on every write. Devices
pull with a `since` cursor of the highest `server_seq` they have seen and push
whatever they have changed locally. Conflicts resolve last-write-wins on
`updated_at`.

Three things this design exists to prevent:

  * Colliding ids. Two devices offline at once would both create entry 1 under
    an autoincrementing key, and the server could not tell them apart. UUIDs are
    generated on the device, so they never collide.

  * Resurrected deletions. A hard DELETE on one device leaves the server still
    holding the row, which the next pull hands straight back. Deleting sets a
    tombstone instead, so the deletion is a change like any other.

  * Clock skew deciding conflicts. A phone set an hour fast would win every
    conflict forever. Incoming stamps are clamped to the server's clock, and the
    pull cursor uses `server_seq` rather than time, so paging never depends on a
    device's idea of the hour.
"""

from datetime import datetime, timedelta, timezone

# Fields a client may set. Anything else in a pushed row is ignored, so a
# client cannot write `server_seq` and corrupt other devices' cursors.
CLIENT_FIELDS = (
    "id", "food_id", "food_name", "quantity", "serving", "kcal", "carbs_g",
    "protein_g", "fat_g", "category", "tags", "note", "eaten_at", "source",
    "deleted", "updated_at",
)

REQUIRED_FIELDS = ("id", "food_name", "kcal", "category", "eaten_at", "updated_at")

# The weight log travels with the entries. Same shape of bookkeeping, for the
# same reasons: a client-generated id so two devices cannot collide, and a
# tombstone so a deletion is not handed back by the next pull.
WEIGHT_FIELDS = ("id", "kg", "recorded_at", "note", "deleted", "updated_at")
WEIGHT_REQUIRED = ("id", "kg", "recorded_at", "updated_at")

# Foods the user entered themselves. A collection, so the same bookkeeping
# again. `serving` is free text -- "1 bowl", "half a packet" -- because the
# app multiplies by it rather than parsing it, exactly as it does with HPB's
# published serving labels.
CUSTOM_FOOD_FIELDS = ("id", "name", "serving", "kcal", "carbs_g", "protein_g",
                      "fat_g", "deleted", "updated_at")
CUSTOM_FOOD_REQUIRED = ("id", "name", "kcal", "updated_at")

# The profile is one row per device rather than a collection, so it has no
# tombstone: there is no meaningful "deleted profile" to propagate, only a
# newer one.
PROFILE_FIELDS = (
    "name", "email", "age", "gender", "height_cm", "weight_kg",
    "activity_level", "goal", "target_weight_kg", "preferences",
    "restrictions", "allergens", "diet_types", "diet_type",
    "computed_target_kcal", "target_kcal", "target_is_manual", "updated_at",
)
PROFILE_REQUIRED = ("name", "age", "height_cm", "weight_kg", "target_kcal",
                    "updated_at")

# How far ahead of the server a device's clock may be before it is corrected.
MAX_CLOCK_SKEW = timedelta(minutes=5)

# Rows returned per pull. Paging keeps a first sync on a full diary from
# building one enormous response.
PAGE_SIZE = 200


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse(stamp):
    """Read an ISO timestamp, returning None rather than raising."""
    if not stamp:
        return None
    try:
        parsed = datetime.fromisoformat(str(stamp))
    except (ValueError, TypeError):
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def clamp_timestamp(stamp, server_now=None):
    """Pull a client timestamp back to the server's clock if it is in the future.

    A device running fast would otherwise win every conflict it ever entered,
    permanently, because its stamps always look newer. An unreadable or missing
    stamp is treated as "now", which is the safest available guess.
    """
    server_now = server_now or datetime.now(timezone.utc)
    parsed = parse(stamp)
    if parsed is None:
        return server_now.isoformat(timespec="seconds")
    if parsed > server_now + MAX_CLOCK_SKEW:
        return server_now.isoformat(timespec="seconds")
    return parsed.isoformat(timespec="seconds")


def _has_required(row, required):
    if not isinstance(row, dict):
        return False
    return all(row.get(f) not in (None, "") for f in required)


def is_valid(row):
    """True if a pushed entry carries the fields the server needs."""
    return _has_required(row, REQUIRED_FIELDS)


def is_valid_weight(row):
    """True if a pushed weight carries the fields the server needs.

    The weight itself is also range-checked. A zero or a negative would be
    stored happily by SQLite and then poison every average computed from it.
    """
    if not _has_required(row, WEIGHT_REQUIRED):
        return False
    try:
        kg = float(row["kg"])
    except (TypeError, ValueError):
        return False
    return 20.0 <= kg <= 500.0


def is_valid_custom_food(row):
    """A custom food needs a name and a calorie figure; the rest has defaults.

    The name is checked for content rather than just presence: a food called
    " " is indistinguishable from a mistake, and it would sit in the user's
    search results forever with nothing to click on.
    """
    if not isinstance(row, dict) or not _has_required(row, CUSTOM_FOOD_REQUIRED):
        return False
    if not str(row.get("name", "")).strip():
        return False
    try:
        float(row["kcal"])
    except (TypeError, ValueError):
        return False
    return True


def is_valid_profile(row):
    """True if a pushed profile carries the fields the server needs."""
    if not _has_required(row, PROFILE_REQUIRED):
        return False
    try:
        return int(row["target_kcal"]) > 0
    except (TypeError, ValueError):
        return False


def clean(row, server_now=None):
    """Keep only the fields a client may set, and correct its clock."""
    out = {k: row[k] for k in CLIENT_FIELDS if k in row}
    out["deleted"] = 1 if row.get("deleted") else 0
    out["updated_at"] = clamp_timestamp(row.get("updated_at"), server_now)
    return out


def clean_weight(row, server_now=None):
    out = {k: row[k] for k in WEIGHT_FIELDS if k in row}
    out["deleted"] = 1 if row.get("deleted") else 0
    out["updated_at"] = clamp_timestamp(row.get("updated_at"), server_now)
    return out


def clean_profile(row, server_now=None):
    """Keep only the profile fields a client may set, and correct its clock.

    The id is set by the server rather than taken from the push. One device
    holds one profile, so a client that sent a different key would otherwise
    create a second row that nothing would ever read.
    """
    out = {k: row[k] for k in PROFILE_FIELDS if k in row}
    out["target_is_manual"] = 1 if row.get("target_is_manual") else 0
    out["updated_at"] = clamp_timestamp(row.get("updated_at"), server_now)
    return out


def clean_custom_food(row, server_now=None):
    cleaned = {field: row.get(field) for field in CUSTOM_FOOD_FIELDS}
    cleaned["name"] = str(cleaned["name"]).strip()[:120]
    cleaned["serving"] = (str(cleaned.get("serving") or "").strip()
                          or "1 serving")[:80]
    cleaned["kcal"] = int(float(cleaned["kcal"]))
    for macro in ("carbs_g", "protein_g", "fat_g"):
        try:
            cleaned[macro] = float(cleaned.get(macro) or 0)
        except (TypeError, ValueError):
            cleaned[macro] = 0.0
    cleaned["deleted"] = 1 if cleaned.get("deleted") else 0
    cleaned["updated_at"] = clamp_timestamp(cleaned["updated_at"], server_now)
    return cleaned


def should_apply(incoming, existing):
    """Decide whether a pushed row replaces what the server holds.

    Last-write-wins on `updated_at`. Equal stamps keep the stored row, which
    makes a replayed push a no-op: a client that pushes, loses the response and
    retries does not churn `server_seq` and drag every other device into a
    pointless pull.
    """
    if existing is None:
        return True
    incoming_at = parse(incoming.get("updated_at"))
    existing_at = parse(existing.get("updated_at"))
    if incoming_at is None:
        return False
    if existing_at is None:
        return True
    return incoming_at > existing_at


def summarise(applied, skipped, invalid):
    return {"applied": applied, "skipped": skipped, "invalid": invalid}


def page(candidates, page_size=PAGE_SIZE):
    """Merge several sources into one page ordered by `server_seq`.

    Entries, weights and the profile share one sequence, so a pull has to be
    one ordered stream rather than three independent queries. Taking the first
    `page_size` of the merged stream means the cursor the client stores is a
    point every collection has been read up to. Three separate limits would
    advance the cursor past rows in another table that were never sent, and
    those rows would never be pulled.

    `candidates` is a list of (kind, row) pairs, each row carrying a
    `server_seq`. Returns the page, the cursor to report, and whether more is
    waiting.
    """
    ordered = sorted(candidates, key=lambda pair: pair[1]["server_seq"])
    has_more = len(ordered) > page_size
    taken = ordered[:page_size]
    cursor = taken[-1][1]["server_seq"] if taken else None
    return taken, cursor, has_more
