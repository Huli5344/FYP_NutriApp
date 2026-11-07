# Offline sync

The diary works offline and reconciles when a connection returns. This file
describes the contract the Android client implements against.

Three collections travel over it: diary **entries**, the **weight log**, and
the **profile**. They share one `server_seq` sequence and therefore one cursor.

## Model

Every diary entry and every weight carries:

| Field | Set by | Purpose |
|---|---|---|
| `id` | the device | UUID. Generated locally so two offline devices never collide |
| `updated_at` | the device | ISO timestamp of the last change. Decides conflicts |
| `deleted` | the device | Tombstone. `1` means removed |
| `server_seq` | the server | Monotonic counter. The pull cursor |

The profile carries the same `updated_at`, but no `deleted`: there is one
profile per device and no meaningful "deleted profile" to propagate, only a
newer one.

The device's own SQLite database is the source of truth for the interface. The
app reads and writes locally and never waits on the network; sync runs in the
background and updates the same tables.

## The endpoint

```
POST /sync
{
  "since":   0,              // highest server_seq this device has seen
  "changes": [ {entry}, … ], // entries changed locally since the last sync
  "weights": [ {weight}, … ],// weights changed locally
  "profile": {profile}|null  // the profile, only if changed locally
}
```

```
200 OK
{
  "server_time": "2026-09-19T08:14:02+00:00",
  "cursor":      42,        // store this, send it as "since" next time
  "has_more":    false,     // true if more rows are waiting; call again
  "changes":     [ {entry}, … ],
  "weights":     [ {weight}, … ],
  "profile":     {profile}|null,
  "push":        {"applied": 3, "skipped": 1, "invalid": 0}
}
```

Push and pull happen in one round trip, push first, so the response reflects
the caller's own writes. Call it on launch, on returning to the foreground, and
after a local write when a connection exists.

`400` for a malformed `since`, a non-list `changes` or `weights`, or a
non-object `profile`. `413` for more than 500 rows across `changes` and
`weights` combined.

### One cursor across three collections

The pull merges all three into a single stream ordered by `server_seq` and
returns the first page of it, so the cursor the client stores is a point every
collection has been read up to.

Paging each table with its own `LIMIT` would be wrong. Suppose entries have
sequences 1-3 and weights have 4-5, with a page size of 2. Three separate
queries would return entries 1-3 and weights 4-5 and report a cursor of 5 — but
only some of those rows fit in a page, and whatever was dropped sits below the
new cursor and is never pulled again. Merging first means the cursor only ever
advances past rows that were actually sent.

## Three failure modes this design prevents

**Colliding ids.** An autoincrementing key gives two offline devices the same
`id` for different meals. UUIDs are generated on the device.

**Resurrected deletions.** A hard `DELETE` leaves the server holding the row,
which the next pull hands straight back and the meal reappears. Deleting sets a
tombstone, so the deletion travels like any other change. Every read filters
`deleted = 0`.

**Clock skew deciding conflicts.** A phone set an hour fast would win every
conflict permanently, because its stamps always look newer. Incoming stamps are
clamped to the server clock when they are more than five minutes ahead, and the
pull cursor is a sequence number rather than a time, so paging never depends on
a device's idea of the hour.

## Conflict resolution

Last write wins, compared on `updated_at`. Equal stamps keep the stored row,
which makes a replayed push a no-op: a client that pushes, loses the response
and retries does not churn `server_seq` and drag every other device into a
pointless pull.

Last-write-wins is the right choice here. One user, rarely two devices editing
the same entry in the same minute, and the cost of losing the wrong edit is a
single meal entry. Anything cleverer would cost more than it saves.

## What does not sync

`api_cache` and `shown` are device-local conveniences. `foods` and `recipes`
are reference data and flow server-to-device only — in the app they are
compiled in as `seed_data.dart`, generated from `database.py` so the two
cannot drift.

## What the server will not accept

A pushed row is dropped, and counted under `invalid`, when it fails its
validator. Beyond the required fields:

- a weight outside 20–500 kg. SQLite would store a zero happily, and every
  average and trend computed from it afterwards would be wrong.
- a profile whose `target_kcal` is missing or not positive. The target is what
  every other figure in the app is measured against.

`server_seq` and `dirty` are stripped from anything a client pushes, so a
client cannot write the sequence and corrupt other devices' cursors. The
profile's `id` is set by the server for the same reason: a client that sent a
different key would create a second row nothing would ever read.

## Client responsibilities

1. Generate a UUID for each new entry and each new weight.
2. Set `updated_at` on every write, including deletions.
3. Keep a `dirty` flag locally, and clear it once the push reports `applied`.
4. Store `cursor` from each response and send it as the next `since`.
5. Repeat while `has_more` is true.
6. On merge, apply an incoming row only when its `updated_at` is newer than the
   local copy's.

The `dirty` flag is the one column the server never sees. It exists only so the
device knows what it still owes.

## Tests

`tests.py` covers the awkward cases: deletion resurrection, clock skew, a
replayed push, an entry edited on two devices, invalid rows beside valid ones,
the cursor stopping a device re-downloading its own writes, an implausible
weight, a profile without a target, a stale profile losing to a newer stored
one, and the merged page never advancing the cursor past a row it did not
return.

`tools/smoke_backend.py` drives every route end to end against a throwaway
database, including the full setup-to-sync path.
