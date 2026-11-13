"""Nutri App backend: web prototype and the JSON API the Android app uses.

Run locally against SQLite:
    pip install -r requirements.txt
    python app.py
    open http://127.0.0.1:5000

Run against the hosted database:
    export DATABASE_URL="postgresql://user:pass@host/db?sslmode=require"
    python app.py

All calculation lives in logic.py, which imports neither Flask nor a database
driver and can be tested on its own. All SQL goes through database.py, which
goes through db.py -- the only module that knows whether it is talking to
Postgres or SQLite.

Everything that belongs to a person is scoped by `user_id`, taken from the
signed-in session (web) or the bearer token (app). The scoping is not optional
and not applied per query by hand: see `scoped_user` and the helpers below,
which take a user and refuse to build a query without one.
"""

import functools
import os
import uuid
from datetime import date, datetime, timedelta, timezone

from flask import (Flask, flash, g, jsonify, redirect, render_template,
                   request, session, url_for)

import accounts
import admin
import database
import db
import logic
import recipes_api
import sync

app = Flask(__name__)

# The staff panel, at /admin. Every route in it is behind an is_admin check
# applied by the blueprint itself -- see admin.require_admin.
app.register_blueprint(admin.bp)

# A fixed key would let anyone forge a session cookie and sign in as any
# user, so it comes from the environment in deployment. The fallback exists
# so a local run works out of the box.
#
# The guard is here at import, not in the __main__ block below: gunicorn
# imports this module and never runs that block, so a warning printed there
# would be invisible in exactly the deployment it was written for. PORT is
# set by Render, Railway, Heroku and every host of that shape, and is
# normally unset locally, which makes it a good enough signal that this is
# not a development machine.
#
# Failing the boot is deliberate. Serving with a published key is worse than
# not serving: it looks like it works, and anyone who reads this file can
# mint a session for any account.
SECRET_KEY = os.environ.get("SECRET_KEY")
if not SECRET_KEY and os.environ.get("PORT"):
    raise RuntimeError(
        "SECRET_KEY is not set, and PORT is -- so this looks like a hosting "
        "platform. Refusing to start: session cookies would be signed with "
        "a key published in this file, and anyone could forge one and sign "
        "in as any user. Set SECRET_KEY in the service's environment; "
        "render.yaml asks Render to generate one.")
app.secret_key = SECRET_KEY or "local-development-key"

# cache and a local fallback.
# Set NUTRIAPP_API=off to force the offline path for a demonstration.
USE_EXTERNAL_API = os.environ.get("NUTRIAPP_API", "on").lower() != "off"

# Endpoints reachable without being signed in. Everything else requires a
# user, so a route added later is private by default rather than public by
# accident -- the failure mode of an allow-list is a locked door, which gets
# noticed, and the failure mode of a deny-list is an open one, which does not.
PUBLIC_ENDPOINTS = {
    "static", "login", "register", "api_ping", "api_register", "api_login",
    # Public so a deployment can be checked before an account exists on it.
    # It reports whether the database answers and how many foods are loaded --
    # nothing about any user, so there is nothing here to leak.
    "api_health",
}

# Pages that measure something need a profile to measure against, but must not
# redirect to the page that creates one.
SETUP_EXEMPT = PUBLIC_ENDPOINTS | {"profile_setup", "logout", "api_recipes",
                                   "sync_entries", "api_logout", "api_me",
                                   # Someone who never finished setup must
                                   # still be able to delete their account.
                                   "api_delete_account"}

# Endpoints that must not open a database connection.
#
# This is not a micro-optimisation, it is a billing cliff. /api/ping answers
# "is the server up?", and on a free host that sleeps after fifteen idle
# minutes something has to poll it to keep it awake. If answering that poll
# opened a connection, the poll would wake the *database* too -- and Neon's
# free plan bills compute by the hour, with scale-to-zero after five idle
# minutes that cannot be switched off.
#
# The arithmetic: 100 CU-hours a month at the 0.25 CU minimum is 400 hours of
# active compute, against roughly 720 hours in a month. A ping every five
# minutes never lets the compute suspend, which is about 180 CU-hours -- so the
# database would suspend itself around two thirds of the way through the month
# and stay suspended until the next billing period. Not slow: off.
#
# Answered without a connection, the keep-warm poll costs nothing, and the
# database wakes only when somebody actually uses the app.
DB_FREE_ENDPOINTS = {"static", "api_ping"}


def wants_json():
    """True when this request should be answered with JSON rather than a page.

    The app's endpoints all live under /api or /sync; the browser prototype
    gets redirects. Deciding from the path rather than the Accept header keeps
    the behaviour predictable when a browser visits an API route by hand.
    """
    return request.path.startswith(("/api/", "/sync"))


@app.before_request
def load_user_and_profile():
    """Resolve the caller, then their profile, for the duration of the request.

    Read per request rather than cached in a module global: a global would
    serve whatever was true when the process started, so an edit would look
    like it had been ignored until a restart -- and with more than one account
    it would serve the wrong person's data entirely.
    """
    g.user = None
    g.token = None

    # See DB_FREE_ENDPOINTS. Set the profile defaults anyway so nothing
    # downstream has to care which branch it came through.
    if request.endpoint in DB_FREE_ENDPOINTS:
        g.profile = database.profile_dict(None)
        g.has_profile = False
        return None

    conn = database.connect()
    try:
        token = accounts.bearer_token(request.headers)
        if token:
            g.user = accounts.user_for_token(conn, token)
            g.token = token if g.user else None
        elif session.get("user_id"):
            g.user = accounts.find_user_by_id(conn, session["user_id"])
            if g.user is None:
                session.pop("user_id", None)   # account deleted under us

        if g.user is None:
            g.profile = database.profile_dict(None)
            g.has_profile = False
            if request.endpoint not in PUBLIC_ENDPOINTS:
                if wants_json():
                    return jsonify({"error": "authentication required"}), 401
                return redirect(url_for("login", next=request.path))
            return None

        row = database.profile_row(conn, g.user["id"])
        g.profile = database.profile_dict(row)
        g.has_profile = row is not None
    finally:
        conn.close()

    # The profile gate is for pages: a browser with no profile is sent to make
    # one, because the pages after it measure against a target that does not
    # exist yet. An API caller is not redirected -- an HTML redirect in answer
    # to a JSON request is just a parse error at the other end. The app asks
    # /api/me whether setup is done and decides for itself.
    # The admin panel is exempt as a whole. It measures nothing against a
    # target, so it has nothing to redirect for -- and a staff account that
    # has never used the app as a diary would otherwise be sent to set up a
    # weight goal before it could look at the user list.
    if (not g.has_profile and not wants_json()
            and request.endpoint not in SETUP_EXEMPT
            and not (request.endpoint or "").startswith("admin.")):
        return redirect(url_for("profile_setup"))
    return None


def scoped_user():
    """The signed-in user's id, or a refusal.

    Every per-person query goes through this rather than reading `g.user`
    directly, so a route that forgets to check raises here instead of quietly
    running an unscoped query across every account.
    """
    user = getattr(g, "user", None)
    if user is None:
        raise PermissionError("this query requires a signed-in user")
    return user["id"]


def login_required(view):
    @functools.wraps(view)
    def wrapper(*args, **kwargs):
        if getattr(g, "user", None) is None:
            if wants_json():
                return jsonify({"error": "authentication required"}), 401
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)
    return wrapper


@app.context_processor
def inject_globals():
    return {
        "profile": getattr(g, "profile", database.profile_dict(None)),
        "has_profile": getattr(g, "has_profile", False),
        "user": getattr(g, "user", None),
        "today": date.today(),
        "logic": logic,
    }



# Shared queries
#
# `substr(eaten_at, 1, 10)` rather than SQLite's `date()`: eaten_at is stored
# as an ISO-8601 string, so the first ten characters are the calendar day on
# either engine, and no dialect branch is needed.
def entries_for(day):
    conn = database.connect()
    rows = conn.execute(
        "SELECT * FROM entries WHERE user_id=? AND substr(eaten_at,1,10)=?"
        " AND deleted=0 ORDER BY eaten_at",
        (scoped_user(), day.isoformat())).fetchall()
    conn.close()
    return rows


def entries_between(first, last):
    conn = database.connect()
    rows = conn.execute(
        "SELECT * FROM entries WHERE user_id=?"
        " AND substr(eaten_at,1,10) BETWEEN ? AND ? AND deleted=0"
        " ORDER BY eaten_at",
        (scoped_user(), first.isoformat(), last.isoformat())).fetchall()
    conn.close()
    return rows


def todays_summary():
    entries = entries_for(date.today())
    return entries, logic.summarise_day(
        entries, g.profile["target_kcal"],
        logic.macro_split_for(g.profile["goal"]))



#Home dashboard
@app.route("/")
def dashboard():
    entries, summary = todays_summary()
    next_meal = logic.categorise_by_time(datetime.now())
    next_meal_left = logic.remaining_for_meal(summary, next_meal)

    # what was eaten under each meal, not a flat entry list.
    by_meal = {c: [e for e in entries if e["category"] == c] for c in logic.CATEGORIES}

    # The frame carries one suggestion. Failing to reach the service does
    # not take the dashboard down with it
    teaser = None
    try:
        recipes, _, _ = load_recipes()
        picks = logic.recommend(recipes, g.profile["allergens"], g.profile["diet_type"],
                                next_meal_left or 600, limit=1)
        teaser = picks[0] if picks else None
    except Exception as exc:                      # noqa: BLE001 - never fatal here
        app.logger.warning("Dashboard suggestion unavailable: %s", exc)

    return render_template("home.html", summary=summary, entries=entries,
                           by_meal=by_meal, next_meal=next_meal,
                           next_meal_left=next_meal_left, teaser=teaser,
                           allergens=g.profile["allergens"])



# Add food and serving
@app.route("/add", methods=["GET", "POST"])
def add_food():
    """Search the food table, pick a serving, write a diary entry.

    The entry stores a copy of the nutrition rather than a reference to the
    food: a diary is a record of what someone ate, so a later correction to
    the food table must not silently rewrite last week's lunch. `food_id` is
    kept as provenance only.
    """
    conn = database.connect()
    user_id = scoped_user()

    if request.method == "POST":
        food = database.food_dict(
            database.food_by_id(conn, request.form.get("food_id", "")))
        if not food:
            conn.close()
            flash("Pick a food before saving.", "error")
            return redirect(url_for("add_food"))

        quantity = max(0.25, float(request.form.get("quantity") or 1))
        eaten_at = request.form.get("eaten_at") or datetime.now().isoformat(timespec="minutes")
        nutrition = logic.scale_nutrition(food, quantity)
        category = request.form.get("category") or logic.categorise_by_time(eaten_at)
        tags = logic.auto_tags(nutrition)

        entry_id = str(uuid.uuid4())
        conn.execute(
            "INSERT INTO entries (id,user_id,food_id,food_name,quantity,serving,"
            "kcal,carbs_g,protein_g,fat_g,category,tags,note,eaten_at,source,"
            "deleted,updated_at,server_seq)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)",
            (entry_id, user_id, food["food_id"], food["name"], quantity,
             food["serving_label"],
             nutrition["kcal"], nutrition["carbs_g"], nutrition["protein_g"],
             nutrition["fat_g"], category, ",".join(tags),
             request.form.get("note", ""), eaten_at, "manual",
             sync.now_iso(), database.next_seq(conn)))
        conn.commit()
        conn.close()
        flash(f"{food['name']} added to {category}.", "ok")
        return redirect(url_for("saved", entry_id=entry_id))

    query = request.args.get("q", "").strip()
    selected_id = request.args.get("food_id", "").strip()
    quantity = float(request.args.get("quantity") or 1)

    results = [database.food_dict(r)
               for r in database.search_foods(conn, query, limit=20)]

    selected = preview = tags = None
    if selected_id:
        selected = database.food_dict(database.food_by_id(conn, selected_id))
        if selected:
            preview = logic.scale_nutrition(selected, quantity)
            tags = logic.auto_tags(preview)
    conn.close()

    now = datetime.now()
    return render_template("add.html", q=query, results=results, selected=selected,
                           quantity=quantity, preview=preview, tags=tags,
                           categories=logic.CATEGORIES,
                           suggested=logic.categorise_by_time(now),
                           now=now.isoformat(timespec="minutes"))


# Edit or delete an entry
@app.route("/entry/<entry_id>", methods=["GET", "POST"])
def edit_entry(entry_id):
    conn = database.connect()
    entry = conn.execute(
        "SELECT * FROM entries WHERE id=? AND user_id=? AND deleted=0",
        (entry_id, scoped_user())).fetchone()
    if not entry:
        conn.close()
        flash("That entry no longer exists.", "error")
        return redirect(url_for("diary"))

    if request.method == "POST":
        if request.form.get("action") == "delete":
            # Tombstone rather than DELETE: a removed row would be handed
            # straight back by the next pull and reappear in the diary.
            conn.execute(
                "UPDATE entries SET deleted=1, updated_at=?, server_seq=?"
                " WHERE id=? AND user_id=?",
                (sync.now_iso(), database.next_seq(conn), entry_id,
                 scoped_user()))
            conn.commit()
            conn.close()
            flash("Entry deleted. Today's total updated.", "ok")
            return redirect(url_for("diary"))

        quantity = max(0.25, float(request.form.get("quantity") or 1))
        food = database.food_dict(
            database.food_by_id(conn, entry["food_id"])) if entry["food_id"] else None
        # Recompute from the original per-serving values rather than from the
        # stored totals, so repeated edits do not compound rounding error.
        if food:
            per_serving = food
        else:
            per_serving = {k: entry[k] / entry["quantity"]
                           for k in ("kcal", "carbs_g", "protein_g", "fat_g")}
        nutrition = logic.scale_nutrition(per_serving, quantity)

        conn.execute(
            "UPDATE entries SET quantity=?, kcal=?, carbs_g=?, protein_g=?, fat_g=?,"
            " category=?, tags=?, note=?, updated_at=?, server_seq=?"
            " WHERE id=? AND user_id=?",
            (quantity, nutrition["kcal"], nutrition["carbs_g"], nutrition["protein_g"],
             nutrition["fat_g"], request.form["category"],
             ",".join(logic.auto_tags(nutrition)), request.form.get("note", ""),
             sync.now_iso(), database.next_seq(conn), entry_id, scoped_user()))
        conn.commit()
        conn.close()
        flash("Entry updated.", "ok")
        return redirect(url_for("diary"))

    conn.close()
    month = date.fromisoformat(entry["eaten_at"][:10]).strftime("%b")
    return render_template("entry.html", entry=entry, categories=logic.CATEGORIES,
                           month=month)


# Today's diary
@app.route("/diary")
def diary():
    entries, summary = todays_summary()
    grouped = {c: [e for e in entries if e["category"] == c] for c in logic.CATEGORIES}
    return render_template("diary.html", summary=summary, grouped=grouped,
                           day=date.today())


# Recommendations
def local_recipes():
    """The meals seeded with the module. Last step of the fallback chain."""
    conn = database.connect()
    rows = conn.execute("SELECT * FROM recipes").fetchall()
    conn.close()
    return database.recipe_dicts(rows)


def load_recipes():
    """Try TheMealDB, fall back to the cache, then to local meals.

    Returns (recipes, origin, warning). The origin is shown on screen, because
    a fallback that happens silently is indistinguishable from a bug.
    """
    if not USE_EXTERNAL_API:
        return local_recipes(), "local", "External recipe service is switched off."

    diet = g.profile["diet_type"]
    categories = recipes_api.DIET_CATEGORIES.get(diet, recipes_api.DIET_CATEGORIES["balanced"])
    # Ask for roughly twice what is shown, spread across the categories that
    # suit the diet type, because the allergen filter removes some of them.
    wanted = logic.RECOMMENDATIONS_SHOWN * 2
    per_category = max(6, -(-wanted // len(categories)))

    try:
        recipes, origin = recipes_api.fetch_for_diet(diet, per_category=per_category)
    except recipes_api.ApiError as exc:
        app.logger.warning("TheMealDB unavailable: %s", exc)
        return (local_recipes(), "local",
                "TheMealDB could not be reached, so these come from the meals "
                "stored with the module.")

    # A category can hold fewer meals than asked for, and the allergen filter
    # removes more. Top up from the local set rather than showing a short list.
    safe = [r for r in recipes if logic.is_safe_for(r, g.profile["allergens"])]
    if len(safe) < logic.RECOMMENDATIONS_SHOWN:
        have = {r["name"].lower() for r in recipes}
        recipes = recipes + [r for r in local_recipes() if r["name"].lower() not in have]
        return (recipes, origin,
                "TheMealDB returned fewer meals than usual, so some of these come "
                "from the meals stored with the module.")

    return recipes, origin, None


def recently_shown():
    conn = database.connect()
    rows = conn.execute(
        "SELECT recipe_id FROM shown WHERE user_id=? ORDER BY id DESC LIMIT 6",
        (scoped_user(),)).fetchall()
    conn.close()
    # Ids are strings ("mdb-52772", "local-3"); never parse them as integers.
    return {r["recipe_id"] for r in rows}


def resolve_recipe(recipe_id):
    """Fetch one recipe by its namespaced id, from whichever source owns it."""
    recipe_id = str(recipe_id)
    if recipe_id.startswith("mdb-"):
        try:
            recipe, _ = recipes_api.fetch_one(recipe_id[4:])
            return recipe
        except recipes_api.ApiError:
            return None
    numeric = recipe_id[6:] if recipe_id.startswith("local-") else recipe_id
    if not numeric.isdigit():
        return None
    conn = database.connect()
    row = conn.execute("SELECT * FROM recipes WHERE id=?", (int(numeric),)).fetchone()
    conn.close()
    return database.recipe_dicts([row])[0] if row else None


@app.route("/discover")
def discover():
    _, summary = todays_summary()
    slot = request.args.get("slot") or logic.categorise_by_time(datetime.now())
    slot_left = logic.remaining_for_meal(summary, slot)

    recipes, origin, warning = load_recipes()
    refreshing = request.args.get("refresh") == "1"
    expanded = request.args.get("more") == "1"

    # Ranking is deterministic for the same inputs, so expanding the list keeps
    # the first three exactly where they were and appends the next five below.
    recent = recently_shown() if refreshing else set()
    limit = logic.SHOWN_EXPANDED if expanded else logic.SHOWN_INITIALLY
    ranked = logic.recommend(recipes, g.profile["allergens"], g.profile["diet_type"],
                             slot_left or 600, recent, limit=logic.SHOWN_EXPANDED)
    picks = ranked[:limit]

    if refreshing:
        conn = database.connect()
        conn.executemany(
            "INSERT INTO shown (user_id, recipe_id, shown_at) VALUES (?,?,?)",
            [(scoped_user(), p["id"],
              datetime.now().isoformat(timespec="seconds")) for p in picks])
        conn.commit()
        conn.close()

    hidden = [r for r in recipes if not logic.is_safe_for(r, g.profile["allergens"])]
    return render_template("discover.html", picks=picks, slot=slot,
                           slot_left=slot_left, hidden=hidden,
                           allergens=g.profile["allergens"], summary=summary,
                           origin=origin, warning=warning, expanded=expanded,
                           more_available=len(ranked) - len(picks),
                           first_batch=logic.SHOWN_INITIALLY,
                           attribution=recipes_api.ATTRIBUTION)


# Recommendation detail
@app.route("/discover/<recipe_id>")
def recipe_detail(recipe_id):
    recipe = resolve_recipe(recipe_id)
    if not recipe:
        flash("That meal could not be loaded. Try another.", "error")
        return redirect(url_for("discover"))

    slot = request.args.get("slot", "dinner")
    return render_template("recipe.html", r=recipe, slot=slot,
                           categories=logic.CATEGORIES,
                           clear=logic.is_safe_for(recipe, g.profile["allergens"]),
                           allergens=g.profile["allergens"],
                           attribution=recipes_api.ATTRIBUTION)


@app.route("/discover/<recipe_id>/save", methods=["POST"])
def save_recipe(recipe_id):
    """Writes the suggestion into the diary as a full entry."""
    recipe = resolve_recipe(recipe_id)
    if not recipe:
        flash("That meal could not be loaded. Nothing was saved.", "error")
        return redirect(url_for("discover"))

    conn = database.connect()
    # Re-check at the moment of saving. A page rendered before an allergy was
    # recorded must not be able to write an unsafe entry.
    if not logic.is_safe_for(recipe, g.profile["allergens"]):
        conn.close()
        flash("That meal lists an ingredient you are allergic to. Not saved.", "error")
        return redirect(url_for("discover"))

    eaten_at = datetime.now().isoformat(timespec="minutes")
    category = request.form.get("category") or logic.categorise_by_time(eaten_at)
    nutrition = {k: recipe[k] for k in ("kcal", "carbs_g", "protein_g", "fat_g")}

    entry_id = str(uuid.uuid4())
    conn.execute(
        "INSERT INTO entries (id,user_id,food_id,food_name,quantity,serving,kcal,"
        "carbs_g,protein_g,fat_g,category,tags,note,eaten_at,source,deleted,"
        "updated_at,server_seq)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)",
        (entry_id, scoped_user(), None, recipe["name"], 1, "1 serving",
         nutrition["kcal"],
         nutrition["carbs_g"], nutrition["protein_g"], nutrition["fat_g"], category,
         ",".join(logic.auto_tags(nutrition)),
         "From recommendations, estimated values" if recipe.get("estimated")
         else "From recommendations",
         eaten_at, recipe.get("source", "recommendation"),
         sync.now_iso(), database.next_seq(conn)))
    conn.commit()
    conn.close()
    return redirect(url_for("saved", entry_id=entry_id))


# Saved to diary
@app.route("/saved/<entry_id>")
def saved(entry_id):
    """Confirmation showing the entry and the totals it moved.

    user can see the day's figures change without opening the diary.
    """
    conn = database.connect()
    entry = conn.execute(
        "SELECT * FROM entries WHERE id=? AND user_id=? AND deleted=0",
        (entry_id, scoped_user())).fetchone()
    conn.close()
    if not entry:
        return redirect(url_for("diary"))

    # Summarise the day the entry belongs to, not today. A backdated meal
    # otherwise gets compared against today's totals, which reads as nonsense:
    # "before 2,760 left, now 1,850 left" for an entry nine days ago.
    day = date.fromisoformat(entry["eaten_at"][:10])
    summary = logic.summarise_day(entries_for(day), g.profile["target_kcal"])
    before = summary["remaining"] + entry["kcal"]
    same_meal = [e for e in entries_for(day) if e["category"] == entry["category"]]
    return render_template("saved.html", entry=entry, summary=summary,
                           before=before, day=day, is_today=(day == date.today()),
                           same_meal=same_meal)


# Recipe service
@app.route("/api-status")
def api_status():
    """Shows whether the external call works, and what the cache holds."""
    result = None
    if request.args.get("test") == "1":
        result = recipes_api.test_connection()

    conn = database.connect()
    cached = conn.execute("SELECT COUNT(*) c FROM api_cache").fetchone()["c"]
    newest = conn.execute("SELECT MAX(fetched_at) m FROM api_cache").fetchone()["m"]
    conn.close()

    return render_template("api_status.html", result=result,
                           stats=recipes_api.stats(), cached=cached, newest=newest,
                           enabled=USE_EXTERNAL_API,
                           base=recipes_api.BASE_URL.format(key=recipes_api.DEV_KEY),
                           ttl=recipes_api.CACHE_TTL_HOURS,
                           timeout=recipes_api.TIMEOUT_SECONDS,
                           attribution=recipes_api.ATTRIBUTION)


@app.route("/api-status/clear")
def api_cache_clear():
    conn = database.connect()
    conn.execute("DELETE FROM api_cache")
    conn.commit()
    conn.close()
    flash("Cache cleared. The next request will go to TheMealDB.", "ok")
    return redirect(url_for("api_status"))


@app.route("/undo/<entry_id>")
def undo(entry_id):
    """Remove the entry just written. The Undo control."""
    conn = database.connect()
    row = conn.execute(
        "SELECT food_name FROM entries WHERE id=? AND user_id=?",
        (entry_id, scoped_user())).fetchone()
    conn.execute("UPDATE entries SET deleted=1, updated_at=?, server_seq=?"
                 " WHERE id=? AND user_id=?",
                 (sync.now_iso(), database.next_seq(conn), entry_id,
                  scoped_user()))
    conn.commit()
    conn.close()
    flash(f"{row['food_name'] if row else 'Entry'} removed. Totals restored.", "ok")
    return redirect(url_for("dashboard"))


# Profile and goals

# Offered on the setup form. The same lists the app's onboarding screens use;
# every preference maps to a tag the recipe data carries, via logic.DIET_TOKENS.
GENDERS = ["Female", "Male", "Non-binary", "Prefer not to say"]
ACTIVITY_LEVELS = list(logic.ACTIVITY_MULTIPLIERS)
GOALS = list(logic.GOAL_ADJUSTMENTS)
PREFERENCE_OPTIONS = list(logic.DIET_TOKENS)
RESTRICTION_OPTIONS = list(logic.ALLERGEN_TOKENS)

# Wide on purpose. These catch a centimetre value typed into the kilogram box,
# not anyone's body.
BOUNDS = {
    "age": (13, 120),
    "height_cm": (90.0, 250.0),
    "weight_kg": (25.0, 400.0),
    "target_weight_kg": (25.0, 400.0),
}


def _read_profile_form(form):
    """Parse and validate the setup form.

    Returns (profile, errors). A profile is only built when errors is empty, so
    a half-parsed form can never reach the database.
    """
    errors = []

    def number(field, caster, required=True):
        raw = (form.get(field) or "").strip()
        if not raw:
            if required:
                errors.append(f"{field.replace('_', ' ').capitalize()} is required.")
            return None
        try:
            value = caster(raw)
        except ValueError:
            errors.append(f"{field.replace('_', ' ').capitalize()} must be a number.")
            return None
        low, high = BOUNDS[field]
        if not low <= value <= high:
            errors.append(f"{field.replace('_', ' ').capitalize()} must be "
                          f"between {low} and {high}.")
            return None
        return value

    name = (form.get("name") or "").strip()
    if not name:
        errors.append("Name is required.")

    age = number("age", int)
    height = number("height_cm", float)
    weight = number("weight_kg", float)

    goal = form.get("goal") or "Eat Healthier"
    uses_target = goal in ("Lose Weight", "Gain Weight", "Build Muscle")
    target_weight = (number("target_weight_kg", float, required=False)
                     if uses_target else None)

    manual = (form.get("target_kcal") or "").strip()
    manual_target = None
    if manual:
        try:
            manual_target = int(manual)
        except ValueError:
            errors.append("Daily target must be a whole number.")
        else:
            if not logic.MIN_DAILY_TARGET <= manual_target <= logic.MAX_DAILY_TARGET:
                errors.append(f"Daily target must be between "
                              f"{logic.MIN_DAILY_TARGET} and "
                              f"{logic.MAX_DAILY_TARGET} kcal.")
                manual_target = None

    if errors:
        return None, errors

    gender = form.get("gender") or None
    profile = logic.build_profile(
        name=name,
        email=(form.get("email") or "").strip(),
        age=age,
        gender=gender if gender in GENDERS else None,
        height_cm=height,
        weight_kg=weight,
        activity_level=form.get("activity_level") or "Moderately Active",
        goal=goal,
        target_weight_kg=target_weight,
        preferences=[p for p in form.getlist("preferences")
                     if p in PREFERENCE_OPTIONS],
        restrictions=[r for r in form.getlist("restrictions")
                      if r in RESTRICTION_OPTIONS],
        manual_target_kcal=manual_target,
        updated_at=sync.now_iso(),
    )
    return profile, []


@app.route("/profile/setup", methods=["GET", "POST"])
def profile_setup():
    """First-run setup, and the edit form afterwards."""
    if request.method == "POST":
        profile, errors = _read_profile_form(request.form)
        if errors:
            for message in errors:
                flash(message, "warn")
            return render_template(
                "profile_setup.html", form=request.form, genders=GENDERS,
                activity_levels=ACTIVITY_LEVELS, goals=GOALS,
                preference_options=PREFERENCE_OPTIONS,
                restriction_options=RESTRICTION_OPTIONS)

        conn = database.connect()
        database.save_profile(conn, scoped_user(), profile)

        # Seed the weight log from the stated weight so the trend has a
        # starting point without asking for the same number twice.
        existing = conn.execute("SELECT 1 FROM weights WHERE user_id=? LIMIT 1",
                                (scoped_user(),)).fetchone()
        if not existing:
            conn.execute(
                "INSERT INTO weights (id,user_id,kg,recorded_at,note,deleted,"
                "updated_at,server_seq) VALUES (?,?,?,?,?,0,?,?)",
                (str(uuid.uuid4()), scoped_user(), profile["weight_kg"],
                 datetime.now().isoformat(timespec="seconds"),
                 "From profile setup", sync.now_iso(),
                 database.next_seq(conn)))
        conn.commit()
        conn.close()

        flash(f"Profile saved. Your daily target is "
              f"{profile['target_kcal']} kcal.", "ok")
        return redirect(url_for("profile"))

    # Prefill from the stored profile when editing. The raw answers are what
    # the form needs, which is why they are stored alongside the tokens.
    stored = g.profile
    form = {
        "name": stored["name"] if g.has_profile else "",
        "email": stored["email"],
        "age": stored["age"] if g.has_profile else "",
        "gender": stored["gender"] or "",
        "height_cm": stored["height_cm"] if g.has_profile else "",
        "weight_kg": stored["weight_kg"] if g.has_profile else "",
        "activity_level": stored["activity_level"],
        "goal": stored["goal"],
        "target_weight_kg": stored["target_weight_kg"] or "",
        "target_kcal": stored["target_kcal"] if stored["target_is_manual"] else "",
        "preferences": stored["preferences"],
        "restrictions": stored["restrictions"],
    }
    return render_template("profile_setup.html", form=form, genders=GENDERS,
                           activity_levels=ACTIVITY_LEVELS, goals=GOALS,
                           preference_options=PREFERENCE_OPTIONS,
                           restriction_options=RESTRICTION_OPTIONS)


@app.route("/profile")
def profile():
    """The stored profile, with the target's working shown."""
    conn = database.connect()
    weights = [dict(r) for r in database.weight_rows(conn, scoped_user(), limit=10)]
    conn.close()

    p = g.profile
    bmr = logic.basal_metabolic_rate(p["age"], p["height_cm"], p["weight_kg"],
                                     p["gender"])
    multiplier = logic.ACTIVITY_MULTIPLIERS.get(
        p["activity_level"], logic.DEFAULT_ACTIVITY_MULTIPLIER)

    return render_template(
        "profile.html", weights=weights, bmr=bmr, multiplier=multiplier,
        maintenance=round(bmr * multiplier),
        adjustment=logic.GOAL_ADJUSTMENTS.get(p["goal"], 0),
        split=logic.macro_split_for(p["goal"]))


@app.route("/profile/weight", methods=["POST"])
def log_weight():
    """Record a weight and rebuild the target around it.

    The new weight changes the calculated figure, so the profile is rebuilt
    rather than left describing a body that has changed. A target set by hand
    is preserved.
    """
    raw = (request.form.get("kg") or "").strip()
    try:
        kg = float(raw)
    except ValueError:
        flash("Enter a weight in kilograms.", "warn")
        return redirect(url_for("profile"))

    low, high = BOUNDS["weight_kg"]
    if not low <= kg <= high:
        flash(f"Weight must be between {low} and {high} kg.", "warn")
        return redirect(url_for("profile"))

    p = g.profile
    conn = database.connect()
    conn.execute(
        "INSERT INTO weights (id,user_id,kg,recorded_at,note,deleted,updated_at,"
        "server_seq) VALUES (?,?,?,?,'',0,?,?)",
        (str(uuid.uuid4()), scoped_user(), kg,
         datetime.now().isoformat(timespec="seconds"),
         sync.now_iso(), database.next_seq(conn)))

    rebuilt = logic.build_profile(
        name=p["name"], email=p["email"], age=p["age"], gender=p["gender"],
        height_cm=p["height_cm"], weight_kg=kg,
        activity_level=p["activity_level"], goal=p["goal"],
        target_weight_kg=p["target_weight_kg"],
        preferences=p["preferences"], restrictions=p["restrictions"],
        manual_target_kcal=p["target_kcal"] if p["target_is_manual"] else None,
        updated_at=sync.now_iso())
    database.save_profile(conn, scoped_user(), rebuilt)
    conn.commit()
    conn.close()

    flash(f"Logged {kg} kg. Daily target is now "
          f"{rebuilt['target_kcal']} kcal.", "ok")
    return redirect(url_for("profile"))


@app.route("/insights")
def insights():
    """Data visualisation across a window of days."""
    try:
        days = int(request.args.get("days", logic.INSIGHTS_WINDOW_DAYS))
    except (TypeError, ValueError):
        days = logic.INSIGHTS_WINDOW_DAYS
    days = max(1, min(days, 90))

    today = date.today()
    entries = entries_between(today - timedelta(days=days - 1), today)

    conn = database.connect()
    weights = [dict(r) for r in database.weight_rows(conn, scoped_user())]
    conn.close()

    totals = logic.daily_totals([dict(e) for e in entries], today, days)
    trend = logic.summarise_trend(totals, g.profile["target_kcal"])

    return render_template(
        "insights.html", totals=totals, trend=trend, days=days,
        windows=[7, 14, 30],
        by_category=logic.category_totals(totals),
        weights=sorted(weights, key=lambda w: w["recorded_at"]),
        weight_change=logic.weight_change(weights),
        progress=logic.progress_towards_target(
            weights, g.profile["target_weight_kg"]),
        # The tallest bar sets the chart scale. Computed here so the template
        # holds no arithmetic.
        chart_max=max([t["kcal"] for t in totals]
                      + [g.profile["target_kcal"], 1]))


# JSON endpoints for the mobile client

@app.route("/api/ping")
def api_ping():
    """Reachability check for the app, and the keep-warm target for a host
    that sleeps.

    Deliberately touches no database -- see DB_FREE_ENDPOINTS for why that is
    load-bearing rather than tidy. "The web server is up" is all this claims;
    /api/health below is the one that checks the database, and it is not what
    you point a five-minute cron job at.
    """
    return jsonify({"ok": True, "service": "nutriapp-diary"})


@app.route("/api/health")
def api_health():
    """Is the database reachable, and does it have the food table in it?

    For checking a deployment by hand, not on a schedule: every call wakes
    Neon's compute and spends from the monthly allowance.
    """
    conn = database.connect()
    try:
        foods = conn.execute("SELECT COUNT(*) c FROM foods").fetchone()["c"]
    finally:
        conn.close()
    return jsonify({
        "ok": True,
        "database": "postgres" if db.is_postgres() else "sqlite",
        "foods": foods,
    })


@app.route("/api/recipes")
def api_recipes():
    """Meals for a diet type, already normalised for the client.

    The backend keeps the TheMealDB call, the calorie estimation and the
    allergen derivation. All three need a network anyway, so nothing is lost
    by leaving them here, and the API key stays off the device.
    """
    diet = request.args.get("diet", g.profile["diet_type"])
    try:
        recipes, origin = recipes_api.fetch_for_diet(diet)
        warning = None
    except recipes_api.ApiError as exc:
        app.logger.warning("TheMealDB unavailable: %s", exc)
        recipes, origin = local_recipes(), "local"
        warning = "TheMealDB could not be reached; these are the stored meals."

    return jsonify({
        "origin": origin,
        "warning": warning,
        "attribution": recipes_api.ATTRIBUTION,
        "recipes": recipes,
    })


# Sync

def _upsert(conn, table, row, key=("user_id", "id"), user_id=None):
    """Insert or replace a row, assigning it the next sequence number.

    The owner is stamped here from the authenticated session rather than taken
    from the pushed row: a client cannot choose whose diary it writes to.

    `key` is the conflict target and defaults to (user_id, id), matching the
    composite primary key. Conflicting on id alone would let a push carrying
    another account's row id overwrite that row -- the collision resolves to an
    UPDATE, and the UPDATE sets user_id from the pushed values.
    """
    if user_id is not None:
        row["user_id"] = user_id
    row["server_seq"] = database.next_seq(conn)

    keys = (key,) if isinstance(key, str) else tuple(key)
    columns = list(row.keys())
    placeholders = ",".join("?" for _ in columns)
    assignments = ",".join(f"{c}=excluded.{c}" for c in columns
                           if c not in keys)
    conn.execute(
        f"INSERT INTO {table} ({','.join(columns)}) VALUES ({placeholders}) "
        f"ON CONFLICT ({','.join(keys)}) DO UPDATE SET {assignments}",
        [row[c] for c in columns])


@app.route("/sync", methods=["POST"])
def sync_entries():
    """Push local changes and pull everything changed elsewhere, in one call.

    Request:  {"since": <int>, "changes": [ {entry}, ... ],
               "weights": [ {weight}, ... ],
               "custom_foods": [ {food}, ... ], "profile": {profile} | null}
    Response: {"server_time": iso, "cursor": <int>, "has_more": bool,
               "changes": [...], "weights": [...], "custom_foods": [...],
               "profile": {...} | null,
               "push": {applied, skipped, invalid}}

    The client stores `cursor` and sends it back as `since` next time. It is a
    sequence number rather than a timestamp, so paging cannot be thrown off by
    a device whose clock is wrong.

    All four collections share that one sequence, and the pull merges them
    into a single ordered page. Paging each table separately would advance the
    cursor past rows in another table that were never sent, and those rows
    would never be pulled again.
    """
    body = request.get_json(silent=True) or {}
    try:
        since = int(body.get("since", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "since must be an integer"}), 400

    incoming = body.get("changes") or []
    incoming_weights = body.get("weights") or []
    incoming_foods = body.get("custom_foods") or []
    incoming_profile = body.get("profile")

    if (not isinstance(incoming, list)
            or not isinstance(incoming_weights, list)
            or not isinstance(incoming_foods, list)):
        return jsonify(
            {"error": "changes, weights and custom_foods must be lists"}), 400
    if len(incoming) + len(incoming_weights) + len(incoming_foods) > 500:
        return jsonify({"error": "too many changes in one push"}), 413
    if incoming_profile is not None and not isinstance(incoming_profile, dict):
        return jsonify({"error": "profile must be an object"}), 400

    server_now = datetime.now(timezone.utc)
    user_id = scoped_user()
    applied = skipped = invalid = 0
    conn = database.connect()

    for raw in incoming:
        if not sync.is_valid(raw):
            invalid += 1
            continue
        row = sync.clean(raw, server_now)
        existing = conn.execute(
            "SELECT * FROM entries WHERE id=? AND user_id=?",
            (row["id"], user_id)).fetchone()
        if not sync.should_apply(row, dict(existing) if existing else None):
            skipped += 1
            continue
        _upsert(conn, "entries", row, user_id=user_id)
        applied += 1

    for raw in incoming_weights:
        if not sync.is_valid_weight(raw):
            invalid += 1
            continue
        row = sync.clean_weight(raw, server_now)
        existing = conn.execute(
            "SELECT * FROM weights WHERE id=? AND user_id=?",
            (row["id"], user_id)).fetchone()
        if not sync.should_apply(row, dict(existing) if existing else None):
            skipped += 1
            continue
        _upsert(conn, "weights", row, user_id=user_id)
        applied += 1

    for raw in incoming_foods:
        if not sync.is_valid_custom_food(raw):
            invalid += 1
            continue
        row = sync.clean_custom_food(raw, server_now)
        existing = conn.execute(
            "SELECT * FROM custom_foods WHERE id=? AND user_id=?",
            (row["id"], user_id)).fetchone()
        if not sync.should_apply(row, dict(existing) if existing else None):
            skipped += 1
            continue
        _upsert(conn, "custom_foods", row, user_id=user_id)
        applied += 1

    if incoming_profile is not None:
        if not sync.is_valid_profile(incoming_profile):
            invalid += 1
        else:
            row = sync.clean_profile(incoming_profile, server_now)
            existing = database.profile_row(conn, user_id)
            if sync.should_apply(row, dict(existing) if existing else None):
                row["user_id"] = user_id
                _upsert(conn, "profile", row, key="user_id")
                applied += 1
            else:
                skipped += 1

    conn.commit()

    # Pull after pushing, so the caller sees its own writes reflected back and
    # can confirm what the server actually stored.
    candidates = []
    limit = sync.PAGE_SIZE + 1
    for table, kind in (("entries", "changes"), ("weights", "weights"),
                        ("custom_foods", "custom_foods")):
        rows = conn.execute(
            f"SELECT * FROM {table} WHERE user_id=? AND server_seq > ?"
            " ORDER BY server_seq LIMIT ?", (user_id, since, limit)).fetchall()
        candidates.extend((kind, dict(r)) for r in rows)

    profile_out = conn.execute(
        "SELECT * FROM profile WHERE user_id=? AND server_seq > ?",
        (user_id, since)).fetchone()
    if profile_out is not None:
        candidates.append(("profile", dict(profile_out)))

    page, cursor, has_more = sync.page(candidates)
    if cursor is None:
        cursor = max(since, database.current_seq(conn))
    conn.close()

    return jsonify({
        "server_time": server_now.isoformat(timespec="seconds"),
        "cursor": cursor,
        "has_more": has_more,
        "changes": [row for kind, row in page if kind == "changes"],
        "weights": [row for kind, row in page if kind == "weights"],
        "custom_foods":
            [row for kind, row in page if kind == "custom_foods"],
        "profile": next((row for kind, row in page if kind == "profile"), None),
        "push": sync.summarise(applied, skipped, invalid),
    })


@app.route("/reset")
def reset():
    """Clear this user's diary so the app can be demonstrated again.

    Scoped to the signed-in account: a reset must not be able to empty anyone
    else's diary. The sequence counter is deliberately left alone -- it is
    shared, and winding it back would make other devices' cursors point past
    rows that still exist.

    Leaves the profile alone. Clearing the diary for another run-through should
    not make someone re-enter their height.
    """
    user_id = scoped_user()
    conn = database.connect()
    conn.execute("DELETE FROM entries WHERE user_id=?", (user_id,))
    conn.execute("DELETE FROM shown WHERE user_id=?", (user_id,))
    conn.commit()
    conn.close()
    flash("Diary cleared. Ready for another run-through.", "ok")
    return redirect(url_for("dashboard"))


@app.route("/reset/all")
def reset_everything():
    """Clear everything this user has, profile included."""
    user_id = scoped_user()
    conn = database.connect()
    for table in ("entries", "weights", "shown", "profile"):
        conn.execute(f"DELETE FROM {table} WHERE user_id=?", (user_id,))
    conn.commit()
    conn.close()
    flash("Everything cleared. Set up a profile to start again.", "ok")
    return redirect(url_for("profile_setup"))


# Accounts
#
# Two front doors onto one users table: session cookies for the browser
# prototype, bearer tokens for the app. accounts.py holds the password and
# token policy; these routes only translate it into HTTP.

@app.route("/login", methods=["GET", "POST"])
def login():
    if g.user is not None:
        return redirect(url_for("dashboard"))

    if request.method == "POST":
        conn = database.connect()
        user = accounts.authenticate(conn, request.form.get("email", ""),
                                     request.form.get("password", ""))
        if user is None:
            conn.commit()      # authenticate may have rehashed
            conn.close()
            # Deliberately vague: saying which half was wrong tells someone
            # which email addresses are registered.
            flash("Email or password is incorrect.", "error")
            return render_template("login.html",
                                   email=request.form.get("email", ""))

        # See api_login: once the password is right, vagueness protects
        # nobody and only confuses the person it is aimed at.
        if accounts.is_blocked(user):
            conn.commit()
            conn.close()
            flash("This account has been blocked by an administrator.",
                  "error")
            return render_template("login.html",
                                   email=request.form.get("email", ""))
        conn.commit()
        conn.close()

        session.clear()
        session["user_id"] = user["id"]
        session.permanent = True
        target = request.args.get("next") or url_for("dashboard")
        # Only relative paths, or this becomes an open redirect that can send
        # someone to another site from a link that looks like ours.
        if not target.startswith("/"):
            target = url_for("dashboard")
        return redirect(target)

    return render_template("login.html", email="")


@app.route("/register", methods=["GET", "POST"])
def register():
    if g.user is not None:
        return redirect(url_for("dashboard"))

    if request.method == "POST":
        email = request.form.get("email", "")
        password = request.form.get("password", "")
        name = request.form.get("name", "")

        problems = accounts.validate_registration(email, password, name)
        conn = database.connect()
        if not problems and accounts.find_user_by_email(conn, email):
            problems.append("That email already has an account.")

        if problems:
            conn.close()
            for message in problems:
                flash(message, "warn")
            return render_template("register.html", email=email, name=name)

        user = accounts.create_user(conn, email, password, name)
        conn.commit()
        conn.close()

        session.clear()
        session["user_id"] = user["id"]
        session.permanent = True
        flash(f"Welcome, {user['name']}. Set up your profile to get started.",
              "ok")
        return redirect(url_for("profile_setup"))

    return render_template("register.html", email="", name="")


@app.route("/logout")
def logout():
    session.clear()
    flash("Signed out.", "ok")
    return redirect(url_for("login"))


# JSON endpoints for the mobile client

@app.route("/api/register", methods=["POST"])
def api_register():
    body = request.get_json(silent=True) or {}
    email = body.get("email", "")
    password = body.get("password", "")
    name = body.get("name", "")

    problems = accounts.validate_registration(email, password, name)
    conn = database.connect()
    if not problems and accounts.find_user_by_email(conn, email):
        problems.append("That email already has an account.")
    if problems:
        conn.close()
        return jsonify({"error": "invalid registration",
                        "problems": problems}), 400

    user = accounts.create_user(conn, email, password, name)
    token = accounts.issue_token(conn, user["id"])
    conn.commit()
    conn.close()
    return jsonify({"token": token, "user": _public_user(user)}), 201


@app.route("/api/login", methods=["POST"])
def api_login():
    body = request.get_json(silent=True) or {}
    conn = database.connect()
    user = accounts.authenticate(conn, body.get("email", ""),
                                 body.get("password", ""))
    if user is None:
        conn.commit()
        conn.close()
        return jsonify({"error": "email or password is incorrect"}), 401

    # A blocked account is told it is blocked rather than that its password is
    # wrong. The vague message above exists to avoid revealing which addresses
    # are registered; that reason does not apply once the password has already
    # been accepted, and "incorrect password" here would send someone into a
    # reset loop that cannot possibly help them.
    if accounts.is_blocked(user):
        conn.commit()
        conn.close()
        return jsonify({"error": "this account has been blocked"}), 403

    accounts.purge_expired_sessions(conn)
    token = accounts.issue_token(conn, user["id"])
    conn.commit()
    conn.close()
    return jsonify({"token": token, "user": _public_user(user)})


@app.route("/api/logout", methods=["POST"])
def api_logout():
    if g.token:
        conn = database.connect()
        accounts.revoke_token(conn, g.token)
        conn.commit()
        conn.close()
    return jsonify({"ok": True})


@app.route("/api/account/delete", methods=["POST"])
def api_delete_account():
    """Delete this account and everything in it. Permanent.

    The password is required again even though the caller already holds a
    valid token. A token sits on a phone and outlives the moment it was
    issued: an unlocked handset, or a borrowed one, is enough to use it. For
    an action with no undo, the thing worth proving is that the person
    tapping is the person who owns the account, and only the password proves
    that.

    Order matters. Every one of these tables has a foreign key to users(id),
    so users goes last; sessions goes just before it, which signs out every
    other device as a side effect -- correct, since the account they were
    signed in to no longer exists.
    """
    payload = request.get_json(silent=True) or {}
    password = payload.get("password") or ""
    if not password:
        return jsonify({"error": "Enter your password to confirm."}), 400

    conn = database.connect()
    try:
        # g.user came from the token; re-read so the hash is current even if
        # the password was changed on another device since this token was
        # issued.
        user = accounts.find_user_by_id(conn, g.user["id"])
        if user is None:
            return jsonify({"error": "Account not found."}), 404

        if not accounts.verify_password(password, user["password_hash"]):
            # Deliberately not "wrong password" versus anything else: this is
            # the last gate in front of an irreversible action, and it should
            # say as little as possible about why it refused.
            return jsonify({"error": "That password is not correct."}), 403

        user_id = user["id"]
        for table in ("entries", "weights", "shown", "profile", "sessions"):
            conn.execute(f"DELETE FROM {table} WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM users WHERE id=?", (user_id,))
        conn.commit()
    finally:
        conn.close()

    return jsonify({"ok": True})


@app.route("/api/me")
def api_me():
    """Who the token belongs to, and whether setup has been done.

    The app calls this on launch to decide between the dashboard and the setup
    flow, which is the same decision the web prototype makes in before_request.
    """
    return jsonify({
        "user": _public_user(g.user),
        "has_profile": g.has_profile,
        "profile": g.profile if g.has_profile else None,
    })


@app.route("/api/foods")
def api_foods():
    """Food search for the app.

    The app ships its own copy of this table so logging a meal never waits on
    a network. This endpoint exists for an initial download and for checking
    the bundled copy against the server, not for per-keystroke search.
    """
    query = request.args.get("q", "")
    try:
        limit = min(int(request.args.get("limit", 30)), 200)
    except (TypeError, ValueError):
        limit = 30

    conn = database.connect()
    rows = [database.food_dict(r)
            for r in database.search_foods(conn, query, limit=limit)]
    total = conn.execute("SELECT COUNT(*) c FROM foods").fetchone()["c"]
    conn.close()
    return jsonify({"total": total, "count": len(rows), "foods": rows})


def _public_user(user):
    """A user without the password hash. Never serialise the row directly."""
    if user is None:
        return None
    return {"id": user["id"], "email": user["email"], "name": user["name"],
            "created_at": user["created_at"]}


if __name__ == "__main__":
    database.init()

    where = "Postgres" if db.is_postgres() else f"SQLite ({db.SQLITE_PATH})"
    print(f"Database: {where}")
    if not os.environ.get("SECRET_KEY"):
        # Said out loud rather than left to be discovered: with a known key,
        # anyone can forge a session cookie and sign in as any user.
        print("WARNING: SECRET_KEY is not set, so session cookies use a "
              "well-known development key.\n"
              "         Set it before exposing this to anyone: "
              'export SECRET_KEY="$(python -c \'import secrets;'
              "print(secrets.token_hex(32))')\"")
    # Refuse to be the public server.
    #
    # This block runs Werkzeug's development server with debug=True, which
    # hands an interactive Python console to anyone who can trigger a
    # traceback. On a laptop behind a router that is a convenience; on a
    # public URL it is remote code execution.
    #
    # PORT is set by Render, Railway, Heroku and every host of that shape, and
    # is normally unset locally, so it is a good enough signal that this is
    # not a development machine. The Procfile and render.yaml both start
    # gunicorn instead; this exists for the case where someone sets the start
    # command by hand in a dashboard and types what they are used to typing.
    if os.environ.get("PORT") and not os.environ.get("ALLOW_DEV_SERVER"):
        print("\nRefusing to start: PORT is set, so this looks like a hosting\n"
              "platform, and this entry point is the development server with\n"
              "the debugger enabled -- which would let anyone who causes an\n"
              "error run Python on the host.\n\n"
              "Use the production server instead:\n"
              "    gunicorn app:app --bind 0.0.0.0:$PORT --workers 2 "
              "--threads 4 --timeout 120\n\n"
              "That is already the start command in ../render.yaml and in\n"
              "backend/Procfile. If you really did mean the development\n"
              "server, set ALLOW_DEV_SERVER=1.")
        raise SystemExit(1)

    print("Open http://127.0.0.1:5000")
    app.run(debug=True, host="0.0.0.0", port=5000)
