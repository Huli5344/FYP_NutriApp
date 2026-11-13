"""Grant or remove administrator access on an account.

    python tools/make_admin.py --email you@example.com
    python tools/make_admin.py --email them@example.com --remove
    python tools/make_admin.py --list

Run it from the project root, with the same DATABASE_URL the server uses --
`backend/.env.local` is picked up automatically, so in practice:

    cd backend && python ../tools/make_admin.py --email you@example.com

A freshly deployed database has no administrators at all, which means
/admin is reachable by nobody. That is the correct starting state: the panel
can see and block every account, so access to it should be granted
deliberately, once, rather than defaulted on for whoever registers first.

This is the only way in from cold. After the first administrator exists, the
rest can be promoted from the panel itself.

It changes one flag. It does not create accounts, set passwords or touch
anyone's data -- the account must already exist, having registered through
the app or the web prototype like anybody else.
"""

import argparse
import os
import sys

# backend/ holds the modules this needs, and is where .env.local lives.
HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(os.path.dirname(HERE), "backend")
sys.path.insert(0, BACKEND)

import accounts        # noqa: E402
import database        # noqa: E402
import db              # noqa: E402


def describe_target():
    """Which database this is about to change.

    Printed before anything is written, because the difference between the
    local SQLite file and the production Postgres is one environment variable
    and no visible difference at the prompt.
    """
    return db.safe_target_description()


def needs_migration(conn):
    """True when this database predates the admin panel.

    Checked before any query that mentions the new columns. Without it the
    first thing to touch them is a SELECT, and the error is a psycopg
    traceback ending in `column "is_admin" does not exist` -- which is true,
    but says nothing about the deploy that has not happened yet.
    """
    return "is_admin" not in db.columns(conn, "users")


def explain_migration():
    print("This database does not have the admin columns yet, so it predates")
    print("the admin panel. Nothing here has been changed.")
    print()
    print("They are added by database.init(), which Render runs on every")
    print("deploy. The usual order is:")
    print()
    print("  1. git push          -- Render redeploys and adds the columns")
    print("  2. run this again    -- to grant the first administrator")
    print()
    print("To add them from here instead, against the database named above:")
    print('     python -c "import database; database.init()"')
    print("  run from the backend folder. This is additive and safe to repeat;")
    print("  it creates nothing that is not missing and deletes nothing.")
    return 1


def show_list(conn):
    rows = conn.execute(
        "SELECT email, name, is_admin, disabled FROM users"
        " ORDER BY is_admin DESC, email").fetchall()
    if not rows:
        print("No accounts exist yet.")
        return 0

    admins = [r for r in rows if r["is_admin"]]
    print(f"{len(rows)} account(s), {len(admins)} administrator(s):\n")
    for row in rows:
        marks = []
        if row["is_admin"]:
            marks.append("admin")
        if row["disabled"]:
            marks.append("blocked")
        suffix = f"  [{', '.join(marks)}]" if marks else ""
        print(f"  {row['email']:38} {row['name']}{suffix}")
    if not admins:
        print("\nNobody can open /admin. Grant access with --email.")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--email", help="the account to change")
    parser.add_argument("--remove", action="store_true",
                        help="remove administrator access instead of granting it")
    parser.add_argument("--list", action="store_true",
                        help="show every account and who is an administrator")
    args = parser.parse_args()

    if not args.email and not args.list:
        parser.print_help()
        return 1

    print(f"Database: {describe_target()}\n")
    conn = database.connect()
    try:
        # Before anything that reads or writes is_admin, including --list.
        if needs_migration(conn):
            return explain_migration()

        if args.list:
            return show_list(conn)

        user = accounts.find_user_by_email(conn, args.email)
        if user is None:
            print(f"No account with the address {args.email}.")
            print("\nThe account has to exist first -- register it in the app,"
                  " then run this again.")
            print("Run with --list to see which accounts exist.")
            return 1

        granting = not args.remove
        if bool(user["is_admin"]) == granting:
            state = "already" if granting else "not"
            print(f"{user['name']} <{user['email']}> is {state} an"
                  f" administrator. Nothing to do.")
            return 0

        # Refuse the change that locks the panel. The panel itself refuses it
        # too, but this script is the thing you would reach for to undo a
        # mistake, so it must not be able to create one.
        if not granting and database.admin_count_admins(conn) <= 1:
            print(f"{user['email']} is the only administrator left.")
            print("Removing them would leave /admin reachable by nobody.")
            print("Grant it to somebody else first, then run this again.")
            return 1

        database.admin_set_admin(conn, user["id"], granting)
        verb = "now an administrator" if granting else "no longer an administrator"
        print(f"{user['name']} <{user['email']}> is {verb}.")

        if granting:
            print("\nThey sign in at the app's normal sign-in page with their"
                  " own password,")
            print("then open  /admin  on the same site.")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
