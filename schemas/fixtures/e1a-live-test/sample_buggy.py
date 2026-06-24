def search_users(name):
    # Synthetic test fixture for E1.a — DO NOT use in production.
    # Intentionally contains a SQL injection so code-reviewer has a
    # CRITICAL finding to emit through the envelope.
    query = f"SELECT * FROM users WHERE name = '{name}'"
    return db.execute(query).fetchall()


def add_tag(item, tags=[]):
    # Mutable default argument — HIGH finding fodder.
    tags.append(item)
    return tags
