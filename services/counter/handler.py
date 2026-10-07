"""Counter Lambda: turns Likes-table stream events into LikeCounters updates.

The like row is the source of truth; the count is derived from it and may
lag by a couple of seconds (docs/rateit-likes-redesign-prd.md section 5.2).

Idempotency: Lambda can deliver the same batch twice after a failure. Each
batch gets a deterministic ID and every chunk of it writes a marker item in
the SAME transaction as its count updates, so a repeated batch finds the
marker and is applied zero additional times. That only works if a retried
batch is identical to the original, which is why the event source mapping
has batch bisecting and partial-batch responses switched OFF - do not turn
them on.
"""
import hashlib
import json
import os
import random
import time

import boto3
from botocore.exceptions import BotoCoreError, ClientError

dynamodb = boto3.client("dynamodb")

COUNTERS_TABLE = os.environ["COUNTERS_TABLE"]

# TransactWriteItems allows 100 operations: one marker + up to 99 counters.
MAX_POSTS_PER_CHUNK = 99
MARKER_TTL_SECONDS = 48 * 3600
MAX_ATTEMPTS = 5
BACKOFF_SECONDS = 0.1

_RETRYABLE_REASONS = {"TransactionConflict", "ThrottlingError", "ProvisionedThroughputExceeded"}
_RETRYABLE_ERRORS = {
    "TransactionInProgressException",
    "ThrottlingException",
    "ProvisionedThroughputExceededException",
    "InternalServerError",
    "ServiceUnavailable",
}


def _log(**fields):
    print(json.dumps(fields, default=str))


def net_changes(records):
    """Sum +1 per INSERT and -1 per REMOVE for each post; drop net zeros."""
    totals = {}
    for record in records:
        event_name = record.get("eventName")
        if event_name not in ("INSERT", "REMOVE"):
            continue
        experience_id = record["dynamodb"]["Keys"]["experienceId"]["S"]
        totals[experience_id] = totals.get(experience_id, 0) + (1 if event_name == "INSERT" else -1)
    return {post: delta for post, delta in totals.items() if delta != 0}


def batch_id(records):
    """Same batch in -> same ID out, so a retried batch hits its markers."""
    identity = f"{records[0]['eventID']}|{records[-1]['eventID']}|{len(records)}"
    return hashlib.sha256(identity.encode()).hexdigest()[:32]


def _chunk_items(bid, index, chunk):
    expires_at = int(time.time()) + MARKER_TTL_SECONDS
    # The marker goes first: if it already exists this chunk was applied by
    # an earlier attempt and the whole transaction is cancelled with the
    # first reason ConditionalCheckFailed.
    items = [
        {
            "Put": {
                "TableName": COUNTERS_TABLE,
                "Item": {
                    "pk": {"S": f"BATCH#{bid}#{index}"},
                    "expiresAt": {"N": str(expires_at)},
                },
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        }
    ]
    for post, delta in chunk:
        items.append(
            {
                "Update": {
                    "TableName": COUNTERS_TABLE,
                    "Key": {"pk": {"S": f"POST#{post}"}},
                    "UpdateExpression": "ADD likeCount :d",
                    "ExpressionAttributeValues": {":d": {"N": str(delta)}},
                }
            }
        )
    return items


def _apply_chunk(bid, index, chunk):
    """Returns "applied" or "skipped" (already applied by an earlier attempt)."""
    items = _chunk_items(bid, index, chunk)
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            dynamodb.transact_write_items(TransactItems=items)
            return "applied"
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "TransactionCanceledException":
                reasons = [r.get("Code") for r in e.response.get("CancellationReasons", [])]
                if reasons and reasons[0] == "ConditionalCheckFailed":
                    return "skipped"
                if not any(r in _RETRYABLE_REASONS for r in reasons):
                    raise
            elif code not in _RETRYABLE_ERRORS:
                raise
        except BotoCoreError:
            # A timeout may mean the transaction committed. Retrying is safe:
            # if it did, the marker is there and the retry is skipped.
            pass
        if attempt == MAX_ATTEMPTS:
            raise RuntimeError(f"chunk {index} of batch {bid} still failing after {MAX_ATTEMPTS} attempts")
        time.sleep(BACKOFF_SECONDS * (2 ** (attempt - 1)) * (0.5 + random.random()))


def lambda_handler(event, context):
    records = event.get("Records", [])
    if not records:
        return {}

    changes = net_changes(records)
    if not changes:
        _log(event="counter_batch", records=len(records), posts=0, applied=0, skipped=0)
        return {}

    bid = batch_id(records)
    posts = sorted(changes)
    applied = skipped = 0
    for index, start in enumerate(range(0, len(posts), MAX_POSTS_PER_CHUNK)):
        chunk = [(post, changes[post]) for post in posts[start : start + MAX_POSTS_PER_CHUNK]]
        # An unrecoverable failure raises, so Lambda retries the WHOLE batch;
        # chunks already applied are skipped via their markers.
        if _apply_chunk(bid, index, chunk) == "applied":
            applied += 1
        else:
            skipped += 1

    _log(
        event="counter_batch",
        batchId=bid,
        records=len(records),
        posts=len(posts),
        chunksApplied=applied,
        chunksSkipped=skipped,
    )
    return {}
