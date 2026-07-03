"""create_owner.py — one-shot script to bootstrap the first owner user.

Usage:
    python -m modules.auth.scripts.create_owner

Prompts for email + password (twice for confirmation), hashes the
password with bcrypt, and inserts a User row with role=Role.owner.
Refuses to run if any owner already exists — subsequent owners must
be promoted by an existing owner via the admin UI (not shipped in
v0.26.0; add per project).
"""

from __future__ import annotations

import getpass
import sys

from modules.db import session
from modules.auth.models.user import Role, User
from modules.auth.password_service import (
    PasswordTooWeak,
    check_strength,
    hash_password,
)


def main() -> int:
    existing = session.query(User).filter(User.role == Role.owner).first()
    if existing is not None:
        print(f"ERROR: an owner already exists: {existing.email}", file=sys.stderr)
        print("Promote additional owners via the admin UI (not scripted).",
              file=sys.stderr)
        return 1

    email = input("Owner email: ").strip().lower()
    if not email or "@" not in email:
        print("ERROR: invalid email", file=sys.stderr)
        return 2

    while True:
        pw1 = getpass.getpass("Password: ")
        try:
            check_strength(pw1)
        except PasswordTooWeak as e:
            print(f"Too weak: {e.reason}", file=sys.stderr)
            continue
        pw2 = getpass.getpass("Confirm password: ")
        if pw1 != pw2:
            print("Passwords didn't match. Try again.", file=sys.stderr)
            continue
        break

    display = input("Display name (optional): ").strip() or None

    user = User(
        email=email,
        password_hash=hash_password(pw1),
        role=Role.owner,
        display_name=display,
    )
    session.add(user)
    session.commit()
    print(f"✓ Owner {email} created (id={user.id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
