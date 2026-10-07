"""Unit tests for the Moderation Lambda, with every AWS client stubbed.

Run from the repo root:  python3 -m unittest discover -s tests/moderation
(needs boto3 importable).
"""
import io
import json
import os
import sys
import unittest
from unittest import mock

os.environ.update(
    AWS_DEFAULT_REGION="us-west-2",
    UPLOADS_BUCKET="bucket",
    EXPERIENCES_TABLE="experiences",
    QUEUE_URL="https://sqs.test/queue",
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "services", "moderation"))
import handler  # noqa: E402
from botocore.exceptions import ClientError, ReadTimeoutError  # noqa: E402

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 8
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 4


def client_error(code):
    return ClientError({"Error": {"Code": code, "Message": ""}}, "op")


def stream_record(experience_id="p1", keys=("u/a.jpg",), seq="1", name="INSERT"):
    return {
        "eventSource": "aws:dynamodb",
        "eventName": name,
        "dynamodb": {
            "SequenceNumber": seq,
            "NewImage": {
                "experienceId": {"S": experience_id},
                "imageKeys": {"L": [{"S": k} for k in keys]},
            },
        },
    }


class ModerationTests(unittest.TestCase):
    def setUp(self):
        patches = {n: mock.patch.object(handler, n) for n in ("s3", "rekognition", "sqs", "dynamodb")}
        self.m = {n: p.start() for n, p in patches.items()}
        for p in patches.values():
            self.addCleanup(p.stop)
        sleep = mock.patch.object(handler.time, "sleep")
        sleep.start()
        self.addCleanup(sleep.stop)
        self.set_bytes(JPEG)
        self.m["rekognition"].detect_moderation_labels.return_value = {"ModerationLabels": []}

    def set_bytes(self, data):
        # A fresh stream per call - a real response body is read once.
        self.m["s3"].get_object.side_effect = lambda **_: {"Body": io.BytesIO(data)}

    def run_stream(self, *records):
        return handler.lambda_handler({"Records": list(records)}, None)

    # --- decisions -------------------------------------------------------
    def test_clean_post_writes_nothing(self):
        self.assertEqual(self.run_stream(stream_record()), {"batchItemFailures": []})
        self.m["dynamodb"].update_item.assert_not_called()
        self.m["sqs"].send_message.assert_not_called()

    def test_png_accepted(self):
        self.set_bytes(PNG)
        self.run_stream(stream_record())
        self.m["rekognition"].detect_moderation_labels.assert_called_once()

    def test_text_file_renamed_jpg_is_taken_down_without_rekognition(self):
        self.set_bytes(b"hello world!")
        self.run_stream(stream_record())
        self.m["rekognition"].detect_moderation_labels.assert_not_called()
        kwargs = self.m["dynamodb"].update_item.call_args.kwargs
        self.assertEqual(kwargs["ExpressionAttributeValues"][":r"], {"S": "invalid_file_type"})
        self.assertEqual(kwargs["ExpressionAttributeNames"], {"#t": "Type"})
        self.assertTrue(kwargs["UpdateExpression"].startswith("REMOVE #t SET removed"))

    def test_flagged_parent_category_takes_post_down_and_stops_at_first_image(self):
        self.m["rekognition"].detect_moderation_labels.return_value = {
            "ModerationLabels": [
                {"Name": "Graphic Violence", "ParentName": "Violence"},
                {"Name": "Violence", "ParentName": ""},
            ]
        }
        self.run_stream(stream_record(keys=("u/a.jpg", "u/b.jpg")))
        self.assertEqual(self.m["rekognition"].detect_moderation_labels.call_count, 1)
        reason = self.m["dynamodb"].update_item.call_args.kwargs["ExpressionAttributeValues"][":r"]
        self.assertEqual(reason, {"S": "moderation:Violence"})

    def test_child_label_walks_up_to_blocked_root_even_if_root_not_returned(self):
        labels = [{"Name": "Explicit Nudity", "ParentName": "Explicit"}]
        self.assertEqual(handler._flagged_category(labels), "Explicit")

    def test_unblocked_category_passes(self):
        labels = [{"Name": "Alcohol Use", "ParentName": "Alcohol"}, {"Name": "Alcohol", "ParentName": ""}]
        self.assertIsNone(handler._flagged_category(labels))

    def test_takedown_of_already_deleted_post_is_success(self):
        self.set_bytes(b"nope nope no")
        self.m["dynamodb"].update_item.side_effect = client_error("ConditionalCheckFailedException")
        self.assertEqual(self.run_stream(stream_record()), {"batchItemFailures": []})

    def test_non_insert_ignored(self):
        self.run_stream(stream_record(name="MODIFY"))
        self.m["s3"].get_object.assert_not_called()

    # --- failure handling -----------------------------------------------
    def test_transient_error_retried_then_queued_and_handled(self):
        self.m["rekognition"].detect_moderation_labels.side_effect = client_error("ThrottlingException")
        result = self.run_stream(stream_record())
        self.assertEqual(self.m["rekognition"].detect_moderation_labels.call_count, 3)
        body = json.loads(self.m["sqs"].send_message.call_args.kwargs["MessageBody"])
        self.assertEqual((body["experienceId"], body["retryable"]), ("p1", True))
        self.assertEqual(result, {"batchItemFailures": []})  # treated as handled
        self.m["dynamodb"].update_item.assert_not_called()  # fails open

    def test_timeout_is_transient(self):
        self.m["rekognition"].detect_moderation_labels.side_effect = ReadTimeoutError(endpoint_url="x")
        self.run_stream(stream_record())
        self.assertEqual(self.m["rekognition"].detect_moderation_labels.call_count, 3)
        self.m["sqs"].send_message.assert_called_once()

    def test_transient_error_that_recovers_is_clean(self):
        self.m["rekognition"].detect_moderation_labels.side_effect = [
            client_error("ThrottlingException"),
            {"ModerationLabels": []},
        ]
        self.run_stream(stream_record())
        self.m["sqs"].send_message.assert_not_called()

    def test_terminal_error_queued_not_retryable_without_retries(self):
        self.m["rekognition"].detect_moderation_labels.side_effect = client_error("ImageTooLargeException")
        self.run_stream(stream_record())
        self.assertEqual(self.m["rekognition"].detect_moderation_labels.call_count, 1)
        self.assertFalse(json.loads(self.m["sqs"].send_message.call_args.kwargs["MessageBody"])["retryable"])

    def test_missing_object_is_terminal(self):
        self.m["s3"].get_object.side_effect = client_error("NoSuchKey")
        self.run_stream(stream_record())
        self.assertFalse(json.loads(self.m["sqs"].send_message.call_args.kwargs["MessageBody"])["retryable"])

    def test_access_denied_queued_as_retryable(self):
        self.m["rekognition"].detect_moderation_labels.side_effect = client_error("AccessDeniedException")
        self.run_stream(stream_record())
        self.assertEqual(self.m["rekognition"].detect_moderation_labels.call_count, 1)
        body = json.loads(self.m["sqs"].send_message.call_args.kwargs["MessageBody"])
        self.assertTrue(body["retryable"])
        self.assertIn("AccessDeniedException", body["reason"])

    def test_queue_send_failure_reports_batch_item_failure_and_later_records_still_run(self):
        self.m["rekognition"].detect_moderation_labels.side_effect = [
            client_error("AccessDeniedException"),
            {"ModerationLabels": []},
        ]
        self.m["sqs"].send_message.side_effect = client_error("AccessDenied")
        result = self.run_stream(stream_record("p1", seq="1"), stream_record("p2", seq="2"))
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "1"}]})
        self.assertEqual(self.m["rekognition"].detect_moderation_labels.call_count, 2)

    # --- redrive --------------------------------------------------------
    def sqs_record(self, body, message_id="m1"):
        return {"eventSource": "aws:sqs", "messageId": message_id, "body": json.dumps(body)}

    def post_item(self, **extra):
        return {"Item": {"experienceId": {"S": "p1"}, "imageKeys": {"L": [{"S": "u/a.jpg"}]}, **extra}}

    def test_redrive_moderates_and_succeeds(self):
        self.m["dynamodb"].get_item.return_value = self.post_item()
        result = handler.lambda_handler({"Records": [self.sqs_record({"experienceId": "p1"})]}, None)
        self.assertEqual(result, {"batchItemFailures": []})
        self.m["rekognition"].detect_moderation_labels.assert_called_once()

    def test_redrive_failure_returns_message_to_queue_without_requeueing(self):
        self.m["dynamodb"].get_item.return_value = self.post_item()
        self.m["rekognition"].detect_moderation_labels.side_effect = client_error("AccessDeniedException")
        result = handler.lambda_handler({"Records": [self.sqs_record({"experienceId": "p1"})]}, None)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "m1"}]})
        self.m["sqs"].send_message.assert_not_called()

    def test_redrive_skips_deleted_and_removed_posts(self):
        for item in ({}, self.post_item(removed={"BOOL": True})):
            self.m["dynamodb"].get_item.return_value = item
            result = handler.lambda_handler({"Records": [self.sqs_record({"experienceId": "p1"})]}, None)
            self.assertEqual(result, {"batchItemFailures": []})
        self.m["rekognition"].detect_moderation_labels.assert_not_called()

    def test_redrive_pointer_message_without_experience_id_is_dropped(self):
        pointer = {"requestContext": {}, "DDBStreamBatchInfo": {"shardId": "s"}}
        result = handler.lambda_handler({"Records": [self.sqs_record(pointer)]}, None)
        self.assertEqual(result, {"batchItemFailures": []})
        self.m["dynamodb"].get_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()
