# What changed

Two things were done: the seven problems found in the profile code were fixed,
and the two inert tabs were built, along with the Goals and Data Visualisation
features from the functional requirements. The AppManager admin panel was left
out, as agreed.

Layout note: your upload contained only `nutriapp/`. The backend has moved
alongside it as `backend/`, with `tools/` holding the generator scripts, because
`tools/retag_recipes.py` reads `backend/database.py`.

```
nutriapp/     Flutter app
backend/      Flask backend and the Python prototype
tools/        Generators and checks (see the end of this file)
```

---

## The seven problems

### 1. The profile was collected and thrown away

`finishOnboarding()` built a map, called `debugPrint` on it, and navigated
away. There was no profile table, no `shared_preferences`, nothing on disk.

Now there is a `profile` table, and the answers go through
`logic.buildProfile()` on the way in. That function is the only place raw
answers become stored values, which is what stops a screen filtering on an
untranslated label.

### 2. Every screen still read the hardcoded demo profile

Fourteen call sites across five screens used `Profile.dailyTarget`,
`Profile.allergens` and `Profile.dietType`. Those were `static const`, so they
could not have been reassigned at runtime even deliberately.

The class is gone. `UserProfile` replaces it, loaded from the database. Tab-root
screens read it on every load, so a profile edit reaches them without any
plumbing; `RecipeDetailScreen` and `SavedScreen` take it as a parameter so the
allergen check in `build` and the one in `_save` cannot disagree.

The visible symptom is also gone: Discover said *"Peanut and shellfish are
excluded"* regardless of what you ticked. It now reads back your own labels —
"Dairy and Eggs" — and says so plainly when you have no restrictions recorded.

### 3. The allergen vocabularies did not line up

I was half wrong in my review. `recipes_api.py` already derives `nuts` and
`sesame`, so all nine chips map one-to-one onto existing tokens — only the
translation was missing:

| Chip | Token |
|---|---|
| Peanuts | `peanut` |
| Tree Nuts | `nuts` |
| Dairy | `milk` |
| Eggs | `egg` |
| Gluten, Soy, Fish, Shellfish, Sesame | unchanged |

`normaliseAllergens` / `normalise_allergens` do the mapping on both sides. Both
the labels and the tokens are stored: the labels are what the edit form shows
back and what Discover reads out, the tokens are what the filter compares.

There is a test for the exact failure mode — a cheese recipe is correctly
excluded by `normaliseAllergens(['Dairy'])` and wrongly reported safe by the raw
label, so a regression here fails loudly.

**Preferences.** `Mediterranean` could be selected and could never change
anything, so it was replaced with `High protein`, `High fibre` and `Low carb`,
which the data carries. `Pescatarian` and `Halal` are now derived in
`recipes_api.py` by looking for ingredient words that rule a meal out. Every
option now maps to a real tag, and a test asserts that.

`matchesDiet` takes one diet type but setup collects a list, so
`primaryDietType` narrows it. The most restrictive wins: a vegan who also wants
high protein is poorly served by a chicken breast, while the reverse costs only
variety.

### 4. Nothing computed a calorie target

Setup asked for age, sex, height, weight, activity level and goal and used none
of it.

`dailyTargetFor` now does Mifflin–St Jeor for resting burn, scales it by
activity level, adjusts for the goal, and rounds to ten. The macro split varies
by goal too — protein rises for muscle gain and for weight loss, where it
protects lean mass.

The rule worth defending in a viva: **the result is never below resting burn.**
A small, sedentary person on a 500 kcal deficit comes out beneath what their
body uses at rest, and the formula refuses that regardless of how the
arithmetic lands. There is a test asserting it.

The Profile tab shows the working, because a number someone is asked to live by
should not arrive unexplained.

### 5. Register could not read its own fields

No `TextEditingController` on any of the three inputs, so the typed values were
unreachable from Dart.

Per your choice, the stub stays but stops pretending. The fields have
controllers, the screen states that it cannot create an account and stores no
password, and the one answer it can use — the name — is handed back to profile
setup. The login screen names the demo credentials on screen, so whoever marks
this can get in. All of the pretence is confined to `lib/accounts.dart`, with a
note on what a real implementation would replace.

### 6. Onboarding ran on every launch, and could never be revisited

Login pushed `OnboardingScreen` unconditionally. Now it branches on whether a
profile exists. The Profile tab reuses the onboarding flow as its edit form
rather than duplicating it — two forms over the same fields drift apart and the
validation would have to be written twice.

### 7. The migration trap

Schema is now **version 2** with an `onUpgrade`. You have already run this on
your Pixel, so that phone holds a version-1 database; editing `onCreate` alone
would have worked on a wiped device and failed on yours with
`no such table: profile`.

---

## The rest of the app

### Insights (Data Visualisation)

Seven, fourteen or thirty days of: calories per day against target, consistency
and streak, where calories come from, calories by meal, and a weight trend with
progress towards a target weight.

Two arithmetic decisions that are worth knowing about:

- **Averages are over days actually logged, never the whole window.** Dividing
  a week's intake by seven when three days were recorded reports about half of
  what someone ate, and would make every summary look like a deficit.
- **Unlogged days are drawn as empty outlines, not skipped.** A chart that
  omits them shows an unbroken run of good days to someone who simply stopped
  recording.

A streak tolerates an unlogged today, or it would collapse every morning before
breakfast.

Charts are drawn by hand — `WireVBars`, `WireStackBar`, `WireSparkline` in
`ui.dart`, and CSS in `app.css` for the web side. No charting package, so
there is nothing extra to resolve on your machine, and they match the
wireframes' flat bars and hairlines.

### Profile and Goals

View and edit everything, see how the target was derived, override it by hand
(the calculated figure is kept, so the override survives an edit to your
height), log a weight, sync on demand, and start over.

Logging a weight rebuilds the target around it, since the profile would
otherwise go on describing a body that has changed.

### Sync

The contract now carries three collections — entries, weights and the profile —
over one `server_seq` sequence and one cursor.

The pull merges all three into a single ordered stream and returns the first
page. Paging each table with its own `LIMIT` would be wrong: the cursor would
advance past rows in another table that were never sent, and those rows would
never be pulled again. `SYNC.md` has the worked example.

### Found along the way: the seed recipes understated their allergens

Six of the twenty-five offline recipes declared fewer allergens than their own
ingredient lists imply. A stir-fry with soy sauce was tagged `soy` but not
`gluten` — though soy sauce contains wheat, and `ALLERGEN_KEYWORDS` has always
known that. Someone avoiding gluten would have been shown it.

One recipe was tagged `vegan` while listing egg noodles.

`tools/retag_recipes.py` runs the rows through the same derivation the live API
path uses. Allergens merge as a **union** — a declared allergen is never
dropped, because an ingredient list can be incomplete and that is the one change
here that could do harm. A contradicted *diet* claim is removed, which only
narrows what the app claims.

Three tests now guard this, so hand-edited rows cannot drift back.

---

## Tests

| | Before | After |
|---|---|---|
| Python unit tests | 78 | **190**, all passing |
| Backend route checks | — | **56**, all passing on SQLite and Postgres |
| Dart tests | 36 | **106**, none run — see below |

`tools/smoke_backend.py` drives every route against a throwaway database:
setup-redirects-before-a-profile-exists, form rejection, the label-to-token
translation reaching the database, every page rendering, logging a food,
logging a weight recalculating the target, the full sync round trip, and a
stale profile losing to a newer stored one.

**The Dart tests have not been run.** There is no Dart SDK in this environment
and the SDK host is unreachable from it, so I could not compile or execute
anything. Run `flutter test` and `flutter analyze` before you trust that count.

What I did instead: `tools/check_dart.py` checks the ways a hand edit across
twenty-nine files goes wrong — delimiter balance with strings and comments
skipped, imports resolving, no duplicate class declarations, constructor
targets existing, required named parameters supplied at every call site, no
surviving references to identifiers I removed, no redundant inner `const`, and
two new ones:

* **data-destroying calls stay where they belong.** `SessionStore.clear` and
  `LocalDb.resetEverything` delete the user's diary. They are allowed from
  three files and nowhere else, because anywhere else is data loss by accident
  — the kind a user cannot undo.
* **every relative import is used.** The lint a deletion leaves behind.

It passes, and I verified each new check catches a real fault by injecting
one. Worth recording that the import check **passed everything** when first
written: a character class containing `\s` let the anchor run past a line
break, so it collected every method name in the file and matched `if`, `for`
and `return` in the importing file — every import looked used. A check that
cannot fail is worse than no check, because it is counted. The same happened
to the search-ranking check in `check_food_db.py`: the obvious version of it
passes an inverted `ORDER BY`, because inverting it pushes every prefix match
past the row limit and leaves nothing out of order. Both are now stated
positively, and both fail when broken.

None of this is a substitute for the analyser.

---

## Before you build a release APK

Both of these still apply and both fail silently:

1. `android/app/src/main/AndroidManifest.xml` needs
   `<uses-permission android:name="android.permission.INTERNET"/>` inside
   `<manifest>`. Flutter injects it for debug builds only, so a release APK
   fails every network call with no error shown.
2. `lib/api.dart` defaults to a LAN address, which was right for one machine on
   one network. Override it at build time rather than editing the file:
   `flutter run --dart-define=API_BASE=http://<your-ip>:5000`. A deployed
   `https://` URL needs no other change and lets you drop
   `usesCleartextTraffic`.

`nutriapp/TESTING.md` is the walkthrough for all of this: sixteen passes on a
real phone, each with what to expect and what it proves, plus the three
Android settings that fail silently.

---

## Hosting, and the billing cliff in the obvious plan

The PC cannot be the server for two months, so the backend goes on a free
Render web service with the data staying on Neon. `backend/DEPLOY.md` has the
steps. Render's free *Postgres* is not part of the plan: it expires 30 days
after creation, which lands inside the two months.

A free Render service sleeps after 15 idle minutes and takes about a minute to
wake, so something has to poll it. The obvious way to do that would have
killed the database.

`before_request` opened a connection on **every** request, the health check
included. Neon's free plan allows 100 CU-hours a month, which at the 0.25 CU
minimum is 400 hours of active compute against roughly 720 in a month, and
scale-to-zero cannot be disabled. So a poll that touched the database every
five minutes would never let the compute suspend: about 180 CU-hours, with the
database suspending itself around day 16 and staying suspended until the next
billing period. Not slow — off, mid-demo, with no warning.

`/api/ping` now opens no connection at all (`DB_FREE_ENDPOINTS` in `app.py`),
and the check that *does* query the database is a separate `/api/health` you
visit by hand. Measured under gunicorn against real Postgres, counting
sessions in `pg_stat_database`: **200 pings opened 0 database sessions**, one
real request opened 2. There is a test that makes a connection impossible and
asserts `/api/ping` still answers; reverting the fix fails it.

Also changed for deployment:

* **gunicorn**, with a `Procfile` and a root `render.yaml` blueprint. `python
  app.py` is Werkzeug's development server with `debug=True` — an interactive
  Python console for anyone who can cause a traceback — so `app.py` now
  **refuses to start when `PORT` is set**, which is how every host of that
  shape announces itself. A slip in a dashboard start command fails loudly
  instead of quietly serving a remote shell.
* **Auth calls get 75 seconds**, not 6. A cold host takes about a minute, and
  at 6 seconds the first sign-in of the evening failed with "email or password
  is incorrect" — a lie about the one thing the user is trying to get right.
  Sync and recipes keep the short timeout, because nobody is waiting on them.
  The sign-in and register screens show a "still waking up" note after six
  seconds so the wait is explained rather than silent.

---

## tools/

| Script | Does |
|---|---|
| `import_hpb_foods.py` | Builds `foods.db` from HPB's published CSV |
| `verify_hpb_import.py` | Compares all 69,992 cells back against the CSV |
| `load_foods.py backend/foods.db` | Loads the food table into SQLite or Postgres |
| `retag_recipes.py backend/database.py` | Re-derives seed allergens and diet tags. Idempotent |
| `smoke_backend.py` | Drives every Flask route against a temporary database |
| `check_dart.py nutriapp` | Nine static checks on the Dart sources |
| `check_food_db.py nutriapp/assets/foods.db nutriapp/lib/food_db.dart` | Runs the app's own SQL against the database the app ships |

`generate_seed_data.py` is gone. It wrote the 30 hand-entered foods into
`seed_data.dart`; those foods were deleted in favour of HPB's 2,692, which
ship as a database file rather than as Dart source. `seed_data.dart` now holds
only the 25 offline recipes, and `retag_recipes.py` is still the way to
maintain their allergen tags — a drift in that column being exactly the kind
that stops a filter protecting someone.

`check_food_db.py` exists because the queries in `food_db.dart` are strings.
`flutter analyze` does not look inside them and the type system does not
either, so a misspelt column shows up as an empty search box on a phone. It
lifts the SQL out of the Dart source rather than keeping a copy — a copy would
drift within a week and prove nothing — and runs it against the bundled
`assets/foods.db`. 24 checks. It found one real bug on its first run: `_` and
`%` typed into the search box were being treated as SQL `LIKE` wildcards, so
"teh_" quietly matched "teh c" and "teh o". Fixed with an `ESCAPE` clause.
