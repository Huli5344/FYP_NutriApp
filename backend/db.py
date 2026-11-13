"""Database access, speaking either Postgres or SQLite.

The deployed app runs on Postgres (Neon). The tests run on a local SQLite file,
because a test suite that needs a network is a test suite that stops being run.
Both go through this module, which is the only place that knows the difference.

Two dialect gaps are closed here rather than in every query:

  * **Placeholders.** SQLite writes `?`, Postgres writes `%s`. Every query in
    this project is written with `?` and translated on the way out, so the SQL
    in `app.py` reads the same whichever database is behind it. The translation
    skips anything inside a quoted string, so a literal question mark in text
    is left alone.

  * **Rows.** `sqlite3.Row` and psycopg's tuples are both replaced with plain
    dicts, so `row["name"]` works and `dict(row)` is a no-op.

Everything else was made portable by choosing portable SQL. `substr(x, 1, 10)`
instead of SQLite's `date(x)`; `ON CONFLICT ... DO NOTHING` instead of
`INSERT OR IGNORE`; `RETURNING` instead of an update followed by a select.
Both engines have had all three for years.

Set DATABASE_URL to use Postgres:

    export DATABASE_URL="postgresql://user:password@host/dbname?sslmode=require"

Leave it unset and the module falls back to a local SQLite file, which is what
the tests and a laptop demonstration use.
"""

import os
import re
import sqlite3

# psycopg is only needed when a Postgres URL is configured, so the import is
# deferred. That keeps the tests runnable, and a clone of this project usable,
# without installing a driver nobody is going to connect with.
try:                                     # pragma: no cover - import shim
    import psycopg
    from psycopg.rows import dict_row
except ImportError:                      # pragma: no cover
    psycopg = None
    dict_row = None

SQLITE_PATH = os.path.join(os.path.dirname(__file__), "module.db")

# Files `neon env pull` writes, in the order it prefers them. Searched from
# this file upwards, because the CLI writes into the project root while the
# backend runs from its own directory.
ENV_FILES = (".env.local", ".env")
ENV_SEARCH_DEPTH = 3


def _parse_env_file(path):
    """A minimal KEY=value reader.

    Hand-rolled rather than taking a dependency on python-dotenv: the format
    `neon env pull` writes is plain assignments, and a twenty-line parser is
    easier to audit than another package in requirements.txt.
    """
    values = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].lstrip()
                key, _, value = line.partition("=")
                if not _:
                    continue
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                if key:
                    values[key] = value
    except OSError:
        return {}
    return values


def load_env_files():
    """Load .env.local and .env into the environment, if present.

    A variable already set in the real environment always wins: an explicit
    `set DATABASE_URL=...` or a CI secret must not be silently overridden by a
    file left in the working tree.

    Called once at import. Safe when no such file exists, which is the normal
    case for the tests.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    directories = [here]
    for _ in range(ENV_SEARCH_DEPTH):
        parent = os.path.dirname(directories[-1])
        if parent == directories[-1]:
            break
        directories.append(parent)

    loaded = []
    # Nearest directory and highest-priority filename first; later files do
    # not overwrite what an earlier one supplied.
    for directory in directories:
        for name in ENV_FILES:
            path = os.path.join(directory, name)
            if not os.path.isfile(path):
                continue
            for key, value in _parse_env_file(path).items():
                if key not in os.environ:
                    os.environ[key] = value
            loaded.append(path)
    return loaded


LOADED_ENV_FILES = load_env_files()


def _env_url(name):
    """A connection string from the environment, or None if unset or blank."""
    url = (os.environ.get(name) or "").strip()
    return url or None


# `neon env pull` writes both of these. They address the same database by
# different routes, so either one alone is enough to run on: each selection
# below states a preference and falls back to the other.
#
# Preferring one and ignoring the other was a bug. With only
# DATABASE_URL_UNPOOLED set, schema creation connected to Postgres while
# is_postgres() -- which read DATABASE_URL alone -- still reported SQLite, so
# render_schema emitted `AUTOINCREMENT` and Postgres rejected it. A Postgres
# connection running a SQLite schema. Symmetry is what prevents that: every
# one of these answers from the same pair.

def database_url():
    """The URL the application should use, or None for SQLite.

    Prefers the pooled string, because this app opens one short-lived
    connection per request, which is what PgBouncer is for.

    Read on each call rather than captured at import, so a test can point the
    module at a different database without reloading it.
    """
    return _env_url("DATABASE_URL") or _env_url("DATABASE_URL_UNPOOLED")


def migration_url():
    """The URL to create or alter the schema with.

    Prefers the direct string. Neon's pooled connections run through PgBouncer
    in transaction mode, which has no session state, so DDL over them can fail
    in ways that never mention pooling.
    """
    return _env_url("DATABASE_URL_UNPOOLED") or _env_url("DATABASE_URL")


def looks_pooled(url):
    return bool(url) and "-pooler" in url


def is_postgres():
    """True when either configured URL points at Postgres."""
    return database_url() is not None


def safe_target_description():
    """Which database this process is pointed at, without the password.

    For messages that have to name the target -- a refusal to drop tables, a
    tool saying what it is about to change. The connection string contains the
    Neon password, so it is never the thing to print: this gives host and
    database name only.

    Also names the file .env.local when that is where the URL came from, since
    the usual way to end up pointed at production unexpectedly is a script run
    from the folder that holds it.
    """
    url = database_url()
    if url is None:
        return f"SQLite ({SQLITE_PATH})"

    # postgresql://user:password@host/dbname?params -- everything before and
    # including '@' is credentials and is dropped rather than masked.
    rest = url.split("@", 1)[-1]
    host_and_db = rest.split("?", 1)[0]
    where = ""
    if LOADED_ENV_FILES:
        where = f", configured by {', '.join(LOADED_ENV_FILES)}"
    return f"PostgreSQL at {host_and_db}{where}"


# ---------------------------------------------------------------- placeholders

_TOKENS = re.compile(r"""('(?:[^']|'')*'|"(?:[^"]|"")*")|(\?)|(%)""")


def translate(sql):
    """Rewrite `?` placeholders as `%s` for psycopg.

    Two things a naive `sql.replace("?", "%s")` gets wrong:

      * A question mark inside a string literal is text, not a placeholder.
      * psycopg binds client-side, so a literal `%` already in the SQL has to
        be doubled or it is read as the start of a format directive.

    Both are handled by walking quoted runs, placeholders and percent signs in
    one pass, so a quoted literal is copied out untouched while everything
    outside it is rewritten.
    """
    def swap(match):
        quoted, placeholder, percent = match.groups()
        if quoted is not None:
            return quoted                # text, not syntax
        if placeholder is not None:
            return "%s"
        return "%%"                      # literal percent, escaped

    return _TOKENS.sub(swap, sql)


def strip_comments(sql):
    """Drop `--` line comments, so a statement split cannot yield only a comment."""
    return "\n".join(
        line.split("--", 1)[0] for line in sql.splitlines())


# ---------------------------------------------------------------- connections


class Cursor:
    """A cursor that returns dicts and accepts `?` placeholders."""

    def __init__(self, cursor, postgres):
        self._cursor = cursor
        self._postgres = postgres

    def execute(self, sql, params=()):
        self._cursor.execute(translate(sql) if self._postgres else sql, params)
        return self

    def executemany(self, sql, seq):
        self._cursor.executemany(
            translate(sql) if self._postgres else sql, list(seq))
        return self

    def fetchone(self):
        row = self._cursor.fetchone()
        return self._as_dict(row)

    def fetchall(self):
        return [self._as_dict(r) for r in self._cursor.fetchall()]

    def _as_dict(self, row):
        if row is None:
            return None
        return dict(row) if not isinstance(row, dict) else row

    def __iter__(self):
        for row in self._cursor:
            yield self._as_dict(row)

    @property
    def rowcount(self):
        return self._cursor.rowcount

    @property
    def description(self):
        return self._cursor.description


class Connection:
    """Wraps a psycopg or sqlite3 connection behind one interface.

    Mirrors the small part of the sqlite3 API this project actually used, so
    the call sites did not have to change when Postgres arrived.
    """

    def __init__(self, raw, postgres):
        self._raw = raw
        self.postgres = postgres

    def execute(self, sql, params=()):
        if self.postgres:
            cursor = self._raw.cursor()
            return Cursor(cursor, True).execute(sql, params)
        return Cursor(self._raw.execute(sql, params), False)

    def executemany(self, sql, seq):
        if self.postgres:
            cursor = self._raw.cursor()
            return Cursor(cursor, True).executemany(sql, seq)
        return Cursor(self._raw.executemany(sql, seq), False)

    def executescript(self, script):
        """Run a multi-statement schema script.

        psycopg will not take several statements with parameters, but a schema
        script has none, so splitting on the statement terminator is safe here.
        Dollar-quoted bodies are not used anywhere in this project.
        """
        if not self.postgres:
            self._raw.executescript(script)
            return
        cursor = self._raw.cursor()
        # Comments are removed before splitting, or a trailing comment becomes
        # a "statement" of its own and the server rejects it.
        for statement in strip_comments(script).split(";"):
            if statement.strip():
                cursor.execute(statement)

    def commit(self):
        self._raw.commit()

    def rollback(self):
        self._raw.rollback()

    def close(self):
        self._raw.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self.commit()
        else:
            self.rollback()
        self.close()
        return False


def connect(for_migration=False):
    """Open a connection to whichever database is configured.

    `for_migration` asks for the direct, unpooled connection. Schema changes
    need session state that a pooled connection does not have.
    """
    url = migration_url() if for_migration else database_url()
    if url:
        if psycopg is None:              # pragma: no cover
            raise RuntimeError(
                "DATABASE_URL is set but psycopg is not installed. "
                'Run: pip install "psycopg[binary]"')
        # autocommit stays off: the sync endpoint depends on a transaction so
        # a half-applied push cannot be observed by another device's pull.
        return Connection(psycopg.connect(url, row_factory=dict_row), True)

    raw = sqlite3.connect(SQLITE_PATH)
    raw.row_factory = sqlite3.Row
    raw.execute("PRAGMA foreign_keys = ON")
    return Connection(raw, False)


# -------------------------------------------------------------------- schema

# Column types differ; everything else in the schema does not. Keeping one
# schema with substituted type names avoids maintaining two that drift.
TYPES = {
    "sqlite": {"real": "REAL", "int": "INTEGER", "text": "TEXT",
               "serial": "INTEGER PRIMARY KEY AUTOINCREMENT"},
    "postgres": {"real": "DOUBLE PRECISION", "int": "INTEGER", "text": "TEXT",
                 "serial": "INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"},
}


def render_schema(schema):
    """Substitute {real}, {int}, {text} and {serial} for the live dialect."""
    return schema.format(**TYPES["postgres" if is_postgres() else "sqlite"])


def table_exists(conn, table):
    try:
        conn.execute(f"SELECT 1 FROM {table} LIMIT 0")
        return True
    except Exception:
        conn.rollback()      # Postgres aborts the transaction on a failed query
        return False


def columns(conn, table):
    """Column names of a table, or an empty set if it does not exist.

    Read from a zero-row select rather than PRAGMA or information_schema, so
    one implementation covers both engines.
    """
    try:
        cursor = conn.execute(f"SELECT * FROM {table} LIMIT 0")
        return {d[0] for d in (cursor.description or ())}
    except Exception:
        conn.rollback()
        return set()
