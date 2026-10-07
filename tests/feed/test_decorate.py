"""Unit tests for Feed Service's like decoration with DynamoDB stubbed.

Run from the repo root:  python3 -m unittest discover -s tests/feed
(needs boto3 and fastapi importable).
"""
import os
import sys
import unittest
from unittest import mock

os.environ.update(AWS_DEFAULT_REGION="us-west-2", TABLE_NAME="experiences", FEED_INDEX_NAME="feed-idx",
                  AUTHOR_INDEX_NAME="author-idx", LIKES_TABLE_NAME="likes",
                  LIKE_COUNTERS_TABLE_NAME="counters", PUBLIC_IMAGE_BASE_URL="https://x.test")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "services", "feed"))
import app as feed  # noqa: E402


def post(i, **extra):
    return {"experienceId": i, "userId": "author", "title": "t", "description": "d", "rating": 4,
            "CreatedAt": "2026-10-07T00:00:00+00:00", "imageKeys": ["a/x.jpg"], **extra}


class DecorateTests(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(feed, "dynamodb")
        self.ddb = p.start()
        self.addCleanup(p.stop)
        s = mock.patch.object(feed.time, "sleep")
        s.start()
        self.addCleanup(s.stop)
        self.liked = []      # (experienceId) rows in Likes for the caller
        self.counters = {}   # experienceId -> stored count
        self.ddb.batch_get_item.side_effect = self.batch_get

    def batch_get(self, RequestItems):
        likes_req, counters_req = RequestItems["likes"], RequestItems["counters"]
        return {"Responses": {
            "likes": [k for k in likes_req["Keys"] if k["experienceId"] in self.liked],
            "counters": [{"pk": k["pk"], "likeCount": self.counters[k["pk"][5:]]}
                         for k in counters_req["Keys"] if k["pk"][5:] in self.counters],
        }}

    def decorate(self, posts, sub="me"):
        return {i["experienceId"]: i for i in feed.decorate(posts, sub)}

    def test_one_batch_get_spanning_both_tables_two_keys_per_post(self):
        self.decorate([post("a"), post("b")])
        self.assertEqual(self.ddb.batch_get_item.call_count, 1)
        req = self.ddb.batch_get_item.call_args.kwargs["RequestItems"]
        self.assertEqual(set(req), {"likes", "counters"})
        self.assertEqual(len(req["likes"]["Keys"]) + len(req["counters"]["Keys"]), 4)
        self.assertEqual(req["likes"]["Keys"][0], {"userId": "me", "experienceId": "a"})
        self.assertEqual(req["counters"]["Keys"][0], {"pk": "POST#a"})

    def test_likes_read_is_consistent_counters_are_not_required_to_be(self):
        self.decorate([post("a")])
        req = self.ddb.batch_get_item.call_args.kwargs["RequestItems"]
        self.assertTrue(req["likes"]["ConsistentRead"])

    def test_count_and_liked_state(self):
        self.liked, self.counters = ["a"], {"a": 7}
        out = self.decorate([post("a"), post("b")])
        self.assertEqual((out["a"]["likeCount"], out["a"]["likedByMe"]), (7, True))
        self.assertEqual((out["b"]["likeCount"], out["b"]["likedByMe"]), (0, False))

    def test_just_liked_but_counter_not_caught_up_shows_at_least_one(self):
        self.liked, self.counters = ["a"], {}          # like row exists, no counter yet
        self.assertEqual(self.decorate([post("a")])["a"]["likeCount"], 1)
        self.counters = {"a": 0}                         # counter exists but still zero
        self.assertEqual(self.decorate([post("a")])["a"]["likeCount"], 1)

    def test_never_negative(self):
        self.counters = {"a": -2}
        self.assertEqual(self.decorate([post("a")])["a"]["likeCount"], 0)

    def test_unprocessed_keys_are_retried(self):
        first = {"Responses": {"likes": [], "counters": []},
                 "UnprocessedKeys": {"counters": {"Keys": [{"pk": "POST#a"}]}}}
        second = {"Responses": {"likes": [], "counters": [{"pk": "POST#a", "likeCount": 3}]}}
        self.ddb.batch_get_item.side_effect = [first, second]
        self.assertEqual(self.decorate([post("a")])["a"]["likeCount"], 3)
        self.assertEqual(self.ddb.batch_get_item.call_count, 2)

    def test_removed_post_has_no_images(self):
        out = self.decorate([post("a", removed=True)])
        self.assertTrue(out["a"]["removed"])
        self.assertEqual(out["a"]["imageUrls"], [])

    def test_empty_page_makes_no_call(self):
        self.assertEqual(feed.decorate([], "me"), [])
        self.ddb.batch_get_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()
