# The admin panel

A staff-only view of the live database, at `/admin` on the same deployment as
the app. It was written as a separate Flask application and moved in here; what
follows is how to use it, what each page reads, and what changed in the move.

For *why* each page is built the way it is — and why several obvious-looking
features (delete, edit, export, an import button) are deliberately absent —
see **ADMIN-NOTES.md**. That text used to sit at the bottom of the pages
themselves.

---

## Getting in the first time

A freshly deployed database has **no administrators**, so `/admin` is reachable
by nobody. That is deliberate: the panel can see and block every account, so
access is granted once, on purpose, rather than defaulting on for whoever
registers first.

1. **Register an account normally**, through the app or at `/register`. There
   is no separate admin account type — an administrator is an ordinary account
   with a flag set.

2. **Deploy first.** The flag lives in a column that Render's build step adds
   to the live `users` table. Until that deploy has run, there is nothing to
   set — `make_admin.py` will say so rather than failing obscurely.

3. **Grant it**, from the backend folder:

   ```
   cd backend
   python ../tools/make_admin.py --list
   python ../tools/make_admin.py --email you@example.com
   ```

   Remove access later with `--remove`.

4. **Sign in** at the normal sign-in page, then open `/admin`.

After that, administrators promote each other from a user's page — the command
line is only needed from cold.

### Which database it writes to

`make_admin.py` uses whichever database `DATABASE_URL` points at, and **prints
which one before doing anything**. Read that line; it is the only difference
you will see between changing your laptop's scratch file and changing
production.

With no `DATABASE_URL` set and no `.env.local` in `backend/`, it targets the
local SQLite file — which is the usual state of a development machine, and
means the command above grants admin on a database the live site never sees.

To target Neon for one command, take the connection string from the Render
dashboard (your service → Environment → `DATABASE_URL`) and set it for that
shell only:

```powershell
$env:DATABASE_URL="postgresql://..."
python ../tools/make_admin.py --list
```

Expect `PostgreSQL at ep-....neon.tech/...` in the first line of output. The
variable lasts only until that window closes.

That string contains the database password. Do not put it in a file inside the
repository, and if it is ever pasted somewhere it should not be — a chat, a
screenshot, a commit — **reset the role's password in the Neon console** and
update it in Render. Deleting the message does not revoke it.

---

## What each page reads

Nothing on any page is seeded, cached or scheduled. Every figure is a count of
rows, taken when the page is drawn.

| Page | Reads |
|---|---|
| Overview | Counts across `users`, `profile`, `entries`, `weights`, `custom_foods`, `foods`, `sessions` |
| Users | `users` left-joined to `profile`, with each account's live entry count |
| *a user* | That account's profile and its last 30 days of logging |
| Dietary goals | `profile.goal`, against the goals `logic.py` offers |
| Food database | `foods` — the 2,692-row HPB dataset, paged and searchable |
| Categories and tags | `foods.food_group`, and the most-logged foods |
| Preferences and allergens | `profile.allergens` and `profile.diet_types` |
| Recipe service | `recipes` and `api_cache` |
| Rules and metrics | The effective rules: `logic.py` defaults plus any saved overrides. **Editable** |
| Reports | `entries` grouped by day, last 14 and 30 days |
| Roles and access | Accounts with `is_admin` |
| Sessions | `sessions` that have not expired |

The Rules page is editable: `logic.py` holds the defaults, and what an
administrator saves is an override in the `settings` table merged onto them.
Every value is bounded and checked server-side, nothing saves unless the whole
form is valid, and "Restore defaults" removes the override. The minimum daily
target cannot be set below 1,200 kcal. See ADMIN-NOTES.md.

---

## What an administrator can do

Two things, both reversible:

**Block an account.** Refuses sign-in and deletes every session on it, so the
block takes effect immediately rather than whenever the existing tokens expire.
The person is told their account is blocked, not that their password is wrong —
once the password has been accepted there is nothing left to protect by being
vague, and "wrong password" would send them into a reset loop that cannot help.

**Promote or demote an administrator.**

Two refusals are built in, because both are one click away from a panel nobody
can open:

* You cannot block your own account. Blocking deletes your sessions, so the
  click would sign you out of the page needed to undo it.
* The last remaining administrator cannot be demoted. `make_admin.py` refuses
  the same change, since it is the tool you would reach for to fix a mistake.

### What it deliberately cannot do

There is **no delete**, and no editing of anybody else's name, email, goal or
diary.

Deleting an account destroys that person's food diary. The only person who
should be able to do that is its owner, and the app already allows it — profile
screen, re-enter password, confirm. A one-click version here, with no password
and no undo, would be a strictly worse way to do the same thing.

Food figures are not editable either. They are the Health Promotion Board's
published values; editing one would create a number that looks official and
cites nothing. Foods the dataset lacks are added by people themselves, in the
app, and counted separately.

---

## How access is enforced

`admin.py` registers a blueprint `before_request`, so the check runs for every
route in it — including any added later, which is why it is not a per-route
decorator.

* **Not signed in** → the sign-in page.
* **Signed in, not an administrator** → **404**, not 403. A 403 confirms the
  panel exists and that this person is merely not on the list. To an ordinary
  account the panel is absent, not forbidden.
* **An administrator whose account was since blocked** → 404 as well, checked
  per request, so revoking access takes effect on the next click.

Blocking is enforced twice over: `admin_set_disabled` deletes the account's
sessions, and `accounts.user_for_token` refuses a blocked account even if a
token somehow survives. Each half has its own test, because either one alone
makes `/api/me` return 401 — a single test could not tell which was working.

---

## Deploying it

Nothing extra. It is part of the same service, so `git push` deploys it with
everything else, and Render's build step (`database.init()`) adds the two new
columns to the existing `users` table.

That migration is additive and idempotent: `ADDED_COLUMNS` in `database.py`
lists columns added after the first deploy, because `CREATE TABLE IF NOT
EXISTS` sees the existing table and skips it, so a new column would otherwise
never appear in production. Existing rows keep their data and default to
`is_admin = 0`, `disabled = 0`. Re-running it changes nothing, and a granted
admin flag survives later deploys.

It adds no cost on Neon's free plan beyond the pages actually loaded: one
service, one connection pool, and `/api/ping` still answers without touching
the database.

---

## What changed from the original

The panel arrived as a standalone Flask app with its own SQLite file.

**The data layer.** It used Flask-SQLAlchemy over seven models seeded with five
fictional users, five foods and five recipes. Every query now runs through
`database.py` against the real tables. Flask-SQLAlchemy is no longer a
dependency.

**The gate.** None of its routes had a login. `POST /users/action` would add,
edit or deactivate a user for anyone who found the URL, and `app.secret_key`
was a literal string. Every route is now behind the check above.

**Sections describing things this project does not have.** The panel was
written against Supabase Auth, the Edamam API, and free/paid user tiers. None
of the three exist here: authentication is this project's own PBKDF2 and
sessions table, suggestions come from TheMealDB with the HPB dataset for
nutrition, and there is one kind of account plus an admin flag. Those pages now
say so in place rather than showing invented figures.

The fourteen-row permission matrix is the clearest case. Rendering it would
have described a system that was never built, and the first person to rely on
it would be relying on nothing.

**`/api/mobile/sync`** is gone. It returned a fixed dictionary describing the
tech stack plus a list of the fictional users, and its path overlapped the real
`/sync`, which is the offline-sync endpoint the Flutter app depends on.

**What did not change:** the templates, the stylesheet, the sidebar structure,
the page layouts and the class names are as originally written. They live in
`templates/admin/` and `static/admin/`. What they are fed changed; what they
look like did not.

Two small fixes to the markup were needed. Their edit rows placed a `<form>`
directly inside a `<tr>`, which browsers hoist out of the table — so those
forms never submitted their inputs. And `.button-danger` set a background
unconditionally, which overrode the browser's grey-out, so a disabled button
looked identical to a live one.

---

## Tests

`tests.py` covers the panel in four classes, run with the rest:

```
cd backend && python -m pytest tests.py -q
```

* `TestAdminAccessGate` — who is refused, and that every registered route is
  in the list being tested
* `TestBlockingAnAccount` — sign-in refused, sessions deleted, other accounts
  untouched
* `TestAdminCannotLockEveryoneOut` — the two refusals above
* `TestAdminPagesShowRealData` — counts move when rows change, no seeded name
  can appear, search escapes LIKE wildcards
