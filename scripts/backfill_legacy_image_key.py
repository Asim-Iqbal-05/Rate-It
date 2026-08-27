"""One-off migration: rewrite items still using the pre-multi-image
schema (a singular `imageKey` string) into the current shape (an
`imageKeys` list) - see the "Multi-image support added" note in the
project history. Feed Service only ever reads `imageKeys`, so any item
still on the old shape renders with no image at all.

Safe to run more than once (idempotent): an item that already has
`imageKeys` is left untouched.

Usage:
    python scripts/backfill_legacy_image_key.py [--table rateit-experiences] [--region us-west-2] [--dry-run]
"""

import argparse

import boto3


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
            if "imageKeys" in item:
                already_done += 1
                continue
            if "imageKey" not in item:
                # Neither shape present - nothing to migrate, nothing
                # to render either; leave it alone rather than guess.
                continue

            image_key = item["imageKey"]
            print(f"{item['experienceId']}: imageKey={image_key!r} -> imageKeys=[{image_key!r}]")

            if not args.dry_run:
                table.update_item(
                    Key={"experienceId": item["experienceId"]},
                    UpdateExpression="SET imageKeys = :keys REMOVE imageKey",
                    ExpressionAttributeValues={":keys": [image_key]},
                )
            migrated += 1

        if "LastEvaluatedKey" not in page:
            break
        scan_kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    verb = "Would migrate" if args.dry_run else "Migrated"
    print(f"\n{verb} {migrated} item(s); {already_done} already on the new scheme.")


if __name__ == "__main__":
    main()
