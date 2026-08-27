"""One-off migration: rewrite every existing item's `Type` attribute
from the constant "POST" to its time-bucketed value ("POST#YYYY-MM",
derived from the item's own CreatedAt) - infra PRD §7.1's documented
GSI hot-partition fix.

Safe to run more than once (idempotent): an item already on the new
scheme has Type != "POST" and is skipped.

Run this AFTER deploying the new Feed Service (which already knows how
to fall back to the legacy "POST" bucket while this hasn't run yet) -
never before, or the old Feed Service would stop finding these items
until the new one is live. See docs/rateit-infra-prd.md §7.1.

Usage:
    python scripts/backfill_feed_buckets.py [--table rateit-experiences] [--region us-west-2] [--dry-run]
"""

import argparse

import boto3

LEGACY_BUCKET = "POST"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--table", default="rateit-experiences")
    parser.add_argument("--region", default="us-west-2")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change without writing anything.",
    )
    args = parser.parse_args()

    dynamodb = boto3.resource("dynamodb", region_name=args.region)
    table = dynamodb.Table(args.table)

    migrated = 0
    already_done = 0

    scan_kwargs: dict = {}
    while True:
        page = table.scan(**scan_kwargs)

        for item in page.get("Items", []):
            if item.get("Type") != LEGACY_BUCKET:
                already_done += 1
                continue

            new_bucket = f"POST#{item['CreatedAt'][:7]}"
            print(f"{item['experienceId']}: {LEGACY_BUCKET} -> {new_bucket}")

            if not args.dry_run:
                table.update_item(
                    Key={"experienceId": item["experienceId"]},
                    UpdateExpression="SET #t = :new_bucket",
                    ExpressionAttributeNames={"#t": "Type"},
                    ExpressionAttributeValues={":new_bucket": new_bucket},
                )
            migrated += 1

        if "LastEvaluatedKey" not in page:
            break
        scan_kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    verb = "Would migrate" if args.dry_run else "Migrated"
    print(f"\n{verb} {migrated} item(s); {already_done} already on the new scheme.")


if __name__ == "__main__":
    main()
