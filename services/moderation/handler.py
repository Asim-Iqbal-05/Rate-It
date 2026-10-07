import json
import os
import time
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeDeserializer
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# Retries are done explicitly below (so the attempt count and backoff
# are ours, not boto's); short timeouts keep three attempts per call
# inside the function's 60s timeout.
_client_config = Config(
    retries={"max_attempts": 1}, connect_timeout=5, read_timeout=10
)
s3 = boto3.client("s3", config=_client_config)
rekognition = boto3.client("rekognition", config=_client_config)
sqs = boto3.client("sqs", config=_client_config)
dynamodb = boto3.client("dynamodb", config=_client_config)

UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]
EXPERIENCES_TABLE = os.environ["EXPERIENCES_TABLE"]
QUEUE_URL = os.environ["QUEUE_URL"]
MIN_CONFIDENCE = float(os.environ.get("MIN_CONFIDENCE", "80"))
# Top-level (L1) Rekognition moderation categories that take a post down.
# Names checked against the published taxonomy CSV.
BLOCKED_CATEGORIES = {
    c.strip()
    for c in os.environ.get(
        "BLOCKED_CATEGORIES",
        "Explicit,Violence,Visually Disturbing,Hate Symbols",
    ).split(",")
    if c.strip()
}

MAX_ATTEMPTS = 3
BACKOFF_SECONDS = 0.5

JPEG_MAGIC = b"\xff\xd8\xff"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

_deserializer = TypeDeserializer()

# Errors worth retrying in place - the same call may well succeed.
_TRANSIENT_CODES = {
    "ThrottlingException",
    "ThrottledException",
    "Throttling",
    "ProvisionedThroughputExceededException",
    "RequestLimitExceeded",
    "InternalServerError",
    "InternalError",
    "ServiceUnavailable",
    "SlowDown",
    "RequestTimeout",
}
# Errors that can never succeed for this particular image.
_TERMINAL_CODES = {
    "InvalidImageFormatException",
    "ImageTooLargeException",
    "InvalidS3ObjectException",
    "NoSuchKey",
    "404",
}


class ModerationFailure(Exception):
    """The post could not be moderated right now. Carries what goes into
    the queue message."""

    def __init__(self, reason, retryable):
        super().__init__(reason)
        self.reason = reason
        self.retryable = retryable


def _log(**fields):
    print(json.dumps(fields, default=str))


def _call(fn, **kwargs):
    """Call an AWS API, retrying transient errors with backoff. Anything
    still failing becomes a ModerationFailure."""
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return fn(**kwargs)
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code in _TERMINAL_CODES:
                raise ModerationFailure(f"unreadable_image:{code}", retryable=False)
            if code not in _TRANSIENT_CODES:
                # e.g. AccessDenied - retrying here won't help, but it
                # may after someone fixes it, so it goes to the queue as
                # retryable for redrive.
                raise ModerationFailure(f"aws_error:{code}", retryable=True)
            failure = ModerationFailure(f"aws_unavailable:{code}", retryable=True)
        except BotoCoreError as e:  # timeouts, connection errors
            failure = ModerationFailure(f"aws_unavailable:{type(e).__name__}", retryable=True)
        if attempt == MAX_ATTEMPTS:
            raise failure
        time.sleep(BACKOFF_SECONDS * (2 ** (attempt - 1)))


def _is_supported_image(header):
    return header.startswith(JPEG_MAGIC) or header.startswith(PNG_MAGIC)


def _flagged_category(labels):
    """Return the blocked top-level category a label set falls under, or
    None. Labels carry their parent's name, so walk up to the root."""
    parents = {label["Name"]: label.get("ParentName", "") for label in labels}
    for label in labels:
        name = label["Name"]
        seen = set()
        while name and name not in seen:
            if name in BLOCKED_CATEGORIES:
                return name
            seen.add(name)
            name = parents.get(name, "")
    return None


def _check_image(key):
    """Return a takedown reason for this image, or None if it's fine."""
    obj = _call(
        s3.get_object, Bucket=UPLOADS_BUCKET, Key=key, Range="bytes=0-11"
    )
    if not _is_supported_image(obj["Body"].read()):
        return "invalid_file_type"

    result = _call(
        rekognition.detect_moderation_labels,
        Image={"S3Object": {"Bucket": UPLOADS_BUCKET, "Name": key}},
        MinConfidence=MIN_CONFIDENCE,
    )
    category = _flagged_category(result.get("ModerationLabels", []))
    return f"moderation:{category}" if category else None


def _take_down(experience_id, reason):
    try:
        # Removing Type drops the post from the feed GSI; it stays in the
        # userId GSI so its author still sees it (extension PRD §5.2).
        dynamodb.update_item(
            TableName=EXPERIENCES_TABLE,
            Key={"experienceId": {"S": experience_id}},
            UpdateExpression="REMOVE #t SET removed = :t, removedReason = :r, removedAt = :n",
            ConditionExpression="attribute_exists(experienceId)",
            ExpressionAttributeNames={"#t": "Type"},
            ExpressionAttributeValues={
                ":t": {"BOOL": True},
                ":r": {"S": reason},
                ":n": {"S": datetime.now(timezone.utc).isoformat()},
            },
        )
    except ClientError as e:
        # The author deleted the post first - nothing left to take down.
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise


def moderate_post(experience_id, image_keys):
    """Check every image; take the post down at the first bad one.

    Returns ("clean" | "removed", reason). Raises ModerationFailure when
    the post couldn't be checked."""
    for key in image_keys:
        reason = _check_image(key)
        if reason:
            _take_down(experience_id, reason)
            return "removed", reason
    return "clean", None


def _queue_failure(experience_id, failure):
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(
            {
                "experienceId": experience_id,
                "reason": failure.reason,
                "retryable": failure.retryable,
                "failedAt": datetime.now(timezone.utc).isoformat(),
            }
        ),
    )


def _run(experience_id, image_keys):
    """Moderate one post and log the decision. Raises ModerationFailure."""
    started = time.monotonic()
    outcome, reason = moderate_post(experience_id, image_keys)
    _log(
        event="moderation_decision",
        experienceId=experience_id,
        outcome=outcome,
        reason=reason,
        durationMs=round((time.monotonic() - started) * 1000),
    )


def _handle_stream(records):
    failures = []
    for record in records:
        sequence = record["dynamodb"]["SequenceNumber"]
        experience_id = None
        started = time.monotonic()
        try:
            if record.get("eventName") != "INSERT":
                continue  # the mapping filters these out; belt and braces
            image = {
                k: _deserializer.deserialize(v)
                for k, v in record["dynamodb"]["NewImage"].items()
            }
            experience_id = image["experienceId"]
            try:
                _run(experience_id, image.get("imageKeys", []))
            except ModerationFailure as failure:
                # Fail open: the post stays visible, and the queue holds
                # it until someone works it. Treating the record as
                # handled is what stops one bad post blocking the shard.
                _queue_failure(experience_id, failure)
                _log(
                    event="moderation_decision",
                    experienceId=experience_id,
                    outcome="queued",
                    reason=failure.reason,
                    durationMs=round((time.monotonic() - started) * 1000),
                )
        except Exception as e:  # can't even queue it - let Lambda retry
            _log(
                level="error",
                event="moderation_record_failed",
                experienceId=experience_id,
                error=repr(e),
            )
            failures.append({"itemIdentifier": sequence})
    return {"batchItemFailures": failures}


def _handle_redrive(records):
    failures = []
    for record in records:
        message_id = record["messageId"]
        try:
            body = json.loads(record["body"])
            experience_id = body.get("experienceId") if isinstance(body, dict) else None
            if not experience_id:
                # Lambda's own on-failure pointer (stream shard metadata,
                # no post data) can't be reprocessed. The full body is
                # logged for manual handling, then the message is dropped.
                _log(level="error", event="redrive_unprocessable_message", body=body)
                continue

            item = dynamodb.get_item(
                TableName=EXPERIENCES_TABLE,
                Key={"experienceId": {"S": experience_id}},
                ConsistentRead=True,
            ).get("Item")
            if not item or "removed" in item:
                continue  # deleted or already taken down - nothing to do

            image_keys = _deserializer.deserialize({"M": item}).get("imageKeys", [])
            _run(experience_id, image_keys)
        except Exception as e:
            _log(
                level="error",
                event="redrive_record_failed",
                messageId=message_id,
                error=repr(e),
            )
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}


def lambda_handler(event, context):
    records = event.get("Records", [])
    if not records:
        return {"batchItemFailures": []}
    source = records[0].get("eventSource")
    if source == "aws:dynamodb":
        return _handle_stream(records)
    if source == "aws:sqs":
        return _handle_redrive(records)
    _log(level="error", event="unknown_event_source", source=source)
    return {"batchItemFailures": []}
