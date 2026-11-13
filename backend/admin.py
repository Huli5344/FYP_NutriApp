"""The admin panel: a staff-only view of the live database.

Originally a standalone Flask app written alongside this project. It is
mounted here as a blueprint rather than deployed beside it, for three
reasons: it then shares one database connection and one deploy instead of
waking Neon's compute twice, it reuses the accounts system already in place
instead of inventing a second one, and the data it shows is the data the app
is actually serving -- which was the whole point of an admin panel.

What changed in the move, and why:

  * The data layer. It used Flask-SQLAlchemy over its own SQLite file seeded
    with five fictional users. Every query now runs through database.py
    against the real tables, so the numbers on these pages are counts of real
    rows. Nothing here is seeded and nothing is cached.

  * The gate. None of its routes had a login, and POST /users/action would
    edit an account for anyone who found the URL. Every route here requires a
    signed-in account with is_admin set; see `require_admin` below.

  * The sections that described things this project does not have. The panel
    was written against Supabase Auth, the Edamam API, and free/paid user
    tiers, none of which exist here. Those pages now say so, in place, rather
    than showing invented figures: a dashboard that reports numbers nobody
    computed is worse than one that admits the gap.

The templates and stylesheet are kept as they were written, in
templates/admin/ and static/admin/. What they are fed changed; what they look
like did not.
"""

from flask import (Blueprint, abort, flash, g, redirect, render_template,
                   request, url_for)

import database
import logic

bp = Blueprint("admin", __name__, url_prefix="/admin")

# How many rows a table page shows before paging.
PAGE_SIZE = 50


@bp.before_request
def require_admin():
    """Refuse anyone who is not a signed-in administrator.

    A blueprint before_request rather than a decorator on each view, because
    a decorator you have to remember is one somebody eventually forgets --
    and here that would mean an unauthenticated page listing every account.
    This runs for every route in this blueprint, including ones added later,
    and there is no way to register a route that skips it.

    Three distinct answers, deliberately:

      * Not signed in -> the sign-in page. The app's own before_request has
        usually done this already; this is the backstop.
      * Signed in, not an admin -> 404, not 403. A 403 confirms that /admin
        exists and that this person is merely not on the list, which is a
        fact worth not handing out. To an ordinary account the panel is not
        forbidden, it is absent.
      * Signed in, an admin, but the account has since been disabled -> same
        404. Checked per request rather than only at sign-in, so revoking an
        administrator takes effect on their next click rather than whenever
        their session happens to expire.
    """
    user = getattr(g, "user", None)
    if user is None:
        return redirect(url_for("login", next=request.path))
    if not user.get("is_admin") or user.get("disabled"):
        abort(404)
    return None


def page_args():
    """The `q` and `page` query parameters, clamped to something sane."""
    query = (request.args.get("q") or "").strip()
    try:
        page = max(1, int(request.args.get("page", 1)))
    except (TypeError, ValueError):
        page = 1
    return query, page, (page - 1) * PAGE_SIZE


def paging(total, page):
    pages = max(1, -(-total // PAGE_SIZE))
    return {"page": min(page, pages), "pages": pages, "total": total,
            "has_prev": page > 1, "has_next": page < pages}


# ---------------------------------------------------------------- overview

@bp.route("/")
def overview():
    conn = database.connect()
    try:
        stats = database.admin_overview(conn)
        goals = database.admin_goal_distribution(conn)
        logged = database.admin_most_logged(conn, limit=10)
    finally:
        conn.close()

    return render_template("admin/overview.html", stats=stats, goals=goals,
                           most_logged=logged,
                           topbar_title="Overview")


# ------------------------------------------------------------------- users

@bp.route("/users")
def user_management():
    query, page, offset = page_args()
    conn = database.connect()
    try:
        total = database.admin_user_count(conn, query)
        users = database.admin_users(conn, query, PAGE_SIZE, offset)
    finally:
        conn.close()

    return render_template("admin/users.html", users=users, q=query,
                           paging=paging(total, page),
                           topbar_title="User accounts")


@bp.route("/users/<user_id>")
def user_detail(user_id):
    conn = database.connect()
    try:
        person = database.admin_user(conn, user_id)
        activity = database.admin_user_activity(conn, user_id) if person else []
    finally:
        conn.close()

    if not person:
        flash("No such account.", "error")
        return redirect(url_for("admin.user_management"))

    return render_template("admin/user_detail.html", person=person,
                           activity=activity,
                           topbar_title=person["name"])


@bp.post("/users/action")
def manage_user():
    """The two powers an admin has over an account.

    Neither is destructive: an account can be blocked and unblocked, and
    promoted and demoted. There is no delete here on purpose -- deleting an
    account removes somebody's diary, and the only person who should be able
    to do that is the person whose diary it is, from the app, after typing
    their password. That route already exists; this panel does not duplicate
    it with one click and no password.
    """
    action = request.form.get("action")
    user_id = request.form.get("user_id", "")

    conn = database.connect()
    try:
        person = database.admin_user(conn, user_id)
        if not person:
            flash("No such account.", "error")
            return redirect(url_for("admin.user_management"))

        if action in ("disable", "enable"):
            disable = action == "disable"
            # Refusing to disable yourself is not politeness, it is the
            # difference between a mistake and a locked door: disabling your
            # own account also deletes your sessions, so the click that did it
            # would sign you out of the panel you need to undo it.
            if disable and person["id"] == g.user["id"]:
                flash("You cannot disable your own account from here.", "error")
            else:
                database.admin_set_disabled(conn, user_id, disable)
                flash(f"{person['name']} is now "
                      f"{'blocked from signing in' if disable else 'active'}.",
                      "success")

        elif action in ("promote", "demote"):
            promote = action == "promote"
            # The same cliff, one step further out: demoting the last enabled
            # administrator leaves a panel nobody can open, and the only way
            # back in is the command line against the production database.
            if not promote and database.admin_count_admins(conn) <= 1:
                flash("This is the only administrator left. Promote somebody "
                      "else first.", "error")
            else:
                database.admin_set_admin(conn, user_id, promote)
                flash(f"{person['name']} is "
                      f"{'now an administrator' if promote else 'no longer an administrator'}.",
                      "success")
        else:
            flash("Unknown action.", "error")
    finally:
        conn.close()

    return redirect(request.form.get("next") or url_for("admin.user_management"))


# ------------------------------------------------- preferences & allergens

@bp.route("/preferences")
def preferences():
    """What people have actually recorded, not what the app offers.

    The options list is what the app presents at setup; the counts are how
    many accounts chose each. The gap between the two is the interesting part
    -- an allergen nobody records is a question nobody needed asked.
    """
    conn = database.connect()
    try:
        allergens = database.admin_allergen_counts(conn)
        diets = database.admin_diet_counts(conn)
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    recorded = {name for name, _ in allergens}
    unused = [t for t in logic.ALLERGEN_TOKENS if t not in recorded]

    return render_template("admin/preferences.html", allergens=allergens,
                           diets=diets, stats=stats, unused=unused,
                           offered=list(logic.ALLERGEN_TOKENS),
                           diet_options=list(logic.DIET_TOKENS),
                           topbar_title="Preferences and allergens")


# ---------------------------------------------------------------- sections

@bp.route("/section/dietary-goals")
def dietary_goals():
    conn = database.connect()
    try:
        goals = database.admin_goal_distribution(conn)
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    # Every goal the app offers, including the ones nobody has picked, so a
    # zero is visible as a zero rather than as a missing row.
    chosen = {row["goal"]: row for row in goals}
    rows = [{
        "goal": goal,
        "users": chosen.get(goal, {}).get("users", 0),
        "avg_target": chosen.get(goal, {}).get("avg_target"),
        "adjustment": logic.GOAL_ADJUSTMENTS[goal],
    } for goal in logic.GOAL_ADJUSTMENTS]
    rows.sort(key=lambda r: (-r["users"], r["goal"]))

    return render_template("admin/dietary_goals.html", rows=rows, stats=stats,
                           topbar_title="Dietary goals")


@bp.route("/section/food-database")
def food_database():
    query, page, offset = page_args()
    conn = database.connect()
    try:
        total = database.admin_food_count(conn, query)
        foods = database.admin_foods(conn, query, PAGE_SIZE, offset)
        groups = database.admin_food_groups(conn)
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    return render_template("admin/food_database.html", foods=foods, q=query,
                           groups=groups, stats=stats,
                           paging=paging(total, page),
                           topbar_title="Food database")


@bp.route("/section/categories-and-tags")
def categories_and_tags():
    conn = database.connect()
    try:
        groups = database.admin_food_groups(conn)
        logged = database.admin_most_logged(conn, limit=20)
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    return render_template("admin/categories.html", groups=groups,
                           most_logged=logged, stats=stats,
                           topbar_title="Categories and tags")


@bp.route("/section/rules-and-metrics")
def rules_and_metrics():
    """The formulas the server actually uses, read out of logic.py.

    Read from the module rather than typed into the template, so this page
    cannot drift away from the code: change a multiplier in logic.py and this
    page changes with it. A rules page that has to be kept in sync by hand is
    a rules page that is eventually wrong.
    """
    conn = database.connect()
    try:
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    return render_template(
        "admin/rules.html",
        activity=sorted(logic.ACTIVITY_MULTIPLIERS.items(),
                        key=lambda kv: kv[1]),
        goals=sorted(logic.GOAL_ADJUSTMENTS.items(), key=lambda kv: kv[1]),
        macro_splits=logic.GOAL_MACRO_SPLITS,
        default_split=logic.MACRO_SPLIT,
        meal_split=logic.MEAL_SPLIT,
        kcal_floor=logic.MIN_DAILY_TARGET,
        kcal_ceiling=logic.MAX_DAILY_TARGET,
        default_activity=logic.DEFAULT_ACTIVITY_MULTIPLIER,
        insights_window=logic.INSIGHTS_WINDOW_DAYS,
        stats=stats,
        topbar_title="Rules and metrics")


@bp.route("/section/reports")
def reports():
    conn = database.connect()
    try:
        daily = database.admin_daily_totals(conn, days=14)
        stats = database.admin_overview(conn)
        logged = database.admin_most_logged(conn, limit=15)
    finally:
        conn.close()

    return render_template("admin/reports.html", daily=daily, stats=stats,
                           most_logged=logged,
                           topbar_title="Reports")


@bp.route("/section/security-log")
def security_log():
    """Signed-in devices, which is the honest version of a security log.

    The original panel kept an events table and appended a row whenever an
    admin clicked something. That table recorded only what the panel itself
    did, so it read as an audit trail while being blind to every sign-in,
    every sync and every API call -- the things an audit trail is for.

    This shows what the server can actually attest to: the sessions it would
    accept right now, who they belong to, when they were issued and when they
    expire. Every row here is a live way into an account.
    """
    conn = database.connect()
    try:
        sessions = database.admin_sessions(conn, limit=100)
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    return render_template("admin/security_log.html", sessions=sessions,
                           stats=stats,
                           topbar_title="Sessions")


@bp.route("/section/roles-and-access")
def roles_and_access():
    """Who can open this panel.

    The original had a fourteen-row matrix across FreeUser, PaidUser and
    Administrator. This project has no paid tier and no per-role permissions:
    there are accounts, and some of them are administrators. The matrix is
    therefore not shown. Inventing one here would describe a system that does
    not exist, and the first person to rely on it would be relying on nothing.
    """
    conn = database.connect()
    try:
        admins = [u for u in database.admin_users(conn, "", 500, 0)
                  if u["is_admin"]]
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    return render_template("admin/roles_access.html", admins=admins,
                           stats=stats,
                           topbar_title="Roles and access")


@bp.route("/section/recipe-api")
def recipe_api_page():
    """The suggestion pool and the state of the external service.

    The original synced from Edamam. This project uses TheMealDB, with the
    `recipes` table as the offline fallback when it cannot be reached, so
    that is what is reported: what is stored locally, and what the cache
    holds.
    """
    import recipes_api

    conn = database.connect()
    try:
        recipes = database.admin_recipes(conn)
        cached = conn.execute(
            "SELECT COUNT(*) AS n FROM api_cache").fetchone()["n"]
        newest = conn.execute(
            "SELECT MAX(fetched_at) AS m FROM api_cache").fetchone()["m"]
        stats = database.admin_overview(conn)
    finally:
        conn.close()

    return render_template("admin/recipe_api.html", recipes=recipes,
                           cached=cached, newest=newest, stats=stats,
                           attribution=recipes_api.ATTRIBUTION,
                           ttl=recipes_api.CACHE_TTL_HOURS,
                           topbar_title="Recipe service")
