import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ["TABLE_NAME"]
UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]

MAX_TITLE_LENGTH = 100
MAX_DESCRIPTION_LENGTH = 1000
MAX_IMAGES = 5

table = dynamodb.Table(TABLE_NAME)


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


def _error(status_code, field, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": {"field": field, "message": message}}),
    }
