"""Unit tests for the Counter Lambda with DynamoDB stubbed.

Run from the repo root:  python3 -m unittest discover -s tests/counter
(needs boto3 importable).
"""
import os
import sys
import unittest
from unittest import mock

os.environ.update(AWS_DEFAULT_REGION="us-west-2", COUNTERS_TABLE="counters")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "services", "counter"))
import handler  # noqa: E402
from botocore.exceptions import ClientError, ReadTimeoutError  # noqa: E402


def rec(event_id, name, post, user="u"):
    return {
        "eventID": event_id,
        "eventName": name,
        "dynamodb": {"Keys": {"userId": {"S": user}, "experienceId": {"S": post}}},
    }


def cancelled(*reasons):
    return ClientError(
        {"Error": {"Code": "TransactionCanceledException", "Message": ""},
         "CancellationReasons": [{"Code": r} for r in reasons]},
        "TransactWriteItems",
    )


class CounterTests(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(handler, "dynamodb")
        self.ddb = p.start()
        self.addCleanup(p.stop)
        s = mock.patch.object(handler.time, "sleep")
        s.start()
        self.addCleanup(s.stop)

    def run_batch(self, records):
        return handler.lambda_handler({"Records": records}, None)

    def updates(self, call):
        items = call.kwargs["TransactItems"]
        return {i["Update"]["Key"]["pk"]["S"]: i["Update"]["ExpressionAttributeValues"][":d"]["N"]
                for i in items if "Update" in i}

    def test_sums_per_post_and_one_transaction_for_the_batch(self):
        self.run_batch([rec("1", "INSERT", "a", "u1"), rec("2", "INSERT", "a", "u2"),
                        rec("3", "INSERT", "b", "u1"), rec("4", "REMOVE", "b", "u2")])
        self.assertEqual(self.ddb.transact_write_items.call_count, 1)
        # b: +1 -1 = 0 -> dropped; a: +2
        self.assertEqual(self.updates(self.ddb.transact_write_items.call_args), {"POST#a": "2"})

    def test_like_then_unlike_in_one_batch_makes_no_update(self):
        self.run_batch([rec("1", "INSERT", "a"), rec("2", "REMOVE", "a")])
        self.ddb.transact_write_items.assert_not_called()

    def test_200_likes_on_one_post_is_a_single_counter_update(self):
        self.run_batch([rec(str(i), "INSERT", "hot", f"user{i}") for i in range(200)])
        self.assertEqual(self.ddb.transact_write_items.call_count, 1)
        self.assertEqual(self.updates(self.ddb.transact_write_items.call_args), {"POST#hot": "200"})

    def test_marker_is_first_and_conditional_and_expires(self):
        self.run_batch([rec("1", "INSERT", "a")])
        marker = self.ddb.transact_write_items.call_args.kwargs["TransactItems"][0]["Put"]
        self.assertTrue(marker["Item"]["pk"]["S"].startswith("BATCH#"))
        self.assertEqual(marker["ConditionExpression"], "attribute_not_exists(pk)")
        self.assertIn("expiresAt", marker["Item"])

    def test_same_batch_gets_same_marker_so_a_redelivery_is_skipped(self):
        batch = [rec("1", "INSERT", "a"), rec("2", "INSERT", "b")]
        self.run_batch(batch)
        first = self.ddb.transact_write_items.call_args.kwargs["TransactItems"][0]["Put"]["Item"]["pk"]
        # Redelivery: the marker now exists, so DynamoDB cancels with it as the first reason.
        self.ddb.transact_write_items.side_effect = cancelled("ConditionalCheckFailed", "None", "None")
        self.run_batch(batch)  # must not raise
        second = self.ddb.transact_write_items.call_args.kwargs["TransactItems"][0]["Put"]["Item"]["pk"]
        self.assertEqual(first, second)

    def test_different_batches_get_different_markers(self):
        self.assertNotEqual(handler.batch_id([rec("1", "INSERT", "a"), rec("2", "INSERT", "a")]),
                            handler.batch_id([rec("1", "INSERT", "a"), rec("3", "INSERT", "a")]))

    def test_more_than_99_posts_split_into_chunks_with_distinct_markers(self):
        self.run_batch([rec(str(i), "INSERT", f"p{i:04d}") for i in range(250)])
        calls = self.ddb.transact_write_items.call_args_list
        self.assertEqual(len(calls), 3)
        sizes = [len(c.kwargs["TransactItems"]) for c in calls]
        self.assertEqual(sizes, [100, 100, 53])  # marker + 99 / marker + 99 / marker + 52
        markers = {c.kwargs["TransactItems"][0]["Put"]["Item"]["pk"]["S"] for c in calls}
        self.assertEqual(len(markers), 3)

    def test_conflict_is_retried_then_succeeds(self):
        self.ddb.transact_write_items.side_effect = [cancelled("None", "TransactionConflict"), None]
        self.run_batch([rec("1", "INSERT", "a")])
        self.assertEqual(self.ddb.transact_write_items.call_count, 2)

    def test_timeout_is_retried(self):
        self.ddb.transact_write_items.side_effect = [ReadTimeoutError(endpoint_url="x"), None]
        self.run_batch([rec("1", "INSERT", "a")])
        self.assertEqual(self.ddb.transact_write_items.call_count, 2)

    def test_retries_exhausted_raises_so_lambda_retries_the_batch(self):
        self.ddb.transact_write_items.side_effect = cancelled("None", "TransactionConflict")
        with self.assertRaises(RuntimeError):
            self.run_batch([rec("1", "INSERT", "a")])
        self.assertEqual(self.ddb.transact_write_items.call_count, handler.MAX_ATTEMPTS)

    def test_unexpected_error_raises_immediately(self):
        self.ddb.transact_write_items.side_effect = ClientError(
            {"Error": {"Code": "AccessDeniedException", "Message": ""}}, "TransactWriteItems")
        with self.assertRaises(ClientError):
            self.run_batch([rec("1", "INSERT", "a")])
        self.assertEqual(self.ddb.transact_write_items.call_count, 1)

    def test_modify_events_ignored(self):
        self.run_batch([rec("1", "MODIFY", "a")])
        self.ddb.transact_write_items.assert_not_called()

    def test_returns_nothing_so_partial_batch_responses_stay_off(self):
        self.assertEqual(self.run_batch([rec("1", "INSERT", "a")]), {})


if __name__ == "__main__":
    unittest.main()
