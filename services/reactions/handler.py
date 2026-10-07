import json
import os
import re
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.client("dynamodb")

# One row per like, keyed (userId, experienceId). That row is the source of
# truth; the count shown on a post is derived from it by the Counter Lambda
# (docs/rateit-likes-redesign-prd.md). This handler never touches a count.
LIKES_TABLE = os.environ["LIKES_TABLE"]
EXPERIENCES_TABLE = os.environ["EXPERIENCES_TABLE"]

_EXPERIENCE_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _user_id(event):
    return event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]


def _response(status_code):
    # Neither route has a request or response body.
    return {"statusCode": status_code}


def _is_condition_failure(error):
    return error.response["Error"]["Code"] == "ConditionalCheckFailedException"


def _post_is_live(experience_id):
    """A plain read of the post - never a write, so a like cannot cause one
    (invariant: nothing frequent writes to the Experiences table or its GSIs).
    Eventually consistent is fine."""
    item = dynamodb.get_item(
        TableName=EXPERIENCES_TABLE,
        Key={"experienceId": {"S": experience_id}},
        ProjectionExpression="experienceId, #r",
        ExpressionAttributeNames={"#r": "removed"},
    ).get("Item")
    return item is not None and "removed" not in item


def _like(experience_id, user_id):
    if not _post_is_live(experience_id):
        return 404
    # The condition is for more than idempotency: a write whose condition
    # fails changes nothing, so it produces no stream event and can never be
    # counted twice.
    # (A post deleted between the read above and this write leaves one orphan
    # like row. Accepted - nothing reads it.)
    try:
        dynamodb.put_item(
            TableName=LIKES_TABLE,
            Item={
                "userId": {"S": user_id},
                "experienceId": {"S": experience_id},
                "createdAt": {"S": datetime.now(timezone.utc).isoformat()},
            },
            ConditionExpression="attribute_not_exists(userId)",
        )
    except ClientError as e:
        if not _is_condition_failure(e):
            raise
        # already liked
    return 204


def _unlike(experience_id, user_id):
    try:
        dynamodb.delete_item(
            TableName=LIKES_TABLE,
            Key={"userId": {"S": user_id}, "experienceId": {"S": experience_id}},
            ConditionExpression="attribute_exists(userId)",
        )
    except ClientError as e:
        if not _is_condition_failure(e):
            raise
        # was not liked
    return 204


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
