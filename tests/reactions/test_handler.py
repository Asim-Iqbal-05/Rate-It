"""Unit tests for the Reactions Lambda with DynamoDB stubbed.

Run from the repo root:  python3 -m unittest discover -s tests/reactions
"""
import os
import sys
import unittest
from unittest import mock

os.environ.update(AWS_DEFAULT_REGION="us-west-2", LIKES_TABLE="likes", EXPERIENCES_TABLE="experiences")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "services", "reactions"))
import handler  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402

POST = "11111111-2222-3333-4444-555555555555"


def client_error(code):
    return ClientError({"Error": {"Code": code, "Message": ""}}, "op")


def event(method, sub="user-1", post=POST):
    return {"requestContext": {"http": {"method": method}, "authorizer": {"jwt": {"claims": {"sub": sub}}}},
            "pathParameters": {"experienceId": post}}


class ReactionsTests(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(handler, "dynamodb")
        self.ddb = p.start()
        self.addCleanup(p.stop)
        self.ddb.get_item.return_value = {"Item": {"experienceId": {"S": POST}}}

    def call(self, method, **kw):
        return handler.lambda_handler(event(method, **kw), None)["statusCode"]

    def test_like_is_one_conditional_write_to_likes_and_nothing_else(self):
        self.assertEqual(self.call("PUT"), 204)
        self.ddb.put_item.assert_called_once()
        kw = self.ddb.put_item.call_args.kwargs
        self.assertEqual(kw["TableName"], "likes")
        self.assertEqual(kw["Item"]["userId"], {"S": "user-1"})
        self.assertEqual(kw["Item"]["experienceId"], {"S": POST})
        self.assertIn("createdAt", kw["Item"])
        self.assertEqual(kw["ConditionExpression"], "attribute_not_exists(userId)")
        # no transaction, no counter, no write of any kind to Experiences
        self.ddb.transact_write_items.assert_not_called()
        self.ddb.update_item.assert_not_called()
        self.assertEqual(self.ddb.get_item.call_args.kwargs["TableName"], "experiences")

    def test_already_liked_is_204(self):
        self.ddb.put_item.side_effect = client_error("ConditionalCheckFailedException")
        self.assertEqual(self.call("PUT"), 204)

    def test_missing_post_is_404_and_writes_nothing(self):
        self.ddb.get_item.return_value = {}
        self.assertEqual(self.call("PUT"), 404)
        self.ddb.put_item.assert_not_called()

    def test_removed_post_is_404_and_writes_nothing(self):
        self.ddb.get_item.return_value = {"Item": {"experienceId": {"S": POST}, "removed": {"BOOL": True}}}
        self.assertEqual(self.call("PUT"), 404)
        self.ddb.put_item.assert_not_called()

    def test_unlike_is_one_conditional_delete(self):
        self.assertEqual(self.call("DELETE"), 204)
        kw = self.ddb.delete_item.call_args.kwargs
        self.assertEqual(kw["TableName"], "likes")
        self.assertEqual(kw["Key"], {"userId": {"S": "user-1"}, "experienceId": {"S": POST}})
        self.assertEqual(kw["ConditionExpression"], "attribute_exists(userId)")
        self.ddb.get_item.assert_not_called()  # unliking doesn't need the post to exist

    def test_unlike_when_not_liked_is_204(self):
        self.ddb.delete_item.side_effect = client_error("ConditionalCheckFailedException")
        self.assertEqual(self.call("DELETE"), 204)

    def test_other_errors_are_503(self):
        self.ddb.put_item.side_effect = client_error("ProvisionedThroughputExceededException")
        self.assertEqual(self.call("PUT"), 503)

    def test_bad_post_id_is_404_without_touching_dynamodb(self):
        self.assertEqual(self.call("PUT", post="not-a-uuid"), 404)
        self.ddb.get_item.assert_not_called()
        self.ddb.put_item.assert_not_called()

    def test_identity_comes_from_the_token_only(self):
        self.call("PUT", sub="token-sub")
        self.assertEqual(self.ddb.put_item.call_args.kwargs["Item"]["userId"], {"S": "token-sub"})


if __name__ == "__main__":
    unittest.main()
