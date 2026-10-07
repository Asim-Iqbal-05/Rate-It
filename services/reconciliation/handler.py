"""Reconciliation Lambda: checks (and optionally repairs) like counts.

Counts are derived from the Likes table, so they need a way to be verified.
This is also the recovery path for anything the Counter Lambda's idempotency
marker can't cover, such as a batch that ended up in its dead-letter queue.

  - detect (default): compare real like rows against stored counters, publish
    the number of differing posts as a CloudWatch metric, log each one.
  - repair ({"repair": true}): apply ADD (actual - stored) to each differing
    counter. ADD, not SET, so likes arriving during the run are not overwritten.

Deleted posts are ignored. Deleting a post removes its counter but leaves its
like rows behind (accepted trade-off), so without this every deleted post that
had likes would look like permanent drift, and repair would recreate counters
for posts that no longer exist.

Counters lag likes by a couple of seconds, so a difference is only reported if
it is identical on two full passes a few seconds apart.

SCALE: scanning Likes inside one Lambda is fine up to a few million like rows.
Beyond that, move this to a DynamoDB export to S3 (and process the export).
"""
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.client("dynamodb")
cloudwatch = boto3.client("cloudwatch")

LIKES_TABLE = os.environ["LIKES_TABLE"]
COUNTERS_TABLE = os.environ["COUNTERS_TABLE"]
EXPERIENCES_TABLE = os.environ["EXPERIENCES_TABLE"]
SETTLE_SECONDS = float(os.environ.get("SETTLE_SECONDS", "10"))

METRIC_NAMESPACE = "RateIt/Likes"
METRIC_NAME = "CountDrift"
POST_PREFIX = "POST#"


def _log(**fields):
    print(json.dumps(fields, default=str))


def _scan(**kwargs):
    while True:
        page = dynamodb.scan(**kwargs)
        yield from page.get("Items", [])
        if "LastEvaluatedKey" not in page:
            return
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def _actual_counts():
    counts = {}
    for item in _scan(TableName=LIKES_TABLE, ProjectionExpression="experienceId"):
        post = item["experienceId"]["S"]
        counts[post] = counts.get(post, 0) + 1
    return counts


def _stored_counts():
    stored = {}
    for item in _scan(
        TableName=COUNTERS_TABLE,
        FilterExpression="begins_with(pk, :p)",
        ExpressionAttributeValues={":p": {"S": POST_PREFIX}},
    ):
        stored[item["pk"]["S"][len(POST_PREFIX):]] = int(item.get("likeCount", {"N": "0"})["N"])
    return stored


def _existing_posts(post_ids):
    existing = set()
    post_ids = sorted(post_ids)
    for start in range(0, len(post_ids), 100):
        pending = {
            EXPERIENCES_TABLE: {
                "Keys": [{"experienceId": {"S": p}} for p in post_ids[start : start + 100]],
                "ProjectionExpression": "experienceId",
            }
        }
        for attempt in range(5):
            response = dynamodb.batch_get_item(RequestItems=pending)
            for item in response["Responses"].get(EXPERIENCES_TABLE, []):
                existing.add(item["experienceId"]["S"])
            pending = response.get("UnprocessedKeys") or {}
            if not pending:
                break
            time.sleep(0.1 * (2**attempt))
        else:
            raise RuntimeError("Experiences BatchGetItem still had unprocessed keys")
    return existing


def find_differences():
    """{experienceId: actual - stored} for existing posts whose count is off."""
    actual = _actual_counts()
    stored = _stored_counts()
    off = {p for p in actual.keys() | stored.keys() if actual.get(p, 0) != stored.get(p, 0)}
    if not off:
        return {}
    live = _existing_posts(off)
    return {p: actual.get(p, 0) - stored.get(p, 0) for p in off if p in live}


def lambda_handler(event, context):
    repair = bool((event or {}).get("repair"))

    first = find_differences()
    if first:
        # Give the Counter Lambda time to catch up with recent likes, then
        # keep only differences that are unchanged on a second full pass.
        time.sleep(SETTLE_SECONDS)
        second = find_differences()
        differences = {p: d for p, d in second.items() if first.get(p) == d}
    else:
        differences = {}

    for post, diff in sorted(differences.items()):
        _log(event="count_drift", experienceId=post, actualMinusStored=diff)

    # Always published (zero included) so the alarm sees a healthy run.
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{"MetricName": METRIC_NAME, "Value": len(differences), "Unit": "Count"}],
    )

    repaired = 0
    if repair:
        for post, diff in differences.items():
            try:
                dynamodb.update_item(
                    TableName=COUNTERS_TABLE,
                    Key={"pk": {"S": f"{POST_PREFIX}{post}"}},
                    UpdateExpression="ADD likeCount :d",
                    ExpressionAttributeValues={":d": {"N": str(diff)}},
                )
                repaired += 1
            except ClientError as e:
                _log(level="error", event="repair_failed", experienceId=post, error=repr(e))

    _log(event="reconciliation_done", drift=len(differences), repaired=repaired, repair=repair)
    return {"drift": len(differences), "repaired": repaired, "differences": differences}
