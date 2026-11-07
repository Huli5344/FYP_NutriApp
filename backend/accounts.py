"""User accounts: password hashing, and tokens that identify a device.

Pure functions plus narrow database helpers, so the hashing can be tested
without a server and the policy is all in one file.

**Passwords are never stored.** What is stored is a PBKDF2-HMAC-SHA256 digest
with a per-user random salt and a deliberately high iteration count. Three
properties matter and each is there for a reason:

  * *Salted per user.* Two people choosing the same password get different
    digests, so one cracked password reveals nothing about the other account,
    and a precomputed table is useless.
  * *Slow on purpose.* 200,000 iterations costs this server a few milliseconds
    per sign-in and costs an attacker the same per guess. That asymmetry is the
    whole point; a fast hash like SHA-256 alone would let a leaked table be
    brute-forced at millions of guesses a second.
  * *Compared in constant time.* `hmac.compare_digest` does not stop early at
    the first wrong byte, so the time a comparison takes says nothing about how
    much of the digest was right.

**Tokens are random, not signed.** A row in `sessions` holds a 256-bit random
token against a user. That is a deliberate choice over a JWT: it can be
revoked by deleting the row, it carries no claims that could be tampered with,
and there is no signature verification to get subtly wrong. The cost is a
database lookup per request, which is a cheap indexed read.

What this is not: there is no email verification, no password reset, no rate
limiting on sign-in attempts, and no lockout. Those belong in a product, and
their absence is listed here rather than left for someone to discover.
"""

import hashlib
import hmac
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone

# Cost parameters. Raising the iteration count invalidates nothing: the count
# is stored in each digest, so old passwords keep verifying at the count they
# were created with and are rehashed on the next successful sign-in.
HASH_NAME = "sha256"
ITERATIONS = 200_000
SALT_BYTES = 16
TOKEN_BYTES = 32

# How long a token stays valid without being used.
SESSION_DAYS = 30

MIN_PASSWORD_LENGTH = 8
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


# ------------------------------------------------------------------ hashing

def hash_password(password, salt=None, iterations=ITERATIONS):
    """A verifier string for a password.

    Format: `pbkdf2_sha256$<iterations>$<salt_hex>$<digest_hex>`. The
    parameters travel with the digest so the cost can be raised later without
    locking anyone out.
    """
    if salt is None:
        salt = secrets.token_bytes(SALT_BYTES)
    digest = hashlib.pbkdf2_hmac(HASH_NAME, password.encode("utf-8"), salt,
                                 iterations)
    return f"pbkdf2_{HASH_NAME}${iterations}${salt.hex()}${digest.hex()}"


def verify_password(password, stored):
    """True if `password` produces `stored`.

    Returns False rather than raising on a malformed or empty verifier, so a
    corrupt row denies access instead of erroring the request.
    """
    if not stored or not password:
        return False
    try:
        algorithm, iterations, salt_hex, digest_hex = stored.split("$")
    except ValueError:
        return False
    if algorithm != f"pbkdf2_{HASH_NAME}":
        return False
    try:
        iterations = int(iterations)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(digest_hex)
    except ValueError:
        return False

    candidate = hashlib.pbkdf2_hmac(HASH_NAME, password.encode("utf-8"), salt,
                                    iterations)
    # Constant time: the duration must not depend on how many bytes matched.
    return hmac.compare_digest(candidate, expected)


def needs_rehash(stored, iterations=ITERATIONS):
    """True when a verifier was made with a weaker cost than we now use."""
    try:
        return int(stored.split("$")[1]) < iterations
    except (AttributeError, IndexError, ValueError):
        return True


# --------------------------------------------------------------- validation

def validate_registration(email, password, name):
    """Problems with a sign-up, as a list of messages. Empty means acceptable."""
    problems = []
    if not EMAIL_PATTERN.match((email or "").strip()):
        problems.append("Enter a valid email address.")
    if len(password or "") < MIN_PASSWORD_LENGTH:
        problems.append(
            f"Password must be at least {MIN_PASSWORD_LENGTH} characters.")
    if not (name or "").strip():
        problems.append("Name is required.")
    return problems


def normalise_email(email):
    """Lowercased and trimmed.

    Addresses are compared case-insensitively, so the stored form has to be
    normalised or `Guest@test.com` would register a second account alongside
    `guest@test.com`.
    """
    return (email or "").strip().lower()


# ------------------------------------------------------------------ storage

def create_user(conn, email, password, name):
    """Insert a user and return the row. Caller validates first."""
    user_id = str(uuid.uuid4())
    conn.execute(
        "INSERT INTO users (id, email, name, password_hash, created_at)"
        " VALUES (?,?,?,?,?)",
        (user_id, normalise_email(email), name.strip(),
         hash_password(password), now_iso()))
    return find_user_by_id(conn, user_id)


def find_user_by_email(conn, email):
    return conn.execute("SELECT * FROM users WHERE email=?",
                        (normalise_email(email),)).fetchone()


def find_user_by_id(conn, user_id):
    return conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()


def authenticate(conn, email, password):
    """The user for these credentials, or None.

    A missing account still pays the cost of one hash comparison. Returning
    early would make "no such email" measurably faster than "wrong password",
    which tells an attacker which addresses are registered.
    """
    user = find_user_by_email(conn, email)
    stored = user["password_hash"] if user else hash_password("not-a-password")
    if not verify_password(password, stored) or user is None:
        return None

    if needs_rehash(stored):
        conn.execute("UPDATE users SET password_hash=? WHERE id=?",
                     (hash_password(password), user["id"]))
    return user


def issue_token(conn, user_id):
    """A fresh session token for a user."""
    token = secrets.token_urlsafe(TOKEN_BYTES)
    expires = datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)
    conn.execute(
        "INSERT INTO sessions (token, user_id, created_at, expires_at)"
        " VALUES (?,?,?,?)",
        (token, user_id, now_iso(), expires.isoformat(timespec="seconds")))
    return token


def user_for_token(conn, token):
    """The user a token identifies, or None if unknown or expired."""
    if not token:
        return None
    row = conn.execute(
        "SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id"
        " WHERE s.token=? AND s.expires_at > ?",
        (token, now_iso())).fetchone()
    return row


def revoke_token(conn, token):
    conn.execute("DELETE FROM sessions WHERE token=?", (token,))


def revoke_all_tokens(conn, user_id):
    """Used when a password changes: other devices should not stay signed in."""
    conn.execute("DELETE FROM sessions WHERE user_id=?", (user_id,))


def purge_expired_sessions(conn):
    conn.execute("DELETE FROM sessions WHERE expires_at <= ?", (now_iso(),))


def bearer_token(headers):
    """Pull a token out of an Authorization header."""
    value = (headers.get("Authorization") or "").strip()
    if value.lower().startswith("bearer "):
        return value[7:].strip()
    return None


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
