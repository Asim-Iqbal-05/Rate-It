# RateIt

Upload a photo, write a review, rate anything. See `docs/rateit-app-prd.md` (product/frontend) and `docs/rateit-infra-prd.md` (infrastructure) for full specs.

**Scope note:** this is a personal portfolio project — single AWS environment, region `us-west-2` (Oregon). No dev/staging/prod split, unlike the multi-environment framing in the infra PRD.

## Layout

- `docs/` — PRDs.
- `infra/bootstrap/` — one-time Terraform stack: S3 bucket for remote Terraform state (versioned, encrypted, private). Uses Terraform's native S3 state locking (`use_lockfile`, requires Terraform >= 1.10) — no DynamoDB lock table needed. Apply this once, first, with local state.
- `infra/env/` — the actual application infrastructure (Cognito, DynamoDB, S3, Lambda, ECS Fargate, API Gateway, CloudFront, WAF...), built out phase by phase per the infra PRD §11 build sequence. Uses the remote state backend created by `infra/bootstrap`.
- `frontend/` — React + Vite SPA, built per the app PRD §8 build sequence.

## Build order

Infra and frontend interleave — see each PRD's own build-sequence section (`infra` PRD §11, `app` PRD §8) for the authoritative phase list. Rough shape:

1. `infra/bootstrap` (Terraform state backend) — apply once, manually.
2. Infra Phase 1–4: Cognito, DynamoDB, S3, Lambda write path, API Gateway — gets you a real authenticated upload+write path.
3. Frontend Steps 1–2 can start against that: auth shell, then read-only feed screen.
4. Infra Phase 5: Feed Service (ECS Fargate, VPC, ALB) in parallel with frontend Steps 3–4 (upload flow, submit form).
5. Infra Phase 6+: CloudFront/edge delivery, WAF hardening, CI/CD, observability.

Terraform is applied manually by the project owner — plans are prepared and reviewed here, applies happen with explicit go-ahead each time.

## Operations: moderation queue

New posts are checked asynchronously by the Moderation Service (Lambda, triggered by the `rateit-experiences` DynamoDB stream). It **fails open**: if a post can't be checked (Rekognition unavailable, unreadable image, ...) it stays visible and a message goes to the `rateit-moderation-dlq` SQS queue. Messages in that queue mean someone needs to look.

When the "moderation queue not empty" alarm fires:

1. Read the Moderation Lambda's error logs (`/aws/lambda/rateit-moderation-service`) and fix the cause if it is on our side. Each queued message has a `reason`; `retryable: false` means that post can never be moderated automatically.
2. Enable the redrive mapping (it is disabled by default so a post that can never succeed doesn't loop forever):
   ```
   UUID=$(aws lambda list-event-source-mappings --function-name rateit-moderation-service:live \
     --query "EventSourceMappings[?contains(EventSourceArn, 'sqs')].UUID" --output text)
   aws lambda update-event-source-mapping --uuid $UUID --enabled
   ```
3. Watch the queue drain (`ApproximateNumberOfMessagesVisible`).
4. Disable it again:
   ```
   aws lambda update-event-source-mapping --uuid $UUID --no-enabled
   ```

A later `terraform apply` resetting the mapping to disabled is the intended behaviour. Messages without an `experienceId` are Lambda's own stream-failure pointers: the redrive logs their full body at error level and drops them, so read those logs for manual follow-up.

Unit tests for the Moderation Service (AWS stubbed): `python3 -m unittest discover -s tests/moderation` from the repo root (needs `boto3`).

## Operations: like counts

A like is one write to the `rateit-likes` table (the source of truth). The count shown on a post is **derived**: the Counter Lambda reads the table's stream in batches and updates `rateit-like-counters`, so a count can lag a like by a couple of seconds (the feed API covers this for the liker). Design and trade-offs: `docs/rateit-likes-redesign-prd.md`.

Things that are deliberate, not bugs:
- Deleting a post removes its counter but leaves its like rows behind (the table can't be queried by post). They are never read.
- The Counter Lambda's event source mapping has batch bisecting and partial-batch responses **off**. Its duplicate protection needs a retried batch to be identical to the original; turning either on would allow double counting.
- There is no "who liked this post" query and no index on `experienceId` (it would recreate the hot partition this design removed).

**"Like counter queue not empty" alarm** (`rateit-like-counter-dlq`): a stream batch failed permanently, so some counts may be off. The messages only hold stream metadata, not the likes themselves.
1. Read `/aws/lambda/rateit-counter-service` and fix the cause.
2. Repair by running the Reconciliation Lambda with repair on:
   ```
   aws lambda invoke --function-name rateit-reconciliation-service:live \
     --cli-binary-format raw-in-base64-out --payload '{"repair": true}' /dev/stdout
   ```
3. Run it again without the payload (detect mode) and confirm `"drift": 0`.

**"Like count drift" alarm**: the weekly reconciliation (Saturday 21:00 UTC, detect only) found posts whose count differs from their like rows; each one is logged in `/aws/lambda/rateit-reconciliation-service`. Same repair as above. Unit tests: `python3 -m unittest discover -s tests/counter` and `-s tests/reconciliation`.
