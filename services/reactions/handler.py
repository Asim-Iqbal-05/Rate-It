import json
import os
import re
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.client("dynamodb")

REACTIONS_TABLE = os.environ["REACTIONS_TABLE"]
EXPERIENCES_TABLE = os.environ["EXPERIENCES_TABLE"]

# Sort-key value of the per-post count row. A Cognito sub is a UUID, so
# it can never collide with this (extension PRD §5.1).
COUNT_ROW = "COUNT"

MAX_ATTEMPTS = 3
BACKOFF_SECONDS = 0.1

_EXPERIENCE_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# Cancellation reasons that mean "try again", as opposed to a failed
# condition (which is an answer, not a failure).
_RETRYABLE_REASONS = {
    "TransactionConflict",
    "ThrottlingError",
    "ProvisionedThroughputExceeded",
}
_RETRYABLE_ERRORS = {
    "TransactionInProgressException",
    "ThrottlingException",
    "ProvisionedThroughputExceededException",
    "InternalServerError",
    "ServiceUnavailable",
}


def _user_id(event):
    return event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]


def _response(status_code):
    # Neither route has a request or response body (extension PRD §6.2).
    return {"statusCode": status_code}


def _reason_codes(error):
    return [r.get("Code") for r in error.response.get("CancellationReasons", [])]


def _like_items(experience_id, user_id):
    return [
        # Reads the post without writing to it, so a like never touches
        # the Experiences table or its GSIs (extension PRD §4, invariant 1).
        {
            "ConditionCheck": {
                "TableName": EXPERIENCES_TABLE,
                "Key": {"experienceId": {"S": experience_id}},
                "ConditionExpression": "attribute_exists(experienceId) AND attribute_not_exists(removed)",
            }
        },
        {
            "Put": {
                "TableName": REACTIONS_TABLE,
                "Item": {
                    "experienceId": {"S": experience_id},
                    "userId": {"S": user_id},
                    "createdAt": {"S": datetime.now(timezone.utc).isoformat()},
                },
                "ConditionExpression": "attribute_not_exists(experienceId)",
            }
        },
        {
            "Update": {
                "TableName": REACTIONS_TABLE,
                "Key": {"experienceId": {"S": experience_id}, "userId": {"S": COUNT_ROW}},
                "UpdateExpression": "ADD likeCount :one",
                "ExpressionAttributeValues": {":one": {"N": "1"}},
            }
        },
    ]


def _unlike_items(experience_id, user_id):
    return [
        {
            "Delete": {
                "TableName": REACTIONS_TABLE,
                "Key": {"experienceId": {"S": experience_id}, "userId": {"S": user_id}},
                "ConditionExpression": "attribute_exists(experienceId)",
            }
        },
        # Only reached when the like row really existed, so the count
        # can never go below zero.
        {
            "Update": {
                "TableName": REACTIONS_TABLE,
                "Key": {"experienceId": {"S": experience_id}, "userId": {"S": COUNT_ROW}},
                "UpdateExpression": "ADD likeCount :minusOne",
                "ExpressionAttributeValues": {":minusOne": {"N": "-1"}},
            }
        },
    ]


def _transact(items):
    """Run the transaction, retrying contention with backoff.

    Returns None on success, or the list of cancellation reason codes
    when a condition failed. Raises if retries are exhausted.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            dynamodb.transact_write_items(TransactItems=items)
            return None
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "TransactionCanceledException":
                reasons = _reason_codes(e)
                if "ConditionalCheckFailed" in reasons:
                    return reasons
                if not any(r in _RETRYABLE_REASONS for r in reasons):
                    raise
            elif code not in _RETRYABLE_ERRORS:
                raise
            if attempt == MAX_ATTEMPTS:
                raise
            time.sleep(BACKOFF_SECONDS * (2 ** (attempt - 1)))


def _like(experience_id, user_id):
    reasons = _transact(_like_items(experience_id, user_id))
    if reasons is None:
        return 204
    # Reasons come back in operation order.
    if reasons[0] == "ConditionalCheckFailed":
        return 404  # post missing or taken down - nothing was written
    if reasons[1] == "ConditionalCheckFailed":
        return 204  # already liked
    return 503


def _unlike(experience_id, user_id):
    reasons = _transact(_unlike_items(experience_id, user_id))
    # A failed condition just means the caller hadn't liked the post.
    return 204 if reasons is None or reasons[0] == "ConditionalCheckFailed" else 503


def lambda_handler(event, context):
    # Identity comes from the verified token only, never the request.
    user_id = _user_id(event)
    method = event["requestContext"]["http"]["method"]
    experience_id = (event.get("pathParameters") or {}).get("experienceId", "")

    if not _EXPERIENCE_ID.match(experience_id):
        return _response(404)

    try:
        if method == "PUT":
            status = _like(experience_id, user_id)
        elif method == "DELETE":
            status = _unlike(experience_id, user_id)
        else:
            return _response(405)
    except ClientError as e:
        print(json.dumps({
            "level": "error",
            "event": "reaction_failed",
            "experienceId": experience_id,
            "method": method,
            "error": e.response["Error"]["Code"],
        }))
        return _response(503)

    return _response(status)
