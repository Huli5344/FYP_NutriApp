# Admin panel: design notes

Why each page is built the way it is, and why certain obvious-looking features
are deliberately absent.

This text used to sit at the bottom of the pages themselves. It was moved here
because an administrator reading a table does not need a paragraph of
reasoning underneath it every time, but the reasoning is still worth keeping:
most of it explains an *absence*, and an absence with no recorded reason tends
to get filled in by the next person.

`ADMIN.md` is the operational document — how to grant access, what each page
reads, how to deploy. This one is the rationale.

---

## Overview

**Where the numbers come from.** The app's backend and this panel are one
service sharing one database, so the counts are the rows the app is serving,
at the moment the page is drawn. Nothing is cached, scheduled or seeded. An
empty table shows as empty rather than as a placeholder figure.

That is the whole point of the integration. The panel arrived with five
fictional users and a set of hardcoded headline figures — "2,450 verified
items", "1,284 weekly logs" — which made it a convincing screenshot and a
useless tool. A number on an admin page is only worth having if it is a count
of something real.

---

## Users

**There is no delete button, and no editing of anybody else's name, email,
goal or diary.**

Deleting an account destroys that person's food diary. The only person who
should be able to do that is its owner, and the app already allows it — the
profile screen, re-enter password, confirm. A one-click version here, with no
password and no undo, would be a strictly worse way to do the same thing.

Editing someone else's profile is a similar trade. Changing an email changes
how they sign in; changing a goal silently changes their calorie target. Both
are things a support conversation should end in the *user* doing, not
something done to them while they are not looking.

What an administrator can do instead is **block** and **unblock** sign-in, and
**promote** and **demote** administrators. Both are reversible, and neither
destroys anything.

**Accounts with no profile are shown as "Setup not finished".** The query uses
a LEFT JOIN specifically to keep them visible. An inner join would silently
drop every account that registered and stopped — which is the most interesting
row on the page, not the least.

---

## Blocking

Blocking does two things: it refuses sign-in, and it deletes every session on
the account.

The second half is what makes it mean anything. Without it, the account keeps
working on every device already signed in — for up to thirty days, until the
tokens expire — while the panel displays it as blocked. The panel would be
lying, and lying in the direction that matters.

A blocked person is told their account is blocked, not that their password is
wrong. The vague "email or password is incorrect" exists so an attacker cannot
learn which addresses are registered; that reason is spent once the password
has already been accepted. Telling a blocked user their password is wrong
sends them into a reset loop that cannot possibly help them.

The flag is enforced twice over: sessions are deleted, *and* the token path
refuses a blocked account even if a token somehow survives. Either one alone
makes an API call fail, which is why each has its own test — a single test
could not tell which of the two was doing the work.

---

## Dietary goals

**Where the adjustment is applied.** A daily target starts from the
Mifflin–St Jeor estimate, is multiplied by the activity level, then has the
goal's adjustment added. The result is clamped before it is stored, so no goal
can produce a target outside the safe range.

Goals nobody has chosen are still listed, showing zero. A zero is information;
a missing row looks like an oversight.

---

## Food database

**There is no edit button.** These are the Health Promotion Board's published
figures. Editing one here would create a number that looks official and cites
nothing.

It would not even achieve what someone reaching for it would want: the diary
stores a copy of the nutrition at the moment a meal is logged, so changing a
food now does not correct a single past entry. Foods the dataset lacks are
added by people themselves, in the app, and are counted separately as
user-added foods.

---

## Categories and tags

Food groups are the dataset's own and are not ours to rename.

Separately from them, every diary entry is filed under breakfast, lunch,
dinner or snacks. The app picks one from the time of day and the person can
change it. The split used to divide a daily target between those is on the
Rules and metrics page.

---

## Preferences and allergens

**How the filter uses these.** An allergen on a profile removes every meal
declaring it, and the check runs again when a meal is saved — so a page
rendered before an allergy was recorded cannot write an unsafe entry.

A meal with no declared allergen list is treated as **unknown**, not as safe.
This is the single most important rule in the feature: an empty list and a
safe list look identical, and defaulting to "safe" would let every untagged
food through every filter silently.

The page also lists allergens that the app offers but nobody has recorded. The
gap between offered and chosen is worth seeing — an allergen nobody records is
a question nobody needed asked.

---

## Recipe service

**Why there is no import button.** The panel was originally written against
the Edamam Nutrition API, with a sync that wrote results into a recipe table.
This project does not use Edamam. Nutrition comes from the HPB dataset; meal
suggestions come from TheMealDB, whose calorie figures are estimated from the
ingredient list — which is why the app labels them as estimated wherever they
appear.

An import would write those estimated figures into the same table as published
ones, and nothing downstream could tell them apart afterwards. The fallback
chain is: TheMealDB, then the cache, then the local meals stored with the
module.

TheMealDB's attribution line stays on the page. That is a condition of using
the service, not commentary.

---

## Rules and metrics

**Why this page has no edit controls.** These values live in the server's
code, which is what actually computes every target. A form here could only
write them somewhere else, leaving two sets of numbers and no way to tell
which one a given target came from.

The page reads the constants out of `logic.py` at render time rather than
repeating them in the template, so changing a multiplier in the code changes
the page. A rules page kept in sync by hand is a rules page that is eventually
wrong.

Changing a rule is a code change and a deploy, deliberately.

---

## Reports

**There is no export button.** The figures here are aggregates across
accounts. A per-person export is somebody's food diary, and handing that out
from an admin page is a decision worth making on purpose rather than by adding
a button to a page that already has several.

---

## Sessions

**What this page is.** The `sessions` table: one row per device holding a
token the server would currently accept. Expired rows are excluded, because a
session that no longer works is not a way in and listing it as one would
misreport who can reach an account.

**What it is not.** An audit trail. The original panel kept an events table
and appended a row whenever an administrator clicked something — so it
recorded only what the panel itself did, while being blind to every sign-in,
every sync and every API call. It read as an audit trail without being one.

A real audit log would need its own append-only table written on every action.
Worth adding; not worth faking in the meantime.

---

## Roles and access

**There is no permission matrix.** The panel was first written against a
three-role model — free user, paid user, administrator — with a row per
permission. This project has no paid tier and no per-feature permissions:
there are accounts, and some of them have the administrator flag. Every
feature in the app is available to every account.

Rendering fourteen rows of Yes and No describing a system that was never built
would read as documentation, and the first person to rely on it would be
relying on nothing.

**Granting the first administrator.** A freshly deployed database has none, so
the panel is reachable by nobody — the right starting state for something that
can see and block every account. The first is granted with
`tools/make_admin.py`; after that, administrators promote each other.

Two refusals are built in, because each is one click from a panel nobody can
open:

* You cannot block your own account. Blocking deletes your sessions, so the
  click would sign you out of the page needed to undo it.
* The last remaining administrator cannot be demoted. `make_admin.py` refuses
  the same change, since it is the tool you would reach for to fix a mistake.

---

## Access control

Not a page, but the reasoning behind every page.

A signed-in account that is not an administrator gets **404**, not 403. A 403
confirms that `/admin` exists and that this person is merely not on the list,
which is a fact worth not handing out. To an ordinary account the panel is not
forbidden — it is absent.

The check is a blueprint `before_request` rather than a decorator on each
view. A decorator you have to remember is one somebody eventually forgets, and
here that would mean an unauthenticated page listing every account. As written
there is no way to add a route to this blueprint that skips the check.
