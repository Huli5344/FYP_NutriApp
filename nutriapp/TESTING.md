# Testing Nutri App on a phone

The app is the thing being marked, so this is a walkthrough you can actually
sit and do, with what should happen written next to each step. Sixteen passes,
about forty-five minutes end to end. Each one says what it proves, because a test
whose purpose you cannot state is a test you cannot defend in a viva.

Three of them fail on a real phone for reasons that have nothing to do with
your code — they are first, under **Before you plug anything in**.

---

## Before you plug anything in

### 1. The INTERNET permission

`android/app/src/main/AndroidManifest.xml`, inside `<manifest>` and before
`<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Flutter injects this for *debug* builds only. A release APK without it fails
every network call, and the app is built to be silent about network failure —
so sync just never happens and nothing tells you why. Add it now and it is
right for both.

### 2. Cleartext traffic, if the server is http://

Also in the manifest, on the `<application>` tag:

```xml
android:usesCleartextTraffic="true"
```

Android 9 and later block plain HTTP by default. Your Flask server is
`http://`, so without this every call fails with a connection error that looks
exactly like the server being down.

If you point the app at an `https://` URL instead, delete this line. It exists
only because the development server has no certificate, and shipping an app
that permits cleartext is a finding a marker may well raise.

### 3. Where the server is

Two choices, and they are not either/or — use both.

**Hosted (what you need for the next two months).** Your PC cannot be the
server if the app has to work while it is off. `backend/DEPLOY.md` has the
steps: Flask on a free Render web service, data on Neon, a 10-minute poll on
`/api/ping` to stop Render falling asleep. Then:

```
flutter run --dart-define=API_BASE=https://your-service.onrender.com
```

With a hosted `https://` URL you can delete `usesCleartextTraffic` from the
manifest — step 2 above stops applying.

**LAN (faster while you are developing).** Your laptop on the same Wi-Fi, no
cold starts.

`lib/api.dart` defaults to `http://192.168.86.29:5000`. That was one machine on
one Wi-Fi network. Find yours with `ipconfig` on Windows — the IPv4 address
next to the Wi-Fi adapter — and pass it at build time rather than editing the
file:

```
flutter run --dart-define=API_BASE=http://192.168.1.42:5000
```

The phone and the laptop must be on the same network, and Windows Firewall
must allow inbound 5000 for Python; the first prompt usually appears the first
time you start the server, and "Private networks" is enough.

Check it from the phone's browser before you build: open
`http://192.168.1.42:5000/api/ping`. You should see

```json
{"ok": true, "service": "nutriapp-diary"}
```

If that does not load in the phone's browser, no amount of Flutter will fix
it, and every later pass will fail for the same reason.

---

## Starting up

```
cd nutriapp
flutter pub get
flutter analyze
flutter test
flutter devices            # the phone should be listed
flutter run --dart-define=API_BASE=http://<your-ip>:5000
```

`flutter test` runs 106 declared tests across three files: `logic_test.dart`
(72 — targets, categories, allergen matching, the recommendation filter),
`widget_test.dart` (17 — the drawing widgets, including the divide-by-zero
cases), and `models_test.dart` (17 — database rows and login JSON turning into
objects).

These were written without a Dart SDK and run for the first time on
2026-11-06: **106 passed**, and `flutter analyze` reported three problems,
all since fixed. Two were a real bug — `Navigator.of(context)` called after a
dialog's `await` in the sign-out and start-over paths, which throws if the
screen is disposed while the dialog is open. Re-run both after any change;
they are quick.

The server, in a second terminal:

```
cd backend
python app.py
```

It should print `Database: Postgres` and the Neon connection it is using. If it
prints `SQLite`, your `.env.local` is not being read, and the app will work
against a local file instead of your hosted database — which is fine for the
first few passes but is not what you are demonstrating.

---

## The passes

### 1. First launch goes to sign-in

Uninstall the app first — long press the icon, App info, Uninstall — so this
really is a first launch. A reinstall over the top keeps the database, which
is pass 15, not this one.

**Expect:** the Sign in screen. Not onboarding, not a dashboard.

**Proves:** `StartupGate` reads the stored session, finds none, and routes to
sign-in. There is no demo account any more — `guest@test.com` / `1234` is gone,
along with the file that held it.

### 2. A sleeping server explains itself

Only if you are on the hosted URL. Stop the keep-warm job (or wait 20 minutes
after any use), then open the app and sign in.

**Expect:** after about six seconds, a note reading "Still waiting. If the
server has been idle it can take up to a minute to wake up." Then a normal
sign-in, within the minute. If it does give up, the message names the cause —
free hosting sleeping — rather than blaming your password.

**Proves:** auth calls get a 75-second budget and their own message, while
sync and the recipe list keep the 6-second one. Six seconds everywhere would
have turned the first sign-in of the evening into "email or password is
incorrect", which is a lie about the one thing the user is trying to get
right.

### 3. Sign in with a wrong password

Type any email and any password.

**Expect:** "email or password is incorrect", and the same wait whether the
email exists or not.

**Proves:** the server compares a PBKDF2 digest and hashes a dummy password for
an unknown email, so the response time does not reveal who has an account.

### 4. Register, then onboarding, then the dashboard

Create an account. A password under eight characters should be refused before
it leaves the phone.

**Expect:** after registering you go straight into profile setup — not back to
a sign-in form asking for the password you just chose. Fill it in; you land on
the dashboard with a calorie target.

**Proves:** registration returns a session token, the app stores it, and
onboarding runs because no profile exists yet. Check the target against the
Profile tab's own working — it shows the BMR, the activity multiplier and the
goal adjustment as separate lines, so you can check the arithmetic by hand.

### 5. Kill the app and relaunch

Swipe it away from the recents list, then open it again.

**Expect:** the dashboard. No sign-in, no onboarding.

**Proves:** the bug that onboarding ran on every launch is gone, and the gate
decides from local state — so this works with the server off, too. Try it:
stop Flask, relaunch, still the dashboard.

### 6. Search the food table

Add food. Type nothing at first.

**Expect:** a starter list in alphabetical order, and the label "Search 2,692
foods".

Now type `rice`.

**Expect:** names *beginning* with "rice" first — there are exactly seven:
Rice bran, Rice cracker, Rice flakes, Rice flour, Rice kheer, Rice milk, Rice
wine — then names merely containing it, of which there are a hundred. Every result shows HPB's own serving
label, like `1 plate(s) = 363g`.

Type `chicken_rice` with the underscore.

**Expect:** nothing found.

**Proves:** the three things most likely to be wrong in a search box. The
ranking is a `CASE` in the `ORDER BY`; the serving text is HPB's, not something
parsed and reassembled; and `_` is a literal underscore rather than SQL's
single-character wildcard, which it was until `tools/check_food_db.py` caught
it.

### 7. Search with the phone in airplane mode

Turn airplane mode on. Search again.

**Expect:** identical results, as fast as before.

**Proves:** the whole food table ships inside the APK as `assets/foods.db` and
is copied to the device on first run. Logging lunch on a train was the point;
it also means 2,692 rows of food search cost your Neon database nothing.

### 8. Log a bulk serving

Search `turkey`. Find "Roasted turkey, without skin".

**Expect:** a `large portion` tag on the row, and a serving of `1 whole = 3812g`
at 4,243 kcal.

**Proves:** HPB publishes some foods per whole item, and one tap would
otherwise log two days of calories as a single lunch. 23 foods carry this flag.

### 9. Log a meal and watch the dashboard

Pick "Roasted chicken rice", quantity 1, add to diary.

**Expect:** the saved screen, then the dashboard showing 643 kcal against your
target, with the macro bars moved.

**Proves:** the end-to-end write path — bundled food, scaled nutrition, local
database, dashboard re-read.

### 10. Edit the quantity twice

Open the entry from the Diary tab. Change 1 to 1.5, save. Open it again, change
1.5 back to 1, save.

**Expect:** 643 kcal again. Exactly.

**Proves:** the edit recomputes from the food's original per-serving figures
rather than scaling the stored total, so repeated edits do not compound
rounding error. The per-serving figures are now loaded once when the screen
opens, because the food table became a database query and `build` cannot wait
for one.

### 11. Log a meal offline, then come back

Airplane mode on. Log something. Note what it was.

**Expect:** it saves with no error and no spinner. The app does not complain
about being offline, because for a food diary that is the normal case.

Airplane mode off. Go to the Profile tab and tap **Sync now**.

**Expect:** a line saying what was pushed. Then check the server: open
`http://127.0.0.1:5000/diary` on the laptop and sign in as the same account —
the meal is there.

**Proves:** the offline-first path. The entry carried a UUID generated on the
phone, so it did not collide with anything, and the server accepted it with the
timestamp the phone recorded rather than the time it arrived.

### 12. Sign out with something unsynced

Airplane mode on. Log a meal. Profile tab, **Sign out**.

**Expect:** a dialog that names a number — "1 change could not be sent to your
account, so they exist only on this phone" — and a button reading **Sign out
anyway**. Cancel it.

Airplane mode off, **Sync now**, then **Sign out** again.

**Expect:** this time, "Everything on this device has been saved to your
account," and a plain **Sign out**.

**Proves:** signing out clears this device, because the local tables have no
owner column and the next person to sign in may be someone else. Since that
destroys data, sign-out pushes first, counts what is still pending, and says
the number out loud. A dialog that claimed your data was safe when it was not
would be worse than no dialog.

### 13. Two accounts on one phone

Sign in as a second account.

**Expect:** an empty diary. None of the first account's meals.

Sign back in as the first account and sync.

**Expect:** the first account's meals come back down from the server.

**Proves:** account separation on the device, and that signing out is
recoverable for anything that reached the server. This is the pass to repeat
in front of a marker.

### 14. A revoked token

With the app signed in and on the dashboard, revoke its session from the
laptop:

```
cd backend
python -c "import database; c=database.connect(); c.execute('DELETE FROM sessions'); c.commit()"
```

Now send the app to the background and bring it back.

**Expect:** the sign-in screen, with "Your session expired, so syncing stopped.
Sign in again to resume. Nothing recorded on this device has been lost."

Sign in again as the same account.

**Expect:** your diary is still there.

**Proves:** a rejected token is the one network failure the app is *not* silent
about, because nothing would ever sync again. And it forgets the token without
clearing the diary — deleting a user's meals because a token aged out is not a
trade worth making. This is why `forgetToken` and `clear` are separate.

### 15. Upgrading over an older install

Only if you have an older build on a phone. Install the new one over it without
uninstalling.

**Expect:** it opens, the diary is intact, and old entries still show their
nutrition. What they lose is the link back to a food — tapping an old entry
shows its stored figures rather than recomputing from the food table.

**Proves:** the schema 2 → 3 migration. Entries used to point at the 30
hand-entered foods by integer id; those foods are gone, so the migration sets
`food_id` to NULL rather than leaving pointers into a table that no longer
exists. An entry keeps its own copy of the nutrition, which is why nothing is
lost. `models_test.dart` also covers an integer arriving in that column, since
`as String?` on an int would have taken the whole diary down.

### 16. Discover, with and without a server

Discover tab with Flask running, then with it stopped.

**Expect:** recipes either way. With the server you get TheMealDB through the
backend's cache; without it you get the 25 bundled recipes, and the screen says
which you are looking at.

**Proves:** the three-step fallback chain. Check an allergen filter while you
are there — set peanuts in your profile and confirm satay does not come back.

---

## What the server side already does

Run against the live Flask server over real HTTP, not a test client — the
difference matters, because the one bug this caught was invisible to the test
client:

| Check | Result |
|---|---|
| `/api/ping` | 200, `{"ok": true, "service": "nutriapp-diary"}` |
| `POST /api/register` | 201, token + user, no password hash in the response |
| `GET /api/me` before setup | 200, `has_profile: false` |
| `GET /api/foods?q=rice` with a token, no profile | **200 `application/json`** |
| `GET /api/foods` with no token | 401 |
| `POST /sync` push | `applied: 1`, cursor advanced |
| A second account pulling from scratch | 0 entries |
| A second account pushing an entry carrying the first's id | both rows survive, separately — the first account still reads its own |
| `POST /api/logout`, then reusing the token | 200, then 401 |

Two of those are the security properties worth stating in a report. The
`/api/foods` one returned a 302 redirect to an HTML setup page until the
profile gate was made page-only: the app would have received a login form where
it expected JSON. And the last-but-one is the composite primary key
`(user_id, id)` doing its job — without it, an entry id from one account
overwrote another account's row and took ownership of it.

`python tests.py` in `backend/` runs 185 unit tests; `tools/smoke_backend.py`
drives every route against a throwaway database. Both pass on SQLite and on
Postgres.

---

## What is not tested, and what I cannot test

Stated plainly so you are not surprised by it in a viva.

- **The 106 tests do not touch the database or the network.** They cover pure
  logic, row and JSON parsing, and the drawing widgets. Everything involving
  sqflite, the bundled food file or an HTTP call is covered by the phone
  passes above, not by `flutter test`.
- **The 75-second auth timeout is not covered by a test**, because
  `Api._client` is not injectable and so a slow server cannot be mocked
  without refactoring.
- **The token is stored in plain text** in the app's private database, not in
  the Android Keystore. On a normal phone only this app can read it; a rooted
  device or a backup extraction would yield it. `flutter_secure_storage` is the
  fix, and `session.dart` is the only file that would change.
- **No password reset and no email verification.** Use a password you will
  remember; there is no way back.
- **No AppManager admin panel.** Out of scope by your own choice.
- **Sync conflicts are last-write-wins** on `updated_at`, with the clock
  clamped to within five minutes of the server's. Two phones editing the same
  entry while both offline is not a case I can test with one phone.
- **The food table is read-only and ships with the app.** A correction from HPB
  needs a new build, not a database update.
