"""Unit tests for Experience Service delete with AWS stubbed.

Run from the repo root:  python3 -m unittest discover -s tests/experience
"""
import os
import sys
import unittest
from unittest import mock

os.environ.update(AWS_DEFAULT_REGION="us-west-2", TABLE_NAME="experiences",
                  UPLOADS_BUCKET="bucket", LIKE_COUNTERS_TABLE="counters")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "services", "experience"))
import handler  # noqa: E402


def event(sub, post="p1"):
    return {"requestContext": {"http": {"method": "DELETE"}, "authorizer": {"jwt": {"claims": {"sub": sub}}}},
            "pathParameters": {"experienceId": post}}


class DeleteTests(unittest.TestCase):
    def setUp(self):
        self.table = mock.patch.object(handler, "table").start()
        self.counters = mock.patch.object(handler, "like_counters_table").start()
        self.s3 = mock.patch.object(handler, "s3_client").start()
        self.addCleanup(mock.patch.stopall)
        self.table.get_item.return_value = {"Item": {"experienceId": "p1", "userId": "me", "imageKeys": ["me/a.jpg"]}}
        self.s3.delete_objects.return_value = {}

    def delete(self, sub="me"):
        return handler.lambda_handler(event(sub), None)["statusCode"]

    def test_owner_delete_removes_post_images_and_only_the_counter(self):
        self.assertEqual(self.delete(), 204)
        self.table.delete_item.assert_called_once()
        self.s3.delete_objects.assert_called_once()
        self.counters.delete_item.assert_called_once_with(Key={"pk": "POST#p1"})
        # likes are deliberately not walked or deleted
        self.counters.query.assert_not_called()
        self.counters.batch_writer.assert_not_called()

    def test_someone_elses_post_is_403_and_changes_nothing(self):
        self.assertEqual(self.delete("intruder"), 403)
        self.table.delete_item.assert_not_called()
        self.s3.delete_objects.assert_not_called()
        self.counters.delete_item.assert_not_called()

    def test_missing_post_is_404(self):
        self.table.get_item.return_value = {}
        self.assertEqual(self.delete(), 404)

    def test_cleanup_failures_still_204(self):
        self.s3.delete_objects.side_effect = RuntimeError("s3 down")
        self.counters.delete_item.side_effect = RuntimeError("ddb down")
        self.assertEqual(self.delete(), 204)


if __name__ == "__main__":
    unittest.main()
