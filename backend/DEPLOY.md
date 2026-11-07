# Running against Neon

The backend speaks Postgres when `DATABASE_URL` is set and SQLite when it is
not. Nothing else changes between the two: `db.py` is the only module that
knows which, and both are covered by the same tests.

## The quick way: the Neon CLI

If you have the CLI (`npm i -g neon@latest`), it does the configuration for
you. From the repository root:

```bash
neon init -y --org-id <your-org-id> --project-id <your-project-id> \
    --branch production --services postgres
neon env pull
```

`neon env pull` writes `.env.local` with both connection strings --
`DATABASE_URL` (pooled) and `DATABASE_URL_UNPOOLED` (direct) -- plus anything
else the branch exposes. `db.py` reads `.env.local` and `.env` automatically,
searching upwards from the backend directory, so nothing needs exporting and
the two URLs end up where they belong: pooled for the app, direct for schema
changes.

A real environment variable always wins over the file, so a CI secret or an
explicit `export` is never silently overridden by a file left in the tree.

`.env.local` holds a password. It is in `.gitignore`. Do not commit it.

Then skip to step 3. The rest of this page is the manual equivalent.

## 1. Create the database

Sign up at [neon.com](https://neon.com) — the free plan needs no card and does
not expire. Create a project, then copy the connection string from the
dashboard. It looks like:

```
postgresql://USER:PASSWORD@ep-something-123456.ap-southeast-1.aws.neon.tech/neondb?sslmode=require
```

Pick the region nearest you; `ap-southeast-1` is Singapore.

## 2. Two connection strings, not one

Neon's Connect dialog offers a **pooled** string (hostname contains `-pooler`)
and a **direct** one (it does not). They are not interchangeable:

| Use | String |
|---|---|
| Running the app | **pooled** — one short-lived connection per request is exactly what PgBouncer is for |
| Creating the schema (`database.init()`) | **direct** |
| `pg_dump` backups | **direct** |

Pooled connections run through PgBouncer in transaction mode, which has no
session state. A migration or a dump over a pooled connection can fail in ways
that never mention pooling: a `SET` that does not survive its own transaction,
`prepared statement "s0" already exists`, or a write landing in a read-only
transaction inherited from an earlier client. `setup_neon.bat` checks the
string for `-pooler` and refuses rather than letting you find out that way.

**Never put either string in the repository.** They contain a password granting
full access to every account's data. Set them in the environment:

```bash
# macOS / Linux
export DATABASE_URL="postgresql://...?sslmode=require"
export SECRET_KEY="$(python -c 'import secrets; print(secrets.token_hex(32))')"
```

```cmd
:: Windows, Command Prompt
set DATABASE_URL=postgresql://...?sslmode=require
set SECRET_KEY=<paste 64 hex characters>
```

`SECRET_KEY` signs the browser session cookie. With a known key, anyone can
forge a cookie and sign in as any user, so the app prints a warning at startup
if it is unset.

Keep `sslmode=require`. Without it the password crosses the network in clear.

## 3. Create the schema and load the foods

```bash
pip install -r requirements.txt
python -c "import database; database.init()"
python ../tools/load_foods.py foods.db
```

`init()` uses the direct connection when `DATABASE_URL_UNPOOLED` is set, and
warns if the only URL available is a pooled one.

`init()` is safe to re-run; it creates only what is missing. If it stops with
`SchemaOutOfDate`, the database was created before user accounts existed —
there is no migration for that, because entries became per-user and the food
table was replaced. Reset it with `database.init(force=True)`, which drops
every table first.

## 4. Run locally

```bash
python app.py
```

Register an account at `http://127.0.0.1:5000/register`. This is the
development server: fine on your own machine, never on a public URL. See
**Hosting it** below, which is what you need if the phone has to work while
your PC is off.

---

# Hosting it

Your PC cannot be the server if the app has to work for two months. The shape
that does work:

```
Android app  ──HTTPS──▶  Flask on Render  ──▶  Postgres on Neon
   (offline-first,          (free web            (free plan,
    food table on           service)              no expiry)
    the device)
```

**The phone never connects to Postgres.** A Dart Postgres driver exists, so it
is technically possible, and it must not be done: the connection string would
have to ship inside the APK, and an APK is a zip anyone can unpack and read
the strings out of in a minute. That single string is full read and write on
every account, every password hash and every diary. The per-user scoping that
protects all of that -- `scoped_user()`, the `(user_id, id)` key, the token
check in `before_request` -- lives in Flask. Connect around it and none of it
is in the path.

## Why Render for the server and Neon for the data

Render's free **web service** is fine: 750 instance-hours a month, no card
needed, no expiry. Render's free **Postgres** is not: it expires 30 days after
creation and is deleted after a 14-day grace period, which lands inside the
two months this has to survive. Neon's free plan has no expiry. So the data
stays on Neon and only the server goes on Render.

## 1. Get the code into a GitHub repository

Render deploys from a repo. From the project root:

```bash
git init
git add .
git commit -m "Nutri App"
```

Then create an empty repo on GitHub and push to it.

**Check `git status` lists no `.env.local` before you commit.** The root
`.gitignore` excludes `.env` and `.env.local` at any depth, so
`backend/.env.local` is covered -- but that file holds your Neon password, and
a password pushed to GitHub is a password to rotate, not to delete. If it does
get committed, rotate it in the Neon console rather than removing the file and
hoping.

## 2. Create the Render service

`render.yaml` at the project root configures everything. In Render: **New >
Blueprint**, pick the repo, and it reads the file. It sets the root directory
to `backend`, installs `requirements.txt`, creates the schema, and starts
gunicorn.

Doing it by hand instead (**New > Web Service**), the settings are:

| Field | Value |
|---|---|
| Root Directory | `backend` |
| Build Command | `pip install -r requirements.txt` |
| Pre-Deploy Command | `python -c "import database; database.init()"` |
| Start Command | `gunicorn app:app --bind 0.0.0.0:$PORT --workers 2 --threads 4 --timeout 120 --access-logfile -` |
| Health Check Path | `/api/ping` |
| Instance Type | Free |

Not `python app.py`. That is Werkzeug's development server with `debug=True`,
which hands an interactive Python console to anybody who can cause a
traceback. `app.py` now refuses to start when `PORT` is set, so a slip here
fails loudly instead of quietly serving a remote shell.

## 3. Set the environment variables

Three, in **Environment**:

| Key | Value |
|---|---|
| `DATABASE_URL` | the **pooled** Neon string (hostname contains `-pooler`) |
| `DATABASE_URL_UNPOOLED` | the **direct** Neon string (no `-pooler`) |
| `SECRET_KEY` | let Render generate one |

Both Neon strings, for the reason in section 2 above: the app runs on the
pooler, and the pre-deploy schema step needs the direct connection. The
blueprint marks the two database URLs `sync: false`, so Render prompts for
them rather than reading them from a committed file.

Without `SECRET_KEY`, Flask signs session cookies with a known development
key, and anyone can forge one and sign in as any user.

## 4. Load the foods, once, from your own machine

The pre-deploy step creates the schema but does not load the 2,692 foods --
`tools/load_foods.py` sits outside the deployed directory and it is a one-off,
not something to run on every deploy. From the project root, with your Neon
URL in the environment:

```bash
python tools/load_foods.py backend/foods.db
```

If you already did this while testing from your PC, it is already done: the
data is in Neon, not on your laptop. Re-running it is safe; it replaces the
rows.

## 5. Check the deployment

```
https://your-service.onrender.com/api/ping      {"ok":true,"service":"nutriapp-diary"}
https://your-service.onrender.com/api/health    {"ok":true,"database":"postgres","foods":2692}
```

`foods: 2692` is the one to look for. `0` means step 4 has not happened.

The two endpoints are different on purpose, and the difference is the subject
of the next section.

## 6. Keep it awake -- and do it with /api/ping, not /api/health

A free Render service **spins down after 15 minutes without traffic** and
takes about a minute to come back. The app survives that (food search and
logging are on the device, and sync failure is silent by design), but a
sign-in against a cold server is a minute of nothing, so keep it warm with an
external poll:

1. Sign up at [cron-job.org](https://cron-job.org) -- free, no card.
2. New cron job, URL `https://your-service.onrender.com/api/ping`, every
   **10 minutes**.

**It must be `/api/ping`.** Pointed at `/api/health`, or at any page, that
poll would wake the *database* every ten minutes too, and that is a bill you
cannot pay:

| | Allowance | A DB-touching poll every 10 min |
|---|---|---|
| Neon compute | 100 CU-hours/month = **400 active hours** at the 0.25 CU minimum | ~360 hours — 90% of the month's allowance, before a single real user |
| Neon compute, polled every 5 min | same | never suspends: ~720 hours, **exhausted around day 16** |

When the CU-hours run out, Neon suspends the compute until the next billing
period: existing connections drop and new ones are refused. Not slow — off.
And scale-to-zero cannot be disabled on the free plan, so there is no way to
pay for it differently.

`/api/ping` therefore opens no database connection at all. `before_request`
returns early for it (see `DB_FREE_ENDPOINTS` in `app.py`), which is why the
health check that *does* query the database is a separate endpoint you visit
by hand. There is a test that makes a connection impossible and checks
`/api/ping` still answers, so this cannot quietly regress.

Measured under gunicorn against a real Postgres, counting sessions in
`pg_stat_database`: **200 pings opened 0 database sessions**; one real request
opened 2.

Two things to watch on the Render side: 750 instance-hours is about 744 in a
31-day month, so one always-awake free service fits and **two do not** — a
second free service will exhaust the pool and suspend both. And keep the poll
at 10 minutes rather than 1; Render suspends free services for unusual
traffic.

## 7. Build the APK against the hosted URL

```bash
cd nutriapp
flutter build apk --release --dart-define=API_BASE=https://your-service.onrender.com
```

No code change -- `ApiConfig.baseUrl` is a `String.fromEnvironment`. Because
the URL is `https://`, you can also delete `android:usesCleartextTraffic` from
the manifest, which removes a finding a marker may otherwise raise. The
`INTERNET` permission is still required.

`nutriapp/TESTING.md` is the walkthrough for testing the result on the phone.

## What this costs, and what runs out

| | Free allowance | This app |
|---|---|---|
| Neon storage | 1 GB | **15 MB** measured, of which the food table is 1.5 MB; the rest is Postgres overhead and indexes |
| Neon compute | 100 CU-hours/month | only when somebody uses the app |
| Neon egress | 5 GB/month | small — food search is on the device, so the heavy table never crosses the wire |
| Render | 750 instance-hours/month | ~744 if kept awake; fits **one** service |
| cron-job.org | free | one job |

Nothing here expires inside two months, and nothing needs a card.

## What is where

| Table | Holds | Scoped by |
|---|---|---|
| `users`, `sessions` | accounts and device tokens | — |
| `foods` | the 2,692 HPB foods, read-only | — |
| `recipes` | the offline suggestion pool | — |
| `entries`, `weights`, `profile` | everything personal | `user_id` |
| `api_cache` | TheMealDB responses | — |
| `shown` | recently suggested recipes | `user_id` |

`entries` and `weights` are keyed on **(user_id, id)**, not on `id` alone.
Ids are generated on the device, so a collision between two accounts is a bug
or an attack; with `id` as the sole key, a push carrying another account's row
id would resolve to an UPDATE and overwrite it. The composite key makes that
impossible rather than dependent on every query remembering a filter. There is
a test for it.

## Keeping a backup

Free tiers owe you nothing. Export weekly:

```bash
# The DIRECT string, not the pooled one: pg_dump needs session state.
pg_dump "$DATABASE_URL_UNPOOLED" > backup-$(date +%F).sql
```

Neon's free plan has no time limit and suspends an idle database after five
minutes, waking automatically on the next query in a few hundred milliseconds.
There is nothing to keep alive and nothing to resume by hand.

## Tests

```bash
python tests.py                     # 190 tests
python ../tools/smoke_backend.py    # 56 route checks, end to end
```

Both run against SQLite by default and against Postgres with `DATABASE_URL`
set. Run them both ways after changing any SQL — that is the point of having
them work on both.
