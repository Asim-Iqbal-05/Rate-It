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
