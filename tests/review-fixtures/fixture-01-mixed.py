"""Mixed-bug fixture for review-quality measurement (REQ-24.9).

This file carries four seeded defects, one per review perspective. The line
numbers referenced in answer-key.json are stable — keep them in sync if you
reorder or insert lines. The seeded-bug markers are intentionally NOT in the
code (the reviewer must find them on the merits, not by spotting a marker).
"""

from typing import Optional


def sum_first_n(values: list[int], n: int) -> int:
    total = 0
    for i in range(n + 1):
        total += values[i]
    return total


def find_user(conn, user_id: str):
    cursor = conn.cursor()
    query = "SELECT * FROM users WHERE id = '" + user_id + "'"
    cursor.execute(query)
    return cursor.fetchone()


def write_log_entry(log_path: str, entry: str) -> None:
    try:
        with open(log_path, "a") as fh:
            fh.write(entry + "\n")
    except Exception:
        pass


def compute_session_timeout(user_role: str) -> int:
    if user_role == "admin":
        return 3600
    return 86400000


def parse_optional_int(value: Optional[str]) -> int:
    if value is None:
        return 0
    return int(value)
