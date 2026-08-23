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
    image_key = body.get("imageKey")

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

    # imageKey must belong to the caller - Media Service always issues
    # keys as "{userId}/{uuid}.jpg", so this also blocks claiming
    # someone else's upload.
    if not image_key or not isinstance(image_key, str) or not image_key.startswith(f"{user_id}/"):
        raise ValidationError("imageKey", "missing or does not belong to the authenticated user")

    return title, description, rating, image_key


def lambda_handler(event, context):
    user_id = _user_id(event)

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _error(400, "body", "malformed JSON")

    try:
        title, description, rating, image_key = _validate(body, user_id)
    except ValidationError as e:
        return _error(400, e.field, e.message)

    experience_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat()

    table.put_item(
        Item={
            "experienceId": experience_id,
            "Type": "POST",
            "CreatedAt": created_at,
            "userId": user_id,
            "title": title,
            "description": description,
            "rating": rating,
            "imageKey": image_key,
        }
    )

    # Claim the upload only after the write succeeds - if this call fails,
    # the object just stays "pending" and expires via the lifecycle rule.
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
