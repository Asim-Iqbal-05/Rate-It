"""Tests for the one-off likes backfill's core logic (no AWS).

Run from the repo root:  python3 -m unittest discover -s tests/backfill
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "one-off", "likes-redesign"))
import backfill_likes as b  # noqa: E402


def row(user, post):
    return {"userId": user, "experienceId": post, "createdAt": "2026-10-07T00:00:00+00:00"}


class BackfillTests(unittest.TestCase):
    def test_count_rows_are_skipped_and_likes_written(self):
        pages = [[row("u1", "p1"), row("COUNT", "p1")], [row("u2", "p1")]]
        written_rows = []
        w, already, skipped = b.backfill(iter(pages), lambda r: written_rows.append(r) or True, dry_run=False)
        self.assertEqual((w, already, skipped), (2, 0, 1))
        self.assertEqual([r["userId"] for r in written_rows], ["u1", "u2"])

    def test_existing_likes_are_not_written_again(self):
        w, already, skipped = b.backfill(iter([[row("u1", "p1")]]), lambda r: False, dry_run=False)
        self.assertEqual((w, already, skipped), (0, 1, 0))

    def test_dry_run_writes_nothing(self):
        called = []
        w, _, _ = b.backfill(iter([[row("u1", "p1")]]), lambda r: called.append(r), dry_run=True)
        self.assertEqual((w, called), (1, []))


if __name__ == "__main__":
    unittest.main()
