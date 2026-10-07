"""Unit tests for the Reconciliation Lambda with DynamoDB/CloudWatch stubbed.

Run from the repo root:  python3 -m unittest discover -s tests/reconciliation
"""
import os
import sys
import unittest
from unittest import mock

os.environ.update(AWS_DEFAULT_REGION="us-west-2", LIKES_TABLE="likes", COUNTERS_TABLE="counters",
                  EXPERIENCES_TABLE="experiences", SETTLE_SECONDS="0")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "services", "reconciliation"))
import handler  # noqa: E402


class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.patches = {n: mock.patch.object(handler, n) for n in ("dynamodb", "cloudwatch")}
        self.m = {n: p.start() for n, p in self.patches.items()}
        for p in self.patches.values():
            self.addCleanup(p.stop)
        self.likes = {}      # post -> number of like rows
        self.counters = {}   # post -> stored count
        self.live = set()    # posts that exist in Experiences
        self.updates = []
        self.m["dynamodb"].scan.side_effect = self.scan
        self.m["dynamodb"].batch_get_item.side_effect = self.batch_get
        self.m["dynamodb"].update_item.side_effect = lambda **kw: self.updates.append(kw)

    def scan(self, **kw):
        if kw["TableName"] == "likes":
            items = [{"experienceId": {"S": p}} for p, n in self.likes.items() for _ in range(n)]
        else:
            items = [{"pk": {"S": f"POST#{p}"}, "likeCount": {"N": str(c)}} for p, c in self.counters.items()]
            items.append({"pk": {"S": "BATCH#x#0"}})  # a marker must never be read as a post
            items = [i for i in items if i["pk"]["S"].startswith("POST#")]
        return {"Items": items}

    def batch_get(self, RequestItems):
        keys = RequestItems["experiences"]["Keys"]
        return {"Responses": {"experiences": [k for k in keys if k["experienceId"]["S"] in self.live]}}

    def run_handler(self, event=None):
        return handler.lambda_handler(event or {}, None)

    def metric_value(self):
        return self.m["cloudwatch"].put_metric_data.call_args.kwargs["MetricData"][0]["Value"]

    def test_everything_matches_publishes_zero(self):
        self.likes, self.counters, self.live = {"a": 2}, {"a": 2}, {"a"}
        self.assertEqual(self.run_handler()["drift"], 0)
        self.assertEqual(self.metric_value(), 0)

    def test_detects_wrong_missing_and_stale_counters(self):
        self.likes = {"a": 3, "b": 2}               # a counted low, b has no counter
        self.counters = {"a": 1, "c": 4}            # c has a count but no like rows
        self.live = {"a", "b", "c"}
        result = self.run_handler()
        self.assertEqual(result["differences"], {"a": 2, "b": 2, "c": -4})
        self.assertEqual(self.metric_value(), 3)
        self.assertEqual(self.updates, [])          # detect mode never writes

    def test_deleted_posts_are_not_drift(self):
        # Like rows outlive a deleted post (accepted) and its counter is gone.
        self.likes, self.counters, self.live = {"gone": 5}, {}, set()
        self.assertEqual(self.run_handler()["drift"], 0)

    def test_repair_uses_add_with_the_difference(self):
        self.likes, self.counters, self.live = {"a": 3}, {"a": 1}, {"a"}
        self.run_handler({"repair": True})
        self.assertEqual(len(self.updates), 1)
        self.assertEqual(self.updates[0]["UpdateExpression"], "ADD likeCount :d")
        self.assertEqual(self.updates[0]["ExpressionAttributeValues"][":d"], {"N": "2"})
        self.assertEqual(self.updates[0]["Key"], {"pk": {"S": "POST#a"}})

    def test_difference_that_changes_between_passes_is_not_reported(self):
        # A like lands between the two passes: the counter catches up, so it is lag, not drift.
        self.likes, self.live = {"a": 2}, {"a"}
        self.counters = {"a": 1}
        original = self.m["dynamodb"].scan.side_effect
        passes = {"n": 0}

        def scan_then_catch_up(**kw):
            if kw["TableName"] == "likes":
                passes["n"] += 1
                if passes["n"] == 2:
                    self.counters["a"] = 2
            return original(**kw)

        self.m["dynamodb"].scan.side_effect = scan_then_catch_up
        self.assertEqual(self.run_handler()["drift"], 0)


if __name__ == "__main__":
    unittest.main()
