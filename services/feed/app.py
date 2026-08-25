import base64
import json
import os
from typing import Optional

import boto3
from fastapi import FastAPI, Query

app = FastAPI()

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ["TABLE_NAME"]
FEED_INDEX_NAME = os.environ["FEED_INDEX_NAME"]
UPLOADS_BUCKET = os.environ["UPLOADS_BUCKET"]

PAGE_SIZE = 20
# Uploads bucket is private (no CloudFront/OAC yet - that's infra PRD
# Phase 6), so images are served via short-lived presigned GET URLs in
# the meantime. Once CloudFront is wired up this should switch to
# stable CDN URLs instead - documented here so it isn't forgotten.
IMAGE_URL_EXPIRES_SECONDS = 3600

table = dynamodb.Table(TABLE_NAME)


def _encode_token(key: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(key).encode()).decode()


def _decode_token(token: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(token.encode()).decode())


def _image_urls(image_keys: list[str]) -> list[str]:
    return [
        s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": UPLOADS_BUCKET, "Key": key},
            ExpiresIn=IMAGE_URL_EXPIRES_SECONDS,
        )
        for key in image_keys
    ]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/feed")
def get_feed(pageToken: Optional[str] = Query(default=None)):
    query_kwargs = {
        "IndexName": FEED_INDEX_NAME,
        "KeyConditionExpression": "#t = :type",
        "ExpressionAttributeNames": {"#t": "Type"},
        "ExpressionAttributeValues": {":type": "POST"},
        # Newest first - app PRD §4.3.
        "ScanIndexForward": False,
        "Limit": PAGE_SIZE,
    }
    if pageToken:
        query_kwargs["ExclusiveStartKey"] = _decode_token(pageToken)

    result = table.query(**query_kwargs)

    items = [
        {
            "experienceId": item["experienceId"],
            "userId": item["userId"],
            "title": item["title"],
            "description": item["description"],
            "rating": int(item["rating"]),
            "imageUrls": _image_urls(item.get("imageKeys", [])),
            "createdAt": item["CreatedAt"],
        }
        for item in result.get("Items", [])
    ]

    next_page_token = (
        _encode_token(result["LastEvaluatedKey"]) if "LastEvaluatedKey" in result else None
    )

    return {"items": items, "nextPageToken": next_page_token}
