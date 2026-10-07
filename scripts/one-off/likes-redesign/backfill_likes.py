#!/usr/bin/env python3
"""ONE-OFF: copy like rows from the old Reactions table into the new Likes table.

Part of the likes redesign migration (docs/rateit-likes-redesign-prd.md
section 9, step 3). Run it ONCE, right after the app changes are deployed.

  - Every old row whose sort key (userId) is not "COUNT" is a like. It is
    written to Likes as (userId, experienceId, createdAt).
  - The old "COUNT" rows are skipped entirely: counts are rebuilt by the
    Counter Lambda, because each row written here is an INSERT on the Likes
    stream.
  - The write is conditional (attribute_not_exists(userId)), so a like that
    was already made through the new path is not written twice - and
    therefore not counted twice. That also makes this safe to re-run.

Usage:
    python3 backfill_likes.py --dry-run     # show what would be written
    python3 backfill_likes.py               # write
"""
import argparse

import boto3
from botocore.exceptions import ClientError

OLD_TABLE = "rateit-reactions"
NEW_TABLE = "rateit-likes"
COUNT_ROW = "COUNT"


def backfill(scan_pages, put_like, dry_run):
    """scan_pages yields lists of old rows; put_like(row) returns True if written,
    False if the like already existed. Returns (written, already_there, skipped_counts)."""
    written = already_there = skipped_counts = 0
    for page in scan_pages:
        for row in page:
            if row["userId"] == COUNT_ROW:
                skipped_counts += 1
                continue
            if dry_run:
                written += 1
                print(f"  would write like: user={row['userId']} post={row['experienceId']}")
                continue
            if put_like(row):
                written += 1
            else:
                already_there += 1
    return written, already_there, skipped_counts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print what would be written, write nothing")
    args = parser.parse_args()

    client = boto3.client("dynamodb")

    def scan_pages():
        kwargs = {"TableName": OLD_TABLE}
        while True:
            page = client.scan(**kwargs)
            yield [
                {
                    "userId": item["userId"]["S"],
                    "experienceId": item["experienceId"]["S"],
                    "createdAt": item.get("createdAt", {}).get("S"),
                }
                for item in page["Items"]
            ]
            if "LastEvaluatedKey" not in page:
                return
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    def put_like(row):
        item = {"userId": {"S": row["userId"]}, "experienceId": {"S": row["experienceId"]}}
        if row["createdAt"]:
            item["createdAt"] = {"S": row["createdAt"]}
        try:
            client.put_item(
                TableName=NEW_TABLE,
                Item=item,
                ConditionExpression="attribute_not_exists(userId)",
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    written, already_there, skipped = backfill(scan_pages(), put_like, args.dry_run)
    verb = "would write" if args.dry_run else "wrote"
    print(f"{verb} {written} like rows; {already_there} already existed; skipped {skipped} old COUNT rows")


if __name__ == "__main__":
    main()
