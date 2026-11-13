"""Storage for Nutri App.

Postgres in deployment (Neon), SQLite for the tests. Both go through db.py,
which is the only module that knows which. The SQL here is written once and
portably: `?` placeholders, `substr()` rather than SQLite's `date()`,
`ON CONFLICT` rather than `INSERT OR IGNORE`, and `RETURNING` rather than an
update followed by a select. Every type that differs between the two engines
is a `{...}` placeholder filled in by db.render_schema.

Two tables hold reference data and the rest hold user data:

  * `foods` is the Health Promotion Board dataset, 2,692 rows imported by
    tools/import_hpb_foods.py. Read-only to the app, and the one source of
    truth for what a food contains -- the thirty hand-entered foods this
    project started with have been removed, because where they overlapped HPB
    they disagreed, and a figure nobody can cite is not worth defending.
  * `recipes` is the offline suggestion pool, used when TheMealDB is
    unreachable.

  * `users`, `sessions` hold accounts. See accounts.py for the policy.
  * `entries`, `weights`, `profile` are per-user and carry `user_id`. Every
    read filters on it: without that, one account's cursor would pull another
    account's diary.
"""

import os

import db

# Used by the web prototype before a profile has been saved, so the dashboard
# has something to measure against rather than crashing. The app does not use
# it: its sign-in gate refuses to reach a measuring screen without a profile.
DEFAULT_PROFILE = {
    "name": "Guest",
    "email": "",
    "age": 30,
    "gender": None,
    "height_cm": 170.0,
    "weight_kg": 70.0,
    "activity_level": "Moderately Active",
    "goal": "Eat Healthier",
    "target_weight_kg": None,
    "preferences": "",
    "restrictions": "",
    "allergens": "",
    "diet_types": "",
    "diet_type": "balanced",
    "computed_target_kcal": 2000,
    "target_kcal": 2000,
    "target_is_manual": 0,
    "updated_at": "1970-01-01T00:00:00+00:00",
    "server_seq": 0,
}

SCHEMA = """
-- `is_admin` and `disabled` are the admin panel's two powers over an account,
-- and they are deliberately columns on `users` rather than a second accounts
-- system. An admin signs in with their ordinary account and ordinary
-- password, so there is one password policy, one hash, one session table and
-- one thing to get right. A separate admin login would be a second set of
-- credentials protecting more, written later and tested less.
--
-- Both are checked at sign-in and on every admin request. See ADMIN.md.
CREATE TABLE IF NOT EXISTS users (
    id            {text} PRIMARY KEY,
    email         {text} NOT NULL UNIQUE,
    name          {text} NOT NULL,
    password_hash {text} NOT NULL,
    created_at    {text} NOT NULL,
    is_admin      {int} NOT NULL DEFAULT 0,
    disabled      {int} NOT NULL DEFAULT 0
);

-- A random token per signed-in device. Deleting the row signs that device
-- out, which is the reason for a table rather than a self-contained JWT.
CREATE TABLE IF NOT EXISTS sessions (
    token      {text} PRIMARY KEY,
    user_id    {text} NOT NULL REFERENCES users(id),
    created_at {text} NOT NULL,
    expires_at {text} NOT NULL
);

CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

-- The HPB dataset. Per-serving figures are as HPB publishes them, which
-- already account for the inedible portion; per_100 columns are per 100 g or
-- ml of edible portion. The two are not interconvertible without
-- edible_portion_pct, which is why both are stored.
CREATE TABLE IF NOT EXISTS foods (
    food_id             {text} PRIMARY KEY,
    name                {text} NOT NULL,
    description         {text},
    food_group          {text},
    food_subgroup       {text},
    serving_label       {text} NOT NULL,
    serving_size        {real} NOT NULL,
    serving_unit        {text} NOT NULL,
    alternative_serving {text},
    edible_portion_pct  {real},

    energy_kcal         {real}, protein_g              {real},
    total_fat_g         {real}, saturated_fat_g        {real},
    trans_fat_g         {real}, carbohydrate_g         {real},
    sugar_g             {real}, added_sugar_g          {real},
    dietary_fibre_g     {real}, sodium_mg              {real},
    potassium_mg        {real}, calcium_mg             {real},
    iron_mg             {real},

    per100_energy_kcal  {real}, per100_protein_g       {real},
    per100_total_fat_g  {real}, per100_saturated_fat_g {real},
    per100_trans_fat_g  {real}, per100_carbohydrate_g  {real},
    per100_sugar_g      {real}, per100_added_sugar_g   {real},
    per100_dietary_fibre_g {real}, per100_sodium_mg    {real},
    per100_potassium_mg {real}, per100_calcium_mg      {real},
    per100_iron_mg      {real},

    -- Measured below the detection limit, stored as 0. Listing them keeps
    -- "about zero" distinguishable from "exactly zero".
    trace_nutrients     {text} DEFAULT '',
    -- Nutrients the interface must not display for this food, because the
    -- published figure contradicts itself.
    suppress_nutrients  {text} DEFAULT '',
    notes               {text} DEFAULT '',
    bulk_serving        {int} NOT NULL DEFAULT 0,
    source_of_data      {text},
    last_updated        {text}
);

CREATE INDEX IF NOT EXISTS foods_name ON foods(name);
CREATE INDEX IF NOT EXISTS foods_group ON foods(food_group);

-- Diary entries. The key is a UUID generated on the device, not an
-- autoincrementing integer: two devices offline at the same time would both
-- create entry 1 and the server could not tell them apart.
CREATE TABLE IF NOT EXISTS entries (
    id          {text} NOT NULL,
    user_id     {text} NOT NULL REFERENCES users(id),
    food_id     {text},
    food_name   {text} NOT NULL,
    quantity    {real} NOT NULL DEFAULT 1,
    serving     {text},
    kcal        {int} NOT NULL,
    carbs_g     {real} NOT NULL,
    protein_g   {real} NOT NULL,
    fat_g       {real} NOT NULL,
    category    {text} NOT NULL,
    tags        {text} DEFAULT '',
    note        {text} DEFAULT '',
    eaten_at    {text} NOT NULL,
    source      {text} DEFAULT 'manual',
    -- `deleted` is a tombstone rather than a hard DELETE, because a removed
    -- row would be handed straight back by the next pull. `server_seq` is the
    -- pull cursor, assigned here on every write, so paging never depends on a
    -- device's clock.
    deleted     {int} NOT NULL DEFAULT 0,
    updated_at  {text} NOT NULL,
    server_seq  {int} NOT NULL DEFAULT 0,

    -- The key is (user_id, id), not id alone. Ids are generated on the device,
    -- so two accounts holding the same id should be impossible by accident --
    -- which means a collision is a bug or an attack. With id as the sole key,
    -- an upsert from one account would overwrite another account's row and
    -- take ownership of it. A composite key makes that structurally
    -- impossible rather than dependent on every query remembering a filter.
    PRIMARY KEY (user_id, id)
);

CREATE INDEX IF NOT EXISTS entries_seq ON entries(user_id, server_seq);
CREATE INDEX IF NOT EXISTS entries_eaten ON entries(user_id, eaten_at);

CREATE TABLE IF NOT EXISTS weights (
    id          {text} NOT NULL,
    user_id     {text} NOT NULL REFERENCES users(id),
    kg          {real} NOT NULL,
    recorded_at {text} NOT NULL,
    note        {text} DEFAULT '',
    deleted     {int} NOT NULL DEFAULT 0,
    updated_at  {text} NOT NULL,
    server_seq  {int} NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, id)
);

CREATE INDEX IF NOT EXISTS weights_seq ON weights(user_id, server_seq);

-- Foods a user entered themselves, for anything the Health Promotion Board
-- does not list: a home recipe, an imported product, a dish from a stall
-- that never made it into the dataset.
--
-- A collection like entries and weights rather than a column on them, because
-- the point is reuse: enter it once, log it whenever. Same bookkeeping for
-- the same reasons -- a client-generated id so two devices cannot collide, a
-- tombstone so a deletion is not handed back by the next pull, and the
-- composite key so one account's id can never overwrite another's row.
--
-- Deleting one does not touch the diary. An entry keeps its own copy of the
-- figures, so meals logged from a custom food stay correct after the food is
-- gone; what breaks is only the link used to recompute on an edit, and that
-- already falls back to the stored totals.
CREATE TABLE IF NOT EXISTS custom_foods (
    id          {text} NOT NULL,
    user_id     {text} NOT NULL REFERENCES users(id),
    name        {text} NOT NULL,
    serving     {text} NOT NULL DEFAULT '1 serving',
    kcal        {int} NOT NULL,
    carbs_g     {real} NOT NULL DEFAULT 0,
    protein_g   {real} NOT NULL DEFAULT 0,
    fat_g       {real} NOT NULL DEFAULT 0,
    deleted     {int} NOT NULL DEFAULT 0,
    updated_at  {text} NOT NULL,
    server_seq  {int} NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, id)
);

CREATE INDEX IF NOT EXISTS custom_foods_seq
    ON custom_foods(user_id, server_seq);

-- One row per user. The raw setup answers (preferences, restrictions) sit
-- beside the normalised tokens (allergens, diet_types) the recipe filter
-- compares against: the answers are what an edit form shows back, the tokens
-- are what the data uses, and neither has to be guessed from the other.
CREATE TABLE IF NOT EXISTS profile (
    user_id              {text} PRIMARY KEY REFERENCES users(id),
    name                 {text} NOT NULL,
    email                {text} DEFAULT '',
    age                  {int} NOT NULL,
    gender               {text},
    height_cm            {real} NOT NULL,
    weight_kg            {real} NOT NULL,
    activity_level       {text} NOT NULL,
    goal                 {text} NOT NULL,
    target_weight_kg     {real},
    preferences          {text} DEFAULT '',
    restrictions         {text} DEFAULT '',
    allergens            {text} DEFAULT '',
    diet_types           {text} DEFAULT '',
    diet_type            {text} DEFAULT 'balanced',
    computed_target_kcal {int} NOT NULL,
    target_kcal          {int} NOT NULL,
    target_is_manual     {int} NOT NULL DEFAULT 0,
    updated_at           {text} NOT NULL,
    server_seq           {int} NOT NULL DEFAULT 0
);

-- Monotonic counters. `seq` is the sync cursor, shared by all users: a
-- cursor only has to increase, not be dense, and one counter avoids a second
-- source of truth per account.
CREATE TABLE IF NOT EXISTS meta (
    key         {text} PRIMARY KEY,
    value       {int} NOT NULL
);

CREATE TABLE IF NOT EXISTS recipes (
    id          {serial},
    name        {text} NOT NULL,
    kcal        {int} NOT NULL,
    carbs_g     {real} NOT NULL,
    protein_g   {real} NOT NULL,
    fat_g       {real} NOT NULL,
    minutes     {int},
    allergens   {text} DEFAULT '',
    diet_types  {text} DEFAULT '',
    ingredients {text} DEFAULT ''
);

-- Responses from TheMealDB, keyed by full URL. Keeps the app inside a sensible
-- request rate, and is the first fallback when the service is unreachable.
CREATE TABLE IF NOT EXISTS api_cache (
    url         {text} PRIMARY KEY,
    body        {text} NOT NULL,
    fetched_at  {text} NOT NULL
);

-- Which recipes were shown recently, per user, so a refresh differs.
CREATE TABLE IF NOT EXISTS shown (
    id          {serial},
    user_id     {text},
    recipe_id   {text} NOT NULL,
    shown_at    {text} NOT NULL
);
"""

RECIPES = [
    ('Grilled salmon with quinoa', 612, 48, 41, 26, 25, 'fish', 'halal,high-protein,pescatarian',
     'Salmon fillet 150 g|Quinoa, cooked 120 g|Broccoli 80 g|Olive oil 1 tbsp'),
    ('Chickpea and spinach curry', 598, 72, 22, 21, 30, '', 'halal,high-fibre,pescatarian,vegan,vegetarian',
     'Chickpeas 240 g|Spinach 100 g|Coconut milk 80 ml|Brown rice 100 g'),
    ('Chicken and broccoli stir-fry', 520, 38, 45, 18, 20, 'gluten,soy', 'halal,high-protein',
     'Chicken breast 180 g|Broccoli 150 g|Soy sauce 1 tbsp|Rice 90 g'),
    ('Tofu and vegetable noodles', 470, 58, 24, 15, 20, 'egg,gluten,soy', 'halal,pescatarian,vegetarian',
     'Firm tofu 150 g|Egg noodles 120 g|Mixed vegetables 150 g'),
    ('Prawn and egg fried rice', 640, 72, 28, 24, 15, 'egg,shellfish', 'halal,high-protein,pescatarian',
     'Prawns 120 g|Eggs 2|Rice 200 g|Peas 50 g'),
    ('Peanut satay chicken', 680, 34, 44, 38, 35, 'peanut', 'halal,high-protein',
     'Chicken thigh 200 g|Peanut sauce 60 g|Cucumber 80 g'),
    ('Greek yoghurt bowl', 320, 38, 22, 8, 5, 'milk', 'halal,high-protein,pescatarian,vegetarian',
     'Greek yoghurt 200 g|Berries 100 g|Oats 30 g|Honey 1 tsp'),
    ('Lentil soup with bread', 430, 62, 21, 9, 30, 'gluten', 'halal,high-fibre,pescatarian,vegan,vegetarian',
     'Red lentils 150 g|Carrot 80 g|Onion 60 g|Wholemeal bread 2 slices'),
    ('Steamed fish with rice', 480, 52, 38, 10, 25, 'fish', 'halal,high-protein,pescatarian',
     'White fish 180 g|Ginger|Rice 120 g|Bok choy 100 g'),
    ('Beef and vegetable stew', 590, 40, 42, 26, 60, '', 'halal,high-protein',
     'Lean beef 180 g|Potato 150 g|Carrot 100 g|Celery 60 g'),
    ('Chicken salad wrap', 425, 40, 32, 14, 10, 'gluten,milk', 'halal,high-protein',
     'Chicken breast 130 g|Tortilla 1|Lettuce 60 g|Yoghurt dressing'),
    ('Black bean burrito bowl', 610, 84, 24, 18, 20, '', 'halal,high-fibre,pescatarian,vegan,vegetarian',
     'Black beans 200 g|Rice 150 g|Corn 60 g|Salsa 50 g'),
    ('Baked cod with sweet potato', 465, 48, 36, 12, 35, 'fish', 'halal,high-protein,pescatarian',
     'Cod 180 g|Sweet potato 200 g|Green beans 100 g|Olive oil 1 tbsp'),
    ('Mushroom and barley risotto', 505, 78, 14, 14, 40, 'gluten,milk', 'halal,high-fibre,pescatarian,vegetarian',
     'Pearl barley 150 g|Mushrooms 150 g|Parmesan 20 g|Stock 400 ml'),
    ('Egg and avocado toast', 410, 34, 18, 23, 10, 'egg,gluten', 'halal,pescatarian,vegetarian',
     'Eggs 2|Avocado half|Wholemeal bread 2 slices'),
    ('Vegetable fried brown rice', 450, 68, 12, 14, 20, 'gluten,soy', 'halal,pescatarian,vegan,vegetarian',
     'Brown rice 180 g|Mixed vegetables 150 g|Soy sauce 1 tbsp'),
    ('Grilled chicken salad', 385, 18, 40, 16, 15, '', 'halal,high-protein,low-carb',
     'Chicken breast 180 g|Mixed leaves 100 g|Cherry tomatoes 80 g|Olive oil 1 tbsp'),
    ('Tofu and vegetable curry', 520, 58, 22, 22, 30, 'soy', 'halal,pescatarian,vegan,vegetarian',
     'Firm tofu 200 g|Coconut milk 150 ml|Mixed vegetables 200 g|Rice 100 g'),
    ('Salmon and soba noodles', 560, 52, 38, 20, 25, 'fish,gluten,sesame,soy', 'halal,high-protein,pescatarian',
     'Salmon 150 g|Soba noodles 120 g|Spring onion 40 g|Sesame oil 1 tsp'),
    ('Minestrone with beans', 395, 58, 18, 9, 35, 'gluten', 'halal,high-fibre,pescatarian,vegetarian',
     'Cannellini beans 200 g|Pasta 60 g|Tomato 300 g|Carrot 80 g'),
    ('Turkey and vegetable chilli', 470, 44, 40, 14, 45, '', 'halal,high-fibre,high-protein',
     'Turkey mince 200 g|Kidney beans 150 g|Tomato 300 g|Pepper 100 g'),
    ('Roasted vegetable couscous', 440, 76, 14, 10, 25, 'gluten', 'halal,high-fibre,pescatarian,vegan,vegetarian',
     'Couscous 120 g|Courgette 120 g|Aubergine 120 g|Chickpeas 100 g'),
    ('Sweet potato and lentil stew', 420, 62, 18, 8, 35, '', 'halal,high-fibre,pescatarian,vegan,vegetarian',
     'Red lentils 150 g|Sweet potato 200 g|Onion 80 g|Cumin 1 tsp'),
    ('Vegan chilli with rice', 545, 82, 20, 12, 40, '', 'halal,high-fibre',
     'Black beans 200 g|Kidney beans 100 g|Tomato 300 g|Rice 120 g'),
    ('Quinoa and roasted vegetable bowl', 480, 64, 16, 16, 30, '', 'halal,high-fibre,pescatarian,vegan,vegetarian',
     'Quinoa 140 g|Courgette 120 g|Pepper 120 g|Olive oil 1 tbsp'),
]


def connect(for_migration=False):
    """A connection to whichever database db.py is configured for.

    `for_migration` asks for Neon's direct, unpooled connection, which schema
    changes need. See db.migration_url.
    """
    return db.connect(for_migration=for_migration)


# A column that only exists in the current schema, per table. If a table is
# present without it, the database predates the accounts and HPB-foods work
# and `CREATE TABLE IF NOT EXISTS` will quietly skip it -- leaving the next
# statement to fail somewhere unhelpful, like a missing index column.
SCHEMA_MARKERS = {
    "foods": "food_group",
    "entries": "user_id",
    "profile": "user_id",
    "weights": "user_id",
}


# Columns added to a table that already exists in deployment. `CREATE TABLE
# IF NOT EXISTS` sees the table, skips it, and the new column never appears --
# so every column added after the first deploy needs an entry here.
#
# Each is (table, column, type-and-default). Additive only: no entry here may
# drop, rename or retype anything, because this runs unattended in Render's
# build step against the live database. A change that cannot be expressed as
# "add a column with a default" belongs in SCHEMA_MARKERS instead, where it
# stops the deploy and asks for a human.
ADDED_COLUMNS = [
    ("users", "is_admin", "{int} NOT NULL DEFAULT 0"),
    ("users", "disabled", "{int} NOT NULL DEFAULT 0"),
]


def add_missing_columns(conn):
    """Apply ADDED_COLUMNS to a database that predates them. Idempotent.

    Returns the columns it added, so init() can say so rather than migrating
    the production database silently.
    """
    added = []
    for table, column, column_type in ADDED_COLUMNS:
        if not db.table_exists(conn, table):
            continue            # a fresh database; SCHEMA already has it
        if column in db.columns(conn, table):
            continue
        rendered = column_type.format(
            **db.TYPES["postgres" if db.is_postgres() else "sqlite"])
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {rendered}")
        added.append(f"{table}.{column}")
    if added:
        conn.commit()
    return added


class SchemaOutOfDate(RuntimeError):
    """Raised when an existing database has an older, incompatible schema."""


def check_schema(conn):
    """Refuse to run against a database from before accounts existed.

    Worth failing loudly: these tables gained a `user_id` and the food table
    was replaced entirely, so carrying on would mix one schema's rows with
    another's queries.
    """
    stale = []
    for table, marker in SCHEMA_MARKERS.items():
        if db.table_exists(conn, table) and marker not in db.columns(conn, table):
            stale.append(f"{table} has no {marker} column")
    if stale:
        where = ("your Postgres database" if db.is_postgres()
                 else db.SQLITE_PATH)
        raise SchemaOutOfDate(
            "The schema in " + where + " predates user accounts: "
            + "; ".join(stale) + ".\n"
            "There is no migration for this: entries are now per-user and the "
            "food table was replaced.\n"
            "Reset it with  python -c \"import database; database.init(force=True)\"  "
            "from the backend folder,\nor delete the database and run again. "
            "Anything already in it will be lost.")


def init(force=False):
    """Create the schema and load reference data. Safe to call repeatedly.

    Uses the direct (unpooled) connection. Running DDL through Neon's pooler
    can fail without naming pooling as the cause, so if only a pooled URL is
    configured this says so rather than letting it fail obscurely later.
    """
    if db.is_postgres() and db.looks_pooled(db.migration_url()):
        print("WARNING: creating the schema over a POOLED connection "
              "(the hostname contains '-pooler').\n"
              "         Neon's pooler has no session state, so DDL can fail "
              "in ways that never mention pooling.\n"
              "         Set DATABASE_URL_UNPOOLED to the direct string, or "
              "run `neon env pull`, which writes both.")
    if force and not db.is_postgres():
        # `os` is imported at module level. A second `import os` here would
        # make the name function-local for the whole of init(), leaving it
        # unbound at the guard below -- which is exactly what it did, turning
        # a clear refusal into an UnboundLocalError.
        if os.path.exists(db.SQLITE_PATH):
            os.remove(db.SQLITE_PATH)

    if force and db.is_postgres():
        # `force` drops every table. Against SQLite that costs a development
        # file; against Postgres it is the live database, and the only thing
        # that stood between the two was which environment variables happened
        # to be set when the process started.
        #
        # db.py loads .env.local at import, so a script run from backend/ is
        # pointed at Neon without saying so. Running the test suite from that
        # folder therefore dropped the production tables once per test class.
        # That is not a mistake anybody should be able to make by running a
        # command that reads as read-only.
        #
        # So the destructive path now has to be asked for out loud. Tests run
        # against SQLite, where force is free; the one legitimate use against
        # Postgres is rebuilding a database deliberately, which is worth an
        # extra word on the command line.
        #
        # Checked before opening the connection, so an unreachable database
        # gives this explanation rather than a connection error that says
        # nothing about what was about to happen.
        if os.environ.get("NUTRIAPP_ALLOW_DESTRUCTIVE", "").lower() not in (
                "1", "yes", "true"):
            raise RuntimeError(
                "Refusing to drop every table in a PostgreSQL database.\n"
                f"  Target: {db.safe_target_description()}\n"
                "\n"
                "init(force=True) runs DROP TABLE on users, profile, entries,\n"
                "weights, foods and the rest. Something pointed this process\n"
                "at Postgres -- usually backend/.env.local, which db.py loads\n"
                "automatically.\n"
                "\n"
                "If you are running tests, run them from a folder without an\n"
                ".env.local, or let tests.py force SQLite as it now does.\n"
                "\n"
                "If you really did mean to wipe this database, set\n"
                "NUTRIAPP_ALLOW_DESTRUCTIVE=1 and run it again.")

    # Schema work goes over the direct connection, never the pooled one.
    conn = connect(for_migration=True)
    if force and db.is_postgres():
        for table in ("sessions", "shown", "weights", "entries", "profile",
                      "custom_foods", "api_cache", "recipes", "foods", "meta",
                      "users"):
            conn.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
        conn.commit()

    if not force:
        check_schema(conn)

    conn.executescript(db.render_schema(SCHEMA))

    # Tables that already existed were skipped above, so columns added after
    # the first deploy are applied here.
    for column in add_missing_columns(conn):
        print(f"added column {column}")

    if not conn.execute("SELECT 1 FROM recipes LIMIT 1").fetchone():
        conn.executemany(
            "INSERT INTO recipes (name,kcal,carbs_g,protein_g,fat_g,minutes,"
            "allergens,diet_types,ingredients) VALUES (?,?,?,?,?,?,?,?,?)",
            RECIPES)
    conn.execute(
        "INSERT INTO meta (key, value) VALUES ('seq', 0)"
        " ON CONFLICT (key) DO NOTHING")
    conn.commit()
    conn.close()


def next_seq(conn):
    """Claim the next sync sequence number.

    Taken inside the caller's transaction, with RETURNING rather than an
    update then a select, so two concurrent writes cannot be handed the same
    number and become invisible to each other's pull cursor.
    """
    row = conn.execute(
        "UPDATE meta SET value = value + 1 WHERE key = 'seq' RETURNING value"
    ).fetchone()
    return row["value"]


def current_seq(conn):
    row = conn.execute("SELECT value FROM meta WHERE key = 'seq'").fetchone()
    return row["value"] if row else 0


# Columns stored as joined text that callers want as real lists.
PROFILE_LIST_FIELDS = ("preferences", "restrictions", "allergens", "diet_types")

# Named explicitly rather than read back from the database, which needed
# PRAGMA table_info on SQLite and information_schema on Postgres.
PROFILE_COLUMNS = (
    "user_id", "name", "email", "age", "gender", "height_cm", "weight_kg",
    "activity_level", "goal", "target_weight_kg", "preferences",
    "restrictions", "allergens", "diet_types", "diet_type",
    "computed_target_kcal", "target_kcal", "target_is_manual", "updated_at",
    "server_seq",
)


def profile_row(conn, user_id):
    """A user's stored profile, or None when setup has not been done.

    None has to mean exactly "no profile" and never "a profile of defaults",
    because that is the signal the setup redirect depends on.
    """
    return conn.execute("SELECT * FROM profile WHERE user_id=?",
                        (user_id,)).fetchone()


def profile_dict(row):
    """A profile row in the shape the rules and templates expect."""
    data = dict(row) if row is not None else dict(DEFAULT_PROFILE)
    for field in PROFILE_LIST_FIELDS:
        raw = data.get(field) or ""
        data[field] = [v.strip() for v in str(raw).split(",") if v.strip()]
    data["target_is_manual"] = bool(data.get("target_is_manual"))
    data["is_default"] = row is None
    return data


def save_profile(conn, user_id, profile, seq=None):
    """Write a user's profile, replacing whatever was there.

    Lists are joined back to text on the way in, so a caller can hand over the
    same dict shape it reads back.
    """
    row = {k: v for k, v in profile.items() if k in PROFILE_COLUMNS}
    row["user_id"] = user_id
    for field in PROFILE_LIST_FIELDS:
        value = row.get(field, "")
        if isinstance(value, (list, tuple)):
            row[field] = ",".join(value)
    row["target_is_manual"] = 1 if row.get("target_is_manual") else 0
    row["server_seq"] = seq if seq is not None else next_seq(conn)

    columns = list(row)
    placeholders = ",".join("?" for _ in columns)
    assignments = ",".join(f"{c}=excluded.{c}" for c in columns
                           if c != "user_id")
    conn.execute(
        f"INSERT INTO profile ({','.join(columns)}) VALUES ({placeholders}) "
        f"ON CONFLICT (user_id) DO UPDATE SET {assignments}",
        [row[c] for c in columns])
    return row


def weight_rows(conn, user_id, limit=60):
    return conn.execute(
        "SELECT * FROM weights WHERE user_id=? AND deleted=0"
        " ORDER BY recorded_at DESC LIMIT ?", (user_id, limit)).fetchall()


# ---------------------------------------------------------------------- foods

# A search result list shows a name, a serving and a calorie figure, and the
# four macros for the preview. The full row is 42 columns, most of them the
# per-100 figures and trace minerals that only the detail view reads.
# Selecting them for every row of every search is the plainest kind of
# overfetch, and over a hosted database it is paid for in egress on every
# keystroke-driven request.
SEARCH_COLUMNS = (
    "food_id", "name", "food_group", "serving_label", "serving_size",
    "serving_unit", "energy_kcal", "carbohydrate_g", "protein_g",
    "total_fat_g", "suppress_nutrients", "trace_nutrients", "bulk_serving",
)


def search_foods(conn, query, limit=30):
    """Foods whose name matches, best matches first.

    A name beginning with the query ranks above one merely containing it, so
    searching "rice" offers rice before fried chicken with rice.

    Returns only the columns a result list needs; use food_by_id for the whole
    row.
    """
    columns = ",".join(SEARCH_COLUMNS)
    text = (query or "").strip().lower()
    if not text:
        return conn.execute(
            f"SELECT {columns} FROM foods ORDER BY name LIMIT ?",
            (limit,)).fetchall()
    like = f"%{text}%"
    starts = f"{text}%"
    return conn.execute(
        f"SELECT {columns} FROM foods WHERE lower(name) LIKE ?"
        " ORDER BY CASE WHEN lower(name) LIKE ? THEN 0 ELSE 1 END, name"
        " LIMIT ?", (like, starts, limit)).fetchall()


def food_by_id(conn, food_id):
    return conn.execute("SELECT * FROM foods WHERE food_id=?",
                        (food_id,)).fetchone()


def food_dict(row):
    """A food row with its suppressed nutrients removed.

    The suppression is applied here rather than in each template, so no screen
    can show a figure the import marked as contradicting itself.
    """
    if row is None:
        return None
    data = dict(row)
    hidden = [h for h in (data.get("suppress_nutrients") or "").split(",") if h]
    for nutrient in hidden:
        data[nutrient] = None
        data[f"per100_{nutrient}"] = None
    data["suppressed"] = hidden
    data["trace"] = [t for t in (data.get("trace_nutrients") or "").split(",") if t]

    # HPB's column names and the names the rules use are not the same, so the
    # canonical four are aliased here. logic.scale_nutrition takes any mapping
    # with these keys, which is how one function scales both a food and a
    # recipe; without the aliases it would need a branch per source.
    data["kcal"] = data.get("energy_kcal")
    data["carbs_g"] = data.get("carbohydrate_g")
    data["fat_g"] = data.get("total_fat_g")
    data["serving"] = data.get("serving_label")
    return data


def recipe_dicts(rows):
    """Recipes store lists as joined text; the rules want real lists.

    Ids are namespaced because meals can also arrive from TheMealDB, whose ids
    look like "mdb-52772". Two sources sharing a bare integer would collide.
    """
    return [{
        "id": f"local-{r['id']}",
        "source": "local",
        "estimated": False,
        "name": r["name"],
        "kcal": r["kcal"],
        "carbs_g": r["carbs_g"],
        "protein_g": r["protein_g"],
        "fat_g": r["fat_g"],
        "minutes": r["minutes"],
        "allergens": [a for a in (r["allergens"] or "").split(",") if a],
        "diet_types": [d for d in (r["diet_types"] or "").split(",") if d],
        "ingredients": [i for i in (r["ingredients"] or "").split("|") if i],
    } for r in rows]


# ---------------------------------------------------------------------------
# Admin panel reads.
#
# Every figure the panel shows is counted here, from the live database, at the
# moment the page is drawn. None of it is cached and none of it is seeded:
# an admin page that says 41 accounts is saying there are 41 rows in `users`.
# That is the whole point of the panel, so a stale or invented number would
# be worse than no number.
#
# These are reads. The two writes an admin has over an account -- disable and
# promote -- are the last two functions, and nothing here deletes anything.
# ---------------------------------------------------------------------------

def _day_cutoff(days):
    """The ISO date `days` ago, for comparing against a stored date string.

    Dates are stored as ISO text, so `substr(col, 1, 10) >= '2026-11-06'`
    compares them correctly without either engine's date functions -- SQLite
    has date(), Postgres does not, and the portable form is plain string
    comparison on a fixed-width prefix.
    """
    from datetime import datetime, timedelta, timezone
    return (datetime.now(timezone.utc) - timedelta(days=days)).date().isoformat()


def admin_overview(conn):
    """The counts behind the overview page."""
    # Rows come back as dicts, not tuples, so every count is aliased and read
    # by name. `SELECT COUNT(*)` with no alias gives a key that differs
    # between the two engines, and row[0] does not work on a dict at all.
    def one(sql, *args):
        row = conn.execute(sql, args).fetchone()
        return (row["n"] if row else 0) or 0

    week = _day_cutoff(7)
    return {
        "users": one("SELECT COUNT(*) AS n FROM users"),
        "admins": one("SELECT COUNT(*) AS n FROM users WHERE is_admin = 1"),
        "disabled": one("SELECT COUNT(*) AS n FROM users WHERE disabled = 1"),
        "with_profile": one("SELECT COUNT(*) AS n FROM profile"),
        "foods": one("SELECT COUNT(*) AS n FROM foods"),
        "recipes": one("SELECT COUNT(*) AS n FROM recipes"),
        # Tombstoned rows are still rows, but they are not food anybody ate.
        "entries": one("SELECT COUNT(*) AS n FROM entries WHERE deleted = 0"),
        "entries_week": one(
            "SELECT COUNT(*) AS n FROM entries WHERE deleted = 0"
            " AND substr(eaten_at, 1, 10) >= ?", week),
        "weights": one("SELECT COUNT(*) AS n FROM weights WHERE deleted = 0"),
        "custom_foods": one(
            "SELECT COUNT(*) AS n FROM custom_foods WHERE deleted = 0"),
        # Signed-in devices, not people: one account on a phone and a tablet
        # is two. Expired rows are excluded rather than counted as sessions.
        "sessions": one(
            "SELECT COUNT(*) AS n FROM sessions WHERE expires_at > ?",
            now_iso_utc()),
        "active_week": one(
            "SELECT COUNT(DISTINCT user_id) AS n FROM entries"
            " WHERE deleted = 0 AND substr(eaten_at, 1, 10) >= ?", week),
    }


def now_iso_utc():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# A LIKE pattern is built from user input on the admin search box, so `%` and
# `_` are escaped: without it, searching for "a_b" matches "aXb", and a search
# for "%" matches every account.
def _escape_like(text):
    return (text.replace("\\", "\\\\")
                .replace("%", "\\%")
                .replace("_", "\\_"))


def admin_users(conn, query="", limit=50, offset=0):
    """Accounts with their profile and how much they have logged.

    LEFT JOIN, because an account that registered but never finished setup has
    no profile row and still has to appear -- those are exactly the accounts
    an admin is looking for.
    """
    where, args = "", []
    if query.strip():
        pattern = f"%{_escape_like(query.strip().lower())}%"
        where = ("WHERE lower(u.email) LIKE ? ESCAPE '\\'"
                 " OR lower(u.name) LIKE ? ESCAPE '\\'")
        args = [pattern, pattern]

    rows = conn.execute(
        f"""
        SELECT u.id, u.email, u.name, u.created_at, u.is_admin, u.disabled,
               p.goal, p.target_kcal, p.age, p.gender, p.weight_kg,
               p.updated_at AS profile_updated,
               (SELECT COUNT(*) FROM entries e
                 WHERE e.user_id = u.id AND e.deleted = 0) AS entry_count,
               (SELECT MAX(e.eaten_at) FROM entries e
                 WHERE e.user_id = u.id AND e.deleted = 0) AS last_entry
          FROM users u
          LEFT JOIN profile p ON p.user_id = u.id
          {where}
         ORDER BY u.created_at DESC
         LIMIT ? OFFSET ?
        """, (*args, limit, offset)).fetchall()
    return [dict(r) for r in rows]


def admin_user_count(conn, query=""):
    if not query.strip():
        row = conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()
        return row["n"] if row else 0
    pattern = f"%{_escape_like(query.strip().lower())}%"
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM users"
        " WHERE lower(email) LIKE ? ESCAPE '\\'"
        "    OR lower(name) LIKE ? ESCAPE '\\'", (pattern, pattern)).fetchone()
    return row["n"] if row else 0


def admin_user(conn, user_id):
    rows = conn.execute(
        """
        SELECT u.id, u.email, u.name, u.created_at, u.is_admin, u.disabled,
               p.goal, p.target_kcal, p.computed_target_kcal, p.age, p.gender,
               p.height_cm, p.weight_kg, p.target_weight_kg, p.activity_level,
               p.allergens, p.diet_types, p.preferences, p.restrictions,
               p.updated_at AS profile_updated
          FROM users u
          LEFT JOIN profile p ON p.user_id = u.id
         WHERE u.id = ?
        """, (user_id,)).fetchall()
    return dict(rows[0]) if rows else None


def admin_user_activity(conn, user_id, days=30):
    """One row per day: how many entries and how many calories.

    Grouped on the date prefix of the stored timestamp rather than a date
    function, for the reason in _day_cutoff.
    """
    rows = conn.execute(
        """
        SELECT substr(eaten_at, 1, 10) AS day,
               COUNT(*) AS entries,
               SUM(kcal) AS kcal
          FROM entries
         WHERE user_id = ? AND deleted = 0 AND substr(eaten_at, 1, 10) >= ?
         GROUP BY substr(eaten_at, 1, 10)
         ORDER BY day DESC
        """, (user_id, _day_cutoff(days))).fetchall()
    return [dict(r) for r in rows]


def admin_sessions(conn, limit=40):
    """Signed-in devices, newest first -- the real sign-in log.

    This is every session the server would accept right now. Expired rows are
    left out: a session that no longer works is not an access path, and
    listing it as one would misreport who can reach the account.
    """
    rows = conn.execute(
        """
        SELECT s.created_at, s.expires_at, u.email, u.name, u.id AS user_id,
               u.is_admin, u.disabled
          FROM sessions s
          JOIN users u ON u.id = s.user_id
         WHERE s.expires_at > ?
         ORDER BY s.created_at DESC
         LIMIT ?
        """, (now_iso_utc(), limit)).fetchall()
    return [dict(r) for r in rows]


def admin_goal_distribution(conn):
    """How many accounts chose each goal, from the profiles themselves."""
    rows = conn.execute(
        """
        SELECT goal,
               COUNT(*) AS users,
               AVG(target_kcal) AS avg_target
          FROM profile
         WHERE goal IS NOT NULL AND goal <> ''
         GROUP BY goal
         ORDER BY COUNT(*) DESC
        """).fetchall()
    return [dict(r) for r in rows]


def admin_allergen_counts(conn):
    """How many accounts avoid each allergen.

    `profile.allergens` is a comma-joined token list, so the split happens
    here rather than in SQL: neither engine has a portable string-split that
    is worth the complexity for a table this size.
    """
    tally = {}
    rows = conn.execute("SELECT allergens, diet_types FROM profile").fetchall()
    for row in rows:
        for token in (row["allergens"] or "").split(","):
            token = token.strip()
            if token:
                tally[token] = tally.get(token, 0) + 1
    return sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))


def admin_diet_counts(conn):
    tally = {}
    for row in conn.execute("SELECT diet_types FROM profile").fetchall():
        for token in (row["diet_types"] or "").split(","):
            token = token.strip()
            if token:
                tally[token] = tally.get(token, 0) + 1
    return sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))


def admin_food_groups(conn):
    rows = conn.execute(
        """
        -- Aliased `food_count`, not `items`: these rows are rendered in
        -- Jinja, where `row.items` finds the dict's own .items method
        -- instead of the column and formats it as a bound method.
        SELECT food_group, COUNT(*) AS food_count,
               AVG(energy_kcal) AS avg_kcal
          FROM foods
         WHERE food_group IS NOT NULL AND food_group <> ''
         GROUP BY food_group
         ORDER BY COUNT(*) DESC
        """).fetchall()
    return [dict(r) for r in rows]


def admin_foods(conn, query="", limit=50, offset=0):
    where, args = "", []
    if query.strip():
        pattern = f"%{_escape_like(query.strip().lower())}%"
        where = ("WHERE lower(name) LIKE ? ESCAPE '\\'"
                 " OR lower(food_group) LIKE ? ESCAPE '\\'")
        args = [pattern, pattern]
    rows = conn.execute(
        f"""SELECT food_id, name, food_group, serving_label, energy_kcal,
                   protein_g, carbohydrate_g, total_fat_g, sodium_mg
              FROM foods {where}
             ORDER BY name LIMIT ? OFFSET ?""",
        (*args, limit, offset)).fetchall()
    return [dict(r) for r in rows]


def admin_food_count(conn, query=""):
    if not query.strip():
        row = conn.execute("SELECT COUNT(*) AS n FROM foods").fetchone()
        return row["n"] if row else 0
    pattern = f"%{_escape_like(query.strip().lower())}%"
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM foods"
        " WHERE lower(name) LIKE ? ESCAPE '\\'"
        "    OR lower(food_group) LIKE ? ESCAPE '\\'",
        (pattern, pattern)).fetchone()
    return row["n"] if row else 0


def admin_most_logged(conn, limit=15, days=30):
    """The foods people actually log, which is not the same as what is listed."""
    rows = conn.execute(
        """
        SELECT food_name, COUNT(*) AS times, AVG(kcal) AS avg_kcal
          FROM entries
         WHERE deleted = 0 AND substr(eaten_at, 1, 10) >= ?
         GROUP BY food_name
         ORDER BY COUNT(*) DESC, food_name
         LIMIT ?
        """, (_day_cutoff(days), limit)).fetchall()
    return [dict(r) for r in rows]


def admin_recipes(conn):
    rows = conn.execute(
        "SELECT id, name, kcal, protein_g, minutes, allergens, diet_types,"
        " ingredients FROM recipes ORDER BY name").fetchall()
    return [dict(r) for r in rows]


def admin_daily_totals(conn, days=14):
    """Entries and distinct users per day, for the reports page."""
    rows = conn.execute(
        """
        SELECT substr(eaten_at, 1, 10) AS day,
               COUNT(*) AS entries,
               COUNT(DISTINCT user_id) AS users,
               SUM(kcal) AS kcal
          FROM entries
         WHERE deleted = 0 AND substr(eaten_at, 1, 10) >= ?
         GROUP BY substr(eaten_at, 1, 10)
         ORDER BY day DESC
        """, (_day_cutoff(days),)).fetchall()
    return [dict(r) for r in rows]


# --- the two writes -------------------------------------------------------

def admin_set_disabled(conn, user_id, disabled):
    """Block or unblock sign-in, and sign out every device on the account.

    Revoking the sessions is the half that matters. Without it, disabling an
    account stops nothing until the existing tokens expire, which is up to
    thirty days of continued access by something the panel is now showing as
    blocked. The panel would be lying, and lying in the direction that counts.
    """
    conn.execute("UPDATE users SET disabled = ? WHERE id = ?",
                 (1 if disabled else 0, user_id))
    if disabled:
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    conn.commit()


def admin_set_admin(conn, user_id, is_admin):
    conn.execute("UPDATE users SET is_admin = ? WHERE id = ?",
                 (1 if is_admin else 0, user_id))
    conn.commit()


def admin_count_admins(conn):
    """Enabled admins. Used to refuse the change that locks everyone out."""
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM users WHERE is_admin = 1 AND disabled = 0"
    ).fetchone()
    return row["n"] if row else 0
