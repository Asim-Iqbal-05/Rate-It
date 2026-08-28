import base64
import json
import os
from datetime import datetime, timezone
from typing import Optional

import boto3
from fastapi import FastAPI, Query

app = FastAPI()

dynamodb = boto3.resource("dynamodb")

TABLE_NAME = os.environ["TABLE_NAME"]
FEED_INDEX_NAME = os.environ["FEED_INDEX_NAME"]
# Public base URL images are served from - CloudFront's /images/*
# behavior in front of the (still-private) uploads bucket, via OAC
# (infra PRD Phase 6). Object keys are content-addressed UUIDs that
# never change once claimed, so these URLs are permanent - no expiry,
# unlike the presigned URLs this replaced.
PUBLIC_IMAGE_BASE_URL = os.environ["PUBLIC_IMAGE_BASE_URL"].rstrip("/")

PAGE_SIZE = 20

# Time-bucketed GSI partition keys (infra PRD §7.1/§12) - a single
# Query can only target one partition-key value, so a chronological
# feed that spans a month boundary has to walk backward bucket by
# bucket, stitching results together here. MAX_MONTH_BUCKETS_PER_REQUEST
# bounds how far back a single request will walk before giving up -
# 24 months is far more history than this project has, it just stops
# an old/sparse pagination request from issuing unbounded empty queries.
MAX_MONTH_BUCKETS_PER_REQUEST = 24

table = dynamodb.Table(TABLE_NAME)


def _encode_token(cursor: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(cursor).encode()).decode()


def _decode_token(token: str) -> Optional[dict]:
    try:
        cursor = json.loads(base64.urlsafe_b64decode(token.encode()).decode())
        if "bucket" not in cursor:
            raise ValueError("missing bucket")
        return cursor
    except Exception:
        # A malformed or pre-migration token (old format was just a
        # raw DynamoDB key, no "bucket") shouldn't 500 the request -
        # treat it the same as no token at all.
        return None


def _current_month_bucket() -> str:
    return f"POST#{datetime.now(timezone.utc).strftime('%Y-%m')}"


def _decrement_month(bucket: str) -> str:
    year, month = (int(p) for p in bucket.removeprefix("POST#").split("-"))
    year, month = (year - 1, 12) if month == 1 else (year, month - 1)
    return f"POST#{year:04d}-{month:02d}"


def _next_bucket(bucket: str, months_tried: int) -> Optional[str]:
    if months_tried >= MAX_MONTH_BUCKETS_PER_REQUEST:
        return None  # exhausted the walk-back bound - true end of the feed
    return _decrement_month(bucket)


def _image_urls(image_keys: list[str]) -> list[str]:
    return [f"{PUBLIC_IMAGE_BASE_URL}/images/{key}" for key in image_keys]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/feed")
def get_feed(pageToken: Optional[str] = Query(default=None)):
    cursor = (_decode_token(pageToken) if pageToken else None) or {
        "bucket": _current_month_bucket(),
        "key": None,
    }

    raw_items: list[dict] = []
    months_tried = 0

    while len(raw_items) < PAGE_SIZE:
        bucket = cursor["bucket"]
        query_kwargs = {
            "IndexName": FEED_INDEX_NAME,
            "KeyConditionExpression": "#t = :type",
            "ExpressionAttributeNames": {"#t": "Type"},
            "ExpressionAttributeValues": {":type": bucket},
            "ScanIndexForward": False,
            "Limit": PAGE_SIZE - len(raw_items),
        }
        if cursor.get("key"):
            query_kwargs["ExclusiveStartKey"] = cursor["key"]

        result = table.query(**query_kwargs)
        raw_items.extend(result.get("Items", []))

        if "LastEvaluatedKey" in result:
            # This bucket still has more - resume exactly here next
            # time, don't walk further back yet.
            cursor = {"bucket": bucket, "key": result["LastEvaluatedKey"]}
            break

        months_tried += 1
        next_bucket = _next_bucket(bucket, months_tried)
        if next_bucket is None:
            cursor = None  # exhausted every bucket - true end of feed
            break
        cursor = {"bucket": next_bucket, "key": None}

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
        for item in raw_items
    ]

    next_page_token = _encode_token(cursor) if cursor else None

    return {"items": items, "nextPageToken": next_page_token}
