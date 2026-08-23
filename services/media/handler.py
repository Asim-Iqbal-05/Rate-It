import json
import os
import uuid

import boto3

s3_client = boto3.client("s3")

UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]
UPLOAD_EXPIRES_SECONDS = 300  # ~5 min, per app PRD §4.1 - re-request if the form stalls
MAX_UPLOAD_BYTES = 10 * 1024 * 1024


def _user_id(event):
    return event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]


def lambda_handler(event, context):
    user_id = _user_id(event)
    image_key = f"{user_id}/{uuid.uuid4()}.jpg"

    # Tag applied at upload time; Experience Service flips it to "claimed"
    # after a successful DynamoDB write (infra PRD §7.2). Untagged/left-
    # pending objects expire via the bucket's lifecycle rule.
    tagging = "<Tagging><TagSet><Tag><Key>status</Key><Value>pending</Value></Tag></TagSet></Tagging>"

    presigned = s3_client.generate_presigned_post(
        Bucket=UPLOADS_BUCKET,
        Key=image_key,
        Fields={"tagging": tagging},
        Conditions=[
            # Soft content-type check only (client-asserted, spoofable -
            # documented residual risk in infra PRD §6/§8).
            ["starts-with", "$Content-Type", "image/"],
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
