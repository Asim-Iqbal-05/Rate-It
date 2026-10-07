import base64
import json
import os
import time
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional

import boto3
from fastapi import FastAPI, Header, HTTPException, Query

app = FastAPI()

dynamodb = boto3.resource("dynamodb")

TABLE_NAME = os.environ["TABLE_NAME"]
FEED_INDEX_NAME = os.environ["FEED_INDEX_NAME"]
AUTHOR_INDEX_NAME = os.environ["AUTHOR_INDEX_NAME"]
LIKES_TABLE_NAME = os.environ["LIKES_TABLE_NAME"]
LIKE_COUNTERS_TABLE_NAME = os.environ["LIKE_COUNTERS_TABLE_NAME"]
# Public base URL images are served from - CloudFront's /images/*
# behavior in front of the (still-private) uploads bucket, via OAC
# (infra PRD Phase 6). Object keys are content-addressed UUIDs that
# never change once claimed, so these URLs are permanent - no expiry,
# unlike the presigned URLs this replaced.
PUBLIC_IMAGE_BASE_URL = os.environ["PUBLIC_IMAGE_BASE_URL"].rstrip("/")

# Each post needs two keys (the caller's like row + the post's counter)
# and BatchGetItem accepts at most 100 keys, so PAGE_SIZE must stay at
# or below 50 (extension PRD §7.6).
PAGE_SIZE = 20
assert PAGE_SIZE * 2 <= 100

# Counter rows in the LikeCounters table are keyed "POST#<experienceId>".
COUNTER_KEY_PREFIX = "POST#"
BATCH_GET_MAX_ATTEMPTS = 5

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


def _decode_author_token(token: str) -> Optional[dict]:
    # "My posts" tokens are just a DynamoDB key, tagged so a global-feed
    # token (or vice versa) is never mistaken for one - a mismatched
    # token is treated like no token at all.
    try:
        cursor = json.loads(base64.urlsafe_b64decode(token.encode()).decode())
        if cursor.get("mode") != "me" or "key" not in cursor:
            raise ValueError("not an author token")
        return cursor
    except Exception:
        return None


def _fetch_global_page(page_token: Optional[str]):
    cursor = (_decode_token(page_token) if page_token else None) or {
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

    return raw_items, (_encode_token(cursor) if cursor else None)


def _fetch_author_page(author_sub: str, page_token: Optional[str]):
    cursor = _decode_author_token(page_token) if page_token else None

    query_kwargs = {
        "IndexName": AUTHOR_INDEX_NAME,
        "KeyConditionExpression": "userId = :u",
        "ExpressionAttributeValues": {":u": author_sub},
        "ScanIndexForward": False,
        "Limit": PAGE_SIZE,
    }
    if cursor and cursor.get("key"):
        query_kwargs["ExclusiveStartKey"] = cursor["key"]

    result = table.query(**query_kwargs)
    last_key = result.get("LastEvaluatedKey")
    next_token = _encode_token({"mode": "me", "key": last_key}) if last_key else None
    return result.get("Items", []), next_token


def fetch_page(author_sub: Optional[str], page_token: Optional[str]):
    """Step 1: the post list. Identical for every caller (the author view
    is keyed on the caller, but still carries no per-caller like data) -
    kept separate from decorate() so a shared cache can wrap just this
    step later without a rewrite (extension PRD §7.6)."""
    if author_sub is not None:
        return _fetch_author_page(author_sub, page_token)
    return _fetch_global_page(page_token)


def _batch_get_likes(likes_keys: list[dict], counter_keys: list[dict]) -> dict:
    """One BatchGetItem spanning both tables, retrying UnprocessedKeys."""
    found: dict[str, list[dict]] = {LIKES_TABLE_NAME: [], LIKE_COUNTERS_TABLE_NAME: []}
    pending = {
        # Consistent, so a like the caller just made shows after a refresh.
        LIKES_TABLE_NAME: {"Keys": likes_keys, "ConsistentRead": True},
        LIKE_COUNTERS_TABLE_NAME: {"Keys": counter_keys},
    }
    for attempt in range(BATCH_GET_MAX_ATTEMPTS):
        response = dynamodb.batch_get_item(RequestItems=pending)
        for table_name, rows in response["Responses"].items():
            found[table_name].extend(rows)
        pending = response.get("UnprocessedKeys") or {}
        if not pending:
            return found
        time.sleep(0.05 * (2**attempt))
    raise RuntimeError("Likes BatchGetItem still had unprocessed keys after retries")


def decorate(raw_items: list[dict], caller_sub: str) -> list[dict]:
    """Step 2: per-post like data for this caller."""
    liked: set[str] = set()
    stored_counts: dict[str, int] = {}
    if raw_items:
        found = _batch_get_likes(
            [{"userId": caller_sub, "experienceId": i["experienceId"]} for i in raw_items],
            [{"pk": f"{COUNTER_KEY_PREFIX}{i['experienceId']}"} for i in raw_items],
        )
        liked = {row["experienceId"] for row in found[LIKES_TABLE_NAME]}
        stored_counts = {
            row["pk"][len(COUNTER_KEY_PREFIX):]: int(row["likeCount"])
            for row in found[LIKE_COUNTERS_TABLE_NAME]
        }

    items = []
    for item in raw_items:
        liked_by_me = item["experienceId"] in liked
        # The counter is derived from the like rows and lags them by a
        # couple of seconds. max() covers that window for the liker: the
        # like row exists but the counter hasn't caught up, and without it
        # they could briefly see a filled heart beside a count of zero.
        like_count = max(stored_counts.get(item["experienceId"], 0), 1 if liked_by_me else 0, 0)
        removed = bool(item.get("removed", False))
        items.append(
            {
                "experienceId": item["experienceId"],
                "userId": item["userId"],
                "title": item["title"],
                "description": item["description"],
                "rating": int(item["rating"]),
                # A taken-down post (only ever visible to its author) shows
                # no images.
                "imageUrls": [] if removed else _image_urls(item.get("imageKeys", [])),
                "createdAt": item["CreatedAt"],
                "likeCount": like_count,
                "likedByMe": liked_by_me,
                "removed": removed,
            }
        )
    return items


@app.get("/api/feed")
def get_feed(
    pageToken: Optional[str] = Query(default=None),
    author: Optional[str] = Query(default=None),
    # Set by API Gateway from the verified JWT, overwriting whatever the
    # client sent (infra/env/main.tf) - never trust it from anywhere
    # else; the ALB is only reachable through the VPC Link.
    x_user_sub: Optional[str] = Header(default=None),
):
    if author is not None and author != "me":
        raise HTTPException(status_code=400, detail="author must be 'me'")
    if not x_user_sub:
        raise HTTPException(status_code=401, detail="missing caller identity")

    raw_items, next_page_token = fetch_page(
        x_user_sub if author == "me" else None, pageToken
    )
    return {"items": decorate(raw_items, x_user_sub), "nextPageToken": next_page_token}
