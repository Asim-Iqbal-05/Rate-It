import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ["TABLE_NAME"]
UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]
LIKE_COUNTERS_TABLE = os.environ["LIKE_COUNTERS_TABLE"]

MAX_TITLE_LENGTH = 100
MAX_DESCRIPTION_LENGTH = 1000
MAX_IMAGES = 5

table = dynamodb.Table(TABLE_NAME)
like_counters_table = dynamodb.Table(LIKE_COUNTERS_TABLE)


class ValidationError(Exception):
    def __init__(self, field, message):
        self.field = field
        self.message = message


def _user_id(event):
    return event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]


def _validate(body, user_id):
    title = body.get("title")
    description = body.get("description")
    rating = body.get("rating")
    image_keys = body.get("imageKeys")

    if not title or not isinstance(title, str) or len(title) > MAX_TITLE_LENGTH:
        raise ValidationError("title", f"required, max {MAX_TITLE_LENGTH} characters")

    if (
        not description
        or not isinstance(description, str)
        or len(description) > MAX_DESCRIPTION_LENGTH
    ):
        raise ValidationError(
            "description", f"required, max {MAX_DESCRIPTION_LENGTH} characters"
        )

    if isinstance(rating, bool) or not isinstance(rating, int) or not (1 <= rating <= 5):
        raise ValidationError("rating", "must be an integer 1-5")

    # Every key must belong to the caller - Media Service always issues
    # keys as "{userId}/{uuid}.jpg", so this also blocks claiming
    # someone else's upload.
    if (
        not isinstance(image_keys, list)
        or not (1 <= len(image_keys) <= MAX_IMAGES)
        or not all(
            isinstance(k, str) and k.startswith(f"{user_id}/") for k in image_keys
        )
    ):
        raise ValidationError(
            "imageKeys", f"must be 1-{MAX_IMAGES} images belonging to the authenticated user"
        )

    return title, description, rating, image_keys


def lambda_handler(event, context):
    user_id = _user_id(event)

    if event["requestContext"]["http"]["method"] == "DELETE":
        return _delete_experience(event, user_id)

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _error(400, "body", "malformed JSON")

    try:
        title, description, rating, image_keys = _validate(body, user_id)
    except ValidationError as e:
        return _error(400, e.field, e.message)

    experience_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat()
    # Time-bucketed GSI partition key (infra PRD §7.1) - "POST" alone
    # would put every write and every feed read on one logical
    # partition. Bucketing by month spreads that load, at the cost of
    # Feed Service needing to walk backward across bucket boundaries
    # to fill a page (see services/feed/app.py).
    feed_bucket = f"POST#{created_at[:7]}"

    table.put_item(
        Item={
            "experienceId": experience_id,
            "Type": feed_bucket,
            "CreatedAt": created_at,
            "userId": user_id,
            "title": title,
            "description": description,
            "rating": rating,
            "imageKeys": image_keys,
        }
    )

    # Claim each upload only after the write succeeds - if one tagging
    # call fails, that object just stays "pending" and expires via the
    # lifecycle rule; the others still get claimed independently.
    for image_key in image_keys:
        s3_client.put_object_tagging(
            Bucket=UPLOADS_BUCKET,
            Key=image_key,
            Tagging={"TagSet": [{"Key": "status", "Value": "claimed"}]},
        )

    return {
        "statusCode": 201,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"experienceId": experience_id, "createdAt": created_at}),
    }


def _log_error(event_name, experience_id, error):
    print(
        json.dumps(
            {
                "level": "error",
                "event": event_name,
                "experienceId": experience_id,
                "error": repr(error),
            }
        )
    )


def _delete_experience(event, user_id):
    experience_id = (event.get("pathParameters") or {}).get("experienceId", "")

    item = table.get_item(Key={"experienceId": experience_id}, ConsistentRead=True).get("Item")
    if not item:
        return _error(404, "experienceId", "post not found")
    if item.get("userId") != user_id:
        return _error(403, "experienceId", "not your post")

    # Deleting the item removes it from both GSIs, so it leaves the feed
    # immediately. The condition guards against it changing hands or
    # vanishing between the read above and this write.
    try:
        table.delete_item(
            Key={"experienceId": experience_id},
            ConditionExpression="userId = :sub",
            ExpressionAttributeValues={":sub": user_id},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _error(404, "experienceId", "post not found")
        raise

    # From here the post is gone, which is what the user asked for. A
    # failed cleanup only leaves harmless orphans, so log it and still
    # return success rather than telling the user it failed.
    try:
        _delete_images(item.get("imageKeys", []))
    except Exception as e:
        _log_error("delete_images_failed", experience_id, e)
    try:
        _delete_like_counter(experience_id)
    except Exception as e:
        _log_error("delete_like_counter_failed", experience_id, e)

    return {"statusCode": 204}


def _delete_images(image_keys):
    if not image_keys:
        return
    response = s3_client.delete_objects(
        Bucket=UPLOADS_BUCKET,
        Delete={"Objects": [{"Key": k} for k in image_keys], "Quiet": True},
    )
    if response.get("Errors"):
        raise RuntimeError(f"S3 failed to delete: {response['Errors']}")


def _delete_like_counter(experience_id):
    # Only the post's counter goes. Its like rows are deliberately left in
    # place: the Likes table is keyed by user, so it can't be queried by
    # post, and the rows are tiny and never read once the post is gone.
    # (If likes are still in the stream when the post is deleted, the
    # Counter Lambda can recreate this counter - also harmless, unread.)
    like_counters_table.delete_item(Key={"pk": f"POST#{experience_id}"})


def _error(status_code, field, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": {"field": field, "message": message}}),
    }
