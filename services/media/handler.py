import json
import os
import uuid

import boto3

s3_client = boto3.client("s3")

UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]
UPLOAD_EXPIRES_SECONDS = 300  # ~5 min, per app PRD §4.1 - re-request if the form stalls
# Well under Rekognition's 15MB limit for images referenced from S3, so
# anything that uploads can also be moderated (extension PRD §7.5).
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

# Rekognition only reads JPEG and PNG, so nothing else is accepted.
# Content type -> key extension. The frontend mirrors this list.
ALLOWED_CONTENT_TYPES = {"image/jpeg": "jpg", "image/png": "png"}
DEFAULT_CONTENT_TYPE = "image/jpeg"


def _user_id(event):
    return event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]


def lambda_handler(event, context):
    user_id = _user_id(event)

    params = event.get("queryStringParameters") or {}
    content_type = params.get("contentType", DEFAULT_CONTENT_TYPE)
    if content_type not in ALLOWED_CONTENT_TYPES:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "error": {
                        "field": "contentType",
                        "message": "must be one of: " + ", ".join(ALLOWED_CONTENT_TYPES),
                    }
                }
            ),
        }

    image_key = f"{user_id}/{uuid.uuid4()}.{ALLOWED_CONTENT_TYPES[content_type]}"

    # Tag applied at upload time; Experience Service flips it to "claimed"
    # after a successful DynamoDB write (infra PRD §7.2). Untagged/left-
    # pending objects expire via the bucket's lifecycle rule.
    tagging = "<Tagging><TagSet><Tag><Key>status</Key><Value>pending</Value></Tag></TagSet></Tagging>"

    presigned = s3_client.generate_presigned_post(
        Bucket=UPLOADS_BUCKET,
        Key=image_key,
        # Content-Type is signed into the form, so the client can't send
        # a different one. It is still client-asserted about the bytes -
        # the Moderation Service's magic-byte check is what catches a
        # mislabelled file.
        Fields={"tagging": tagging, "Content-Type": content_type},
        Conditions=[
            ["eq", "$Content-Type", content_type],
            ["content-length-range", 1, MAX_UPLOAD_BYTES],
            {"tagging": tagging},
        ],
        ExpiresIn=UPLOAD_EXPIRES_SECONDS,
    )

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "url": presigned["url"],
                "fields": presigned["fields"],
                "imageKey": image_key,
            }
        ),
    }
