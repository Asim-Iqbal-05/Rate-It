# Extension PRD: RateIt Reactions, Moderation and Post Management

**Status:** Built and verified live (2026-10-07). The likes design in this document (§5.1, §7.1, step 4 of §7.4, the like part of §7.6, the Reactions rows of §8.2, and §15) was later replaced by `rateit-likes-redesign-prd.md`; the notes marked **Correction** below record what building it found.
**Date:** 2026-10-07
**Audience:** The Claude Code session (or engineer) that built the existing RateIt stack
**Companion docs:** `rateit-app-prd.md`, `rateit-infra-prd.md`, `rateit-architecture.drawio` (target architecture diagram)

This document specifies what to add on top of the working system. It does not restate what already exists. Read section 2 before writing any code.

---

## 1. Summary

RateIt grows from three services to five, and gains four small features.

| Item | Type | Compute | Trigger |
|---|---|---|---|
| Reactions Service | New service | Lambda, outside the VPC | API Gateway (sync) |
| Moderation Service | New service | Lambda, outside the VPC | DynamoDB Stream (async), SQS (redrive) |
| Delete own post | Feature | Experience Service (existing Lambda) | API Gateway |
| My posts | Feature | Feed Service (existing Fargate) | API Gateway |
| Like count and liked state in the feed | Feature | Feed Service | API Gateway |
| Image carousel, like button, delete button | Feature | Frontend SPA | n/a |

New AWS resources: one DynamoDB table (`Reactions`), one GSI and a stream on the `Experiences` table, one SQS queue (dead-letter queue), two Lambda functions, three API routes, two event source mappings, Rekognition access, and alarms.

---

## 2. Ground rules for the implementing session

1. **Inspect before you build.** You have the codebase; the author of this document did not. Confirm the real table name, key names, GSI name, Terraform module layout, Lambda runtime and packaging, and how Feed Service learns who the caller is.
2. **Code wins on names, this document wins on behaviour.** If a resource is named differently in the repo, keep the repo's name. If the repo's behaviour contradicts this document, stop and report it; do not guess.
3. **Follow existing conventions.** Same language and runtime as the existing Lambdas, same Terraform module pattern, same naming scheme (`rateit-<env>-...` or whatever is in use), same logging format, same versioned alias deployment.
4. **All infrastructure goes in Terraform**, through the existing pipeline. No console changes.
5. **Do not break the three invariants in section 4.** They are the reason the design looks the way it does.
6. **Build in the order given in section 13.** Each phase is independently testable.

---

## 3. Current state this document assumes

Verify each of these. If one is wrong, tell the owner before continuing.

**`Experiences` table**

| Attribute | Type | Role |
|---|---|---|
| `experienceId` | String | Table partition key. No sort key. |
| `Type` | String | Monthly grouping value. Feed GSI partition key. |
| `CreatedAt` | String | ISO 8601 UTC. Feed GSI sort key. |
| `userId` | String | Cognito `sub` of the author. |
| `title`, `description` | String | Post text. |
| `rating` | Number | 1 to 5. |
| `imageKeys` | List of strings | S3 object keys, 1 to 5 entries. No bucket name stored. |

Capitalisation matters: the stored names are `Type` and `CreatedAt`.

**Other assumptions**

- The feed GSI is keyed on `Type` + `CreatedAt` and Feed Service reads the current month first, then falls back to earlier months to fill a page.
- `GET /api/feed` is uncached at every layer and authenticated on every request (infra PRD section 12).
- AWS WAF is attached to CloudFront, not to API Gateway (infra PRD section 2).
- Media Service issues keys shaped `{userId}/{uuid}.jpg` with a presigned POST and a `starts-with $Content-Type image/` condition.
- Experience Service tags uploaded objects `status=claimed` after the DynamoDB write.
- Lambdas deploy as versioned aliases. Feed Service deploys with ECS native blue/green.

---

## 4. Design invariants (do not break)

These keep the feed index cold. The feed GSI is the one shared hot spot in the system, so nothing frequent may write to it.

1. **A post item is written only at creation, takedown and delete.** Never for a like, an unlike, or a clean moderation result.
2. **Likes and like counts live only in the `Reactions` table.** No like data is ever stored on, or projected from, a post item.
3. **Do not add frequently changing attributes to post items.** If the feed GSI projects `ALL`, any attribute added to a post is copied into the index and every update to it becomes an index write.

A consequence of rule 1: a post that passes moderation gets no write at all. There is no stored "approved" status. The absence of `removed` means the post is live.

---

## 5. Data model changes

### 5.1 New table: `Reactions`

| Setting | Value |
|---|---|
| Partition key | `experienceId` (String) |
| Sort key | `userId` (String) |
| Billing mode | On-demand |
| Stream | Not needed |
| Point in time recovery | Match the `Experiences` table |

Two kinds of item share the table:

| Item | `experienceId` | `userId` | Other attributes |
|---|---|---|---|
| Like row | post ID | Cognito `sub` of the liker | `createdAt` (ISO 8601 UTC) |
| Count row | post ID | the literal string `COUNT` | `likeCount` (Number) |

A Cognito `sub` is a UUID, so it can never equal `COUNT`. A missing count row means zero likes.

### 5.2 Changes to `Experiences`

| Change | Detail |
|---|---|
| Enable stream | View type `NEW_IMAGE`. |
| Add GSI for author lookups | Partition key `userId`, sort key `CreatedAt`, projection `ALL`. Suggested name `userId-CreatedAt-index`. DynamoDB backfills it automatically. |
| New optional attributes | `removed` (Boolean), `removedReason` (String), `removedAt` (ISO 8601 UTC). Written only by a takedown. |

No existing attribute changes and no data migration is required.

**Takedown mechanics.** A takedown removes the `Type` attribute and sets the three `removed*` attributes in one `UpdateItem`. An item without `Type` is not in the feed GSI, so the post leaves the feed with no change to Feed Service's feed query. It remains in the `userId` GSI, so its author still sees it under "My posts". Use `ExpressionAttributeNames` for `Type`.

---

## 6. API changes

All routes sit behind the existing Cognito JWT authorizer. The caller's identity always comes from the token's `sub` claim, never from the request body or query string.

### 6.1 `PUT /api/experiences/{experienceId}/like` (new, Reactions Service)

Marks the post as liked by the caller. Idempotent.

| Status | Meaning |
|---|---|
| `204` | Liked, or already liked. |
| `404` | Post does not exist or has been removed. |
| `401` | Missing or invalid token (returned by API Gateway). |
| `429` | Rate limited by WAF. |

### 6.2 `DELETE /api/experiences/{experienceId}/like` (new, Reactions Service)

Removes the caller's like. Idempotent.

| Status | Meaning |
|---|---|
| `204` | Unliked, or was not liked. |
| `401`, `429` | As above. |

No request or response bodies on either route.

### 6.3 `DELETE /api/experiences/{experienceId}` (new, Experience Service)

Deletes the caller's own post.

| Status | Meaning |
|---|---|
| `204` | Deleted. |
| `403` | The post belongs to someone else. |
| `404` | Post does not exist. |

### 6.4 `GET /api/feed` (changed, Feed Service)

New optional query parameter: `author=me`. Any other value for `author` returns `400`.

Each item gains fields:

```json
{
  "experienceId": "uuid",
  "userId": "cognito-sub",
  "title": "...",
  "description": "...",
  "rating": 4,
  "imageUrls": ["https://.../image1.jpg"],
  "createdAt": "2026-08-21T10:15:00Z",
  "likeCount": 12,
  "likedByMe": true,
  "removed": false
}
```

- `likeCount` and `likedByMe` are present on every item.
- `removed` is `true` only for the caller's own taken-down posts in the `author=me` view. The global feed never contains removed posts.
- For a removed item, return `imageUrls` as an empty array.
- Pagination is unchanged: `nextPageToken` stays opaque.

### 6.5 `GET /api/media/upload-url` (changed, Media Service)

New optional query parameter: `contentType`, one of `image/jpeg` or `image/png`. Default `image/jpeg`. Any other value returns `400`. See section 7.5 for the reason.

---

## 7. Service specifications

### 7.1 Reactions Service (new Lambda)

**Like.** One `TransactWriteItems` call with three operations, in this order:

1. `ConditionCheck` on `Experiences`, key `experienceId`: `attribute_exists(experienceId) AND attribute_not_exists(removed)`.
2. `Put` the like row into `Reactions`: `attribute_not_exists(experienceId)`.
3. `Update` the count row in `Reactions`: `ADD likeCount :one`.

Handle `TransactionCanceledException` by reading `CancellationReasons`, which are in the same order as the operations:

- Reason 1 is `ConditionalCheckFailed`: return `404`.
- Reason 2 is `ConditionalCheckFailed`: the user already liked the post. Return `204`.
- Anything else (throttling, transaction conflict): retry with backoff up to 3 times, then return `503`.

The `ConditionCheck` reads the post but does not write to it, so invariant 1 holds.

> **Correction (found while building):** a `ConditionCheck` inside `TransactWriteItems` is still *billed* as a write: each like consumed 2 write capacity units on `Experiences` (verified with `ReturnConsumedCapacity`). Nothing is written, no index is charged and no stream record is produced, so invariant 1 is intact in the sense that matters (the feed GSI is never written) — but "zero consumed write capacity" is not achievable with this design. The likes redesign removed the check entirely: a like now does a plain read of the post, so it costs no write capacity on `Experiences` at all.

**Unlike.** One `TransactWriteItems` call with two operations:

1. `Delete` the like row: `attribute_exists(experienceId)`.
2. `Update` the count row: `ADD likeCount :minusOne`.

If operation 1 fails its condition, the user had not liked the post. Return `204`. Because the decrement only happens when a like row was really deleted, the count cannot go below zero.

**Configuration.** Memory 256 MB, timeout 5 seconds, table names from environment variables, versioned alias.

### 7.2 Moderation Service (new Lambda)

One function with two triggers. Detect the trigger from the event shape (`eventSource` is `aws:dynamodb` or `aws:sqs`).

**Trigger A: `Experiences` stream.** Event source mapping settings:

| Setting | Value |
|---|---|
| Starting position | `LATEST` |
| Filter | `eventName` equals `INSERT` only. Takedowns (`MODIFY`) and deletes (`REMOVE`) must not trigger the function. |
| Batch size | 10 |
| Maximum retry attempts | 3. Do not leave the default, which retries until the record expires and blocks the shard. |
| Bisect batch on function error | Enabled |
| Maximum record age | 3600 seconds |
| Function response types | `ReportBatchItemFailures` |
| On-failure destination | The SQS queue from section 7.3 |
| Target | The function alias, not `$LATEST` |

**Processing one post** (from the stream record's new image):

For each key in `imageKeys`:

1. **Magic-byte check.** `GetObject` with `Range: bytes=0-11` from the uploads bucket. Accept only JPEG (`FF D8 FF`) and PNG (`89 50 4E 47 0D 0A 1A 0A`). Anything else is a takedown with reason `invalid_file_type`.
2. **Rekognition.** `DetectModerationLabels` with an `S3Object` reference (bucket from an environment variable, key from the post) and `MinConfidence` from an environment variable, default 80.
3. **Decision.** The post is flagged if any returned label belongs to a blocked top-level category. The blocked list comes from an environment variable. Suggested default: explicit content, violence, visually disturbing content and hate symbols. Confirm the exact category names against the current Rekognition moderation taxonomy before hardcoding the default.

Stop at the first flagged image; the whole post is taken down.

**Takedown.** One `UpdateItem` on the post: `REMOVE #Type SET removed = :true, removedReason = :reason, removedAt = :now`, with condition `attribute_exists(experienceId)`. If the condition fails the author already deleted the post; treat that as success.

**Clean post.** Write nothing. Log one structured line with the `experienceId` and the outcome.

**Error handling.** Process each record independently inside its own try block.

| Failure | Action |
|---|---|
| Transient (throttling, 5xx, timeout from S3, Rekognition or DynamoDB) | Retry in the function with backoff, up to 3 attempts. If still failing, send a message to the queue and treat the record as handled. |
| Terminal (image too large or unreadable for Rekognition, object missing) | Send a message to the queue with `retryable: false` and treat the record as handled. |
| The function cannot send to the queue, or crashes | Report the record as a batch item failure. Lambda retries 3 times, then writes its own pointer message to the queue through the on-failure destination. |

Treating a record as handled after queueing it is what stops one bad post from blocking every post behind it.

**Failure policy (deliberate).** When moderation fails, the post stays visible until someone works the queue. The system fails open so that a Rekognition outage does not hide every new post.

**Trigger B: SQS redrive.** See section 7.3.

**Configuration.** Memory 512 MB, timeout 60 seconds, versioned alias.

### 7.3 Dead-letter queue and redrive

**Queue.** One standard SQS queue, suggested name `rateit-<env>-moderation-dlq`. Retention 14 days, server-side encryption on, visibility timeout 360 seconds (six times the function timeout).

**Message written by the function:**

```json
{
  "experienceId": "uuid",
  "reason": "rekognition_unavailable",
  "retryable": true,
  "failedAt": "2026-10-07T09:00:00Z"
}
```

**Message written by Lambda's on-failure destination.** This has a different shape. It contains stream metadata (shard ID and sequence numbers) and no post data. The redrive handler cannot reprocess it; log it at error level with the full body and leave it for manual handling. This path should be rare.

**Redrive.** A second event source mapping, from the queue to the same function, created **disabled** (`enabled = false`), batch size 5, with `ReportBatchItemFailures`. When it runs:

1. Parse the body. If it has no `experienceId`, log and delete the message.
2. `GetItem` the post. If it no longer exists, or already has `removed`, delete the message.
3. Run the same moderation logic as trigger A.
4. On success, the message is deleted. On failure, report it as a batch item failure so it returns to the queue.

**Operating procedure** (add to the repo's runbook or README):

1. The alarm in section 9 fires.
2. Read the function's error logs and fix the cause if it is on our side.
3. Enable the redrive mapping: `aws lambda update-event-source-mapping --uuid <id> --enabled`.
4. Watch the queue drain.
5. Disable it again: `aws lambda update-event-source-mapping --uuid <id> --no-enabled`.

The mapping stays disabled by default on purpose. If it were always on, a post that can never succeed would loop forever. A later Terraform apply resetting it to disabled is the desired behaviour.

### 7.4 Experience Service (existing Lambda, extended)

Add a handler for `DELETE /api/experiences/{experienceId}`:

1. `GetItem` the post. Missing: `404`. `userId` differs from the token's `sub`: `403`.
2. `DeleteItem` the post with condition `userId = :sub`. This removes it from both GSIs, so it disappears from the feed immediately.
3. Delete the S3 objects listed in `imageKeys` with one `DeleteObjects` call.
4. Delete the post's rows in `Reactions`: `Query` by `experienceId` (paginate), then `BatchWriteItem` deletes in groups of 25, retrying `UnprocessedItems`.
5. Return `204`.

If step 3 or 4 fails after step 2 succeeded, log an error containing the `experienceId` and still return `204`. The post is gone, which is what the user asked for; the leftovers are harmless orphans. New likes cannot arrive after step 2 because the Reactions Service checks that the post exists.

Raise the function timeout to 30 seconds (the API Gateway integration ceiling) to allow for posts with many likes.

### 7.5 Media Service (existing Lambda, changed)

Rekognition accepts JPEG and PNG only, so uploads are restricted to those two formats.

- Read the `contentType` query parameter (section 6.5).
- Replace the `starts-with $Content-Type image/` condition with an exact match on the requested type.
- Use the matching extension in the key: `.jpg` or `.png`.
- Check that the policy's `content-length-range` upper bound does not exceed Rekognition's limit for S3-referenced images. The author recalls 15 MB; verify against the AWS documentation and lower the bound if needed.

### 7.6 Feed Service (existing Fargate service, extended)

**Structure the handler as two steps**, so that a shared cache can later wrap the first step without a rewrite:

1. `fetchPage(...)`: the post list, identical for every user.
2. `decorate(page, callerSub)`: the per-user and per-post like data.

**Like data.** After fetching a page, issue one `BatchGetItem` on `Reactions` with two keys per post: `(experienceId, "COUNT")` and `(experienceId, callerSub)`.

- `BatchGetItem` accepts at most 100 keys, so the page size must be 50 or fewer. Check the current page size.
- Retry `UnprocessedKeys` with backoff.
- Use `ConsistentRead: true` so that a like the user just made shows after a refresh.
- No count row: `likeCount` is 0. Like row present: `likedByMe` is `true`.

**My posts.** When `author=me`, query the `userId` GSI with the caller's `sub`, newest first, with the same page size and token handling as the feed. Include taken-down posts with `removed: true` and an empty `imageUrls`.

**Caller identity.** Feed Service needs the caller's `sub`. Check how it gets identity today. If it does not, add a parameter mapping on the API Gateway feed integration that overwrites a request header (for example `x-user-sub`) with `$context.authorizer.claims.sub`. Overwriting means a client cannot forge it, and the ALB is reachable only through the VPC Link.

**Networking.** No change. The existing DynamoDB gateway endpoint already covers the new table and index.

---

## 8. Infrastructure changes (Terraform)

### 8.1 Resources to add

| Resource | Notes |
|---|---|
| `Reactions` DynamoDB table | Section 5.1 |
| Stream and GSI on `Experiences` | Section 5.2. Apply the GSI as its own change; DynamoDB creates one GSI at a time. |
| Reactions Lambda, alias, log group | Section 7.1 |
| Moderation Lambda, alias, log group | Section 7.2 |
| SQS queue | Section 7.3 |
| Two event source mappings | Stream (enabled) and SQS redrive (disabled) |
| Three API Gateway routes and integrations | Sections 6.1 to 6.3, all with the JWT authorizer, plus Lambda invoke permissions |
| Alarms | Section 9 |

### 8.2 IAM (least privilege, one role per service)

| Role | Add |
|---|---|
| Reactions Lambda | `dynamodb:PutItem`, `DeleteItem`, `UpdateItem` on `Reactions`. `dynamodb:ConditionCheckItem` on `Experiences`. |
| Moderation Lambda | Stream read actions on the `Experiences` stream ARN. `dynamodb:GetItem`, `UpdateItem` on `Experiences`. `s3:GetObject` on the uploads bucket. `rekognition:DetectModerationLabels`. `sqs:SendMessage`, `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes` on the queue. |
| Experience Lambda | `dynamodb:GetItem`, `DeleteItem` on `Experiences`. `s3:DeleteObject` on the uploads bucket. `dynamodb:Query`, `BatchWriteItem` on `Reactions`. |
| Feed Service task role | `dynamodb:BatchGetItem` on `Reactions`. `dynamodb:Query` on the new GSI ARN. |

Rekognition reads the S3 object using the calling role's permissions, so the `s3:GetObject` grant on the Moderation role covers it. No bucket policy change is needed.

### 8.3 Edge and API settings to verify

- **CloudFront `/api/*` behaviour:** allowed methods must include `PUT` and `DELETE`.
- **CORS:** if any CORS configuration exists on API Gateway, add `PUT` and `DELETE`.
- **WAF rate limit:** the current per-token limit was sized for a read and post workload. Liking while scrolling will exceed it. Raise the value in each environment's `.tfvars`. Suggested starting point: 300 requests per 5 minutes per token, then tune from WAF metrics.

### 8.4 CI/CD

Add the two new Lambda packages to the application build stage and deploy them with the same versioned alias mechanism as the existing Lambdas. No new pipeline stages.

---

## 9. Observability

Add to the existing alarm set, with thresholds in per-environment `.tfvars`:

| Alarm | Metric and condition |
|---|---|
| Moderation queue not empty | SQS `ApproximateNumberOfMessagesVisible` greater than 0 |
| Moderation falling behind | Lambda `IteratorAge` on the stream mapping above 5 minutes |
| Reactions errors | Lambda `Errors` and `Duration` p99, same pattern as existing Lambdas |
| Moderation errors | Lambda `Errors`, same pattern |
| Index throttling | `Experiences` GSI throttle events for both indexes, not only the table. A throttled GSI also throttles writes to the base table. |
| Reactions table throttling | Throttled requests on `Reactions` |

Use the same alarm action as the existing alarms. If the existing alarms have no notification target, leave the action empty and tell the owner; do not invent one.

Log one structured line per moderation decision: `experienceId`, outcome (`clean`, `removed`, `queued`), reason, duration.

---

## 10. Frontend changes

| Change | Detail |
|---|---|
| Like button and count | On every feed card, from `likeCount` and `likedByMe`. |
| Optimistic like with debounce | Update the heart and count instantly. Wait about 500 ms, then send only the final state (`PUT` or `DELETE`). On failure, revert and show a brief message. On `404`, remove the card. |
| Delete button | Only on cards where `userId` equals the signed-in user's `sub`. Confirm before sending. Remove the card on `204`. |
| My posts view | A toggle or tab that calls `GET /api/feed?author=me`. Show a "Removed by moderation" state for items with `removed: true`. |
| Image carousel | Browse all `imageUrls` on a card. The app PRD flags this as not yet built. |
| Upload restriction | Accept only JPEG and PNG in the picker. Send the file's type as `contentType` when requesting the upload URL. Show a clear message for other formats. |

Existing rules still apply: keep the token in `sessionStorage`, reconcile optimistic state with the next real feed fetch, and never expose the rate limiting mechanism in error text.

---

## 11. Acceptance criteria

**Reactions**
- Liking a post twice leaves `likeCount` at 1 and returns `204` both times.
- Unliking a post that was not liked returns `204` and does not change the count.
- Liking a missing or removed post returns `404` and creates no rows.
- After 50 mixed like and unlike calls from several users, `likeCount` equals the number of like rows for that post.
- A like produces no writes to the `Experiences` table or to either of its indexes, and no stream record. Confirm from the **index** write capacity metrics and the stream record count, not the table's consumed write capacity (see the correction in §7.1: a transactional `ConditionCheck` is billed as 2 write units even though nothing is written). *(Under the later likes redesign a like does not touch `Experiences` capacity at all.)*

**Moderation**
- A new post with clean JPEG images stays in the feed and its item is unchanged.
- A new post with a flagged image disappears from the global feed, has no `Type`, and has `removed`, `removedReason` and `removedAt`.
- A new post whose "image" is a text file renamed to `.jpg` is taken down with reason `invalid_file_type`.
- A takedown does not trigger the function again.
- With Rekognition access denied (remove the IAM permission in dev), a new post stays visible, one message with its `experienceId` lands in the queue, the alarm fires, and later posts are still processed.
- After restoring access and enabling the redrive mapping, the queue drains and the post is moderated.

**Delete**
- Deleting your own post returns `204`; the post, its S3 objects and its `Reactions` rows are gone.
- Deleting someone else's post returns `403` and changes nothing.

**Feed**
- Every feed item has `likeCount` and `likedByMe`.
- `author=me` returns only the caller's posts, including removed ones flagged as such.
- A post the caller just created still appears on the next feed load.
- A like the caller just made shows as `likedByMe: true` on the next feed load.

**Upload**
- Requesting `contentType=image/webp` returns `400`.
- A PNG upload produces a key ending in `.png` and succeeds end to end.

**Regression**
- Sign in, upload, post and feed all behave as before.
- An ECS blue/green deployment of Feed Service still completes and rolls back.

---

## 12. Out of scope

- Comments, notifications, thumbnails, post editing, public profiles.
- Redis or any cache for like counts.
- Feed caching (still deferred, per infra PRD section 12).
- A shard suffix on the feed GSI key.
- Automatic redrive of the queue.
- A separate asynchronous cleanup service for deletes.
- Deleting or blocking the S3 objects of taken-down posts. Known limitation: a removed post's images stay reachable through `/images/*` by anyone who already has the URL.

---

## 13. Build sequence

Each phase ends in something testable. Do not start a phase until the previous one passes.

**Phase A: data layer**
`Reactions` table, stream on `Experiences`, `userId` GSI. Verify the GSI finishes backfilling.

**Phase B: Reactions Service**
Lambda, IAM, two routes. Test by direct invoke, then through API Gateway. Raise the WAF limit.

**Phase C: Feed Service changes**
Two-step handler, `BatchGetItem`, `author=me`, caller identity. Deploy with blue/green.

**Phase D: Media Service restriction**
`contentType` parameter and exact-match policy. Do this before Moderation so no new unsupported uploads arrive.

**Phase E: Moderation Service and queue**
Queue, Lambda, IAM, stream mapping, disabled redrive mapping, alarms. Run every moderation acceptance test, including the forced failure.

**Phase F: delete**
Experience Service handler, IAM, route.

**Phase G: frontend**
Like button with debounce, delete, My posts, carousel, upload restriction.

**Phase H: documentation**
Section 14, then update both PRDs with the new services, routes and data model.

---

## 14. Corrections to the existing PRDs

Fix these while you are in the documents. They describe designs that were later reversed.

| Document | Location | Problem |
|---|---|---|
| Infra PRD | Section 4 | Still says `GET /api/feed` gets a CloudFront TTL. Section 12 rejected feed caching. |
| Infra PRD | Section 6 | Says the WAF rule is on API Gateway, keyed on `sub`. Section 2 moved it to CloudFront, keyed on the Authorization header. |
| Infra PRD | Section 7.1 | Says `Type` is the constant `"POST"` and that the CloudFront cache mitigates the hot partition. `Type` is a monthly value and there is no cache. Replace the text with the invariants in section 4 of this document. |
| Infra PRD | Phase 7 | Lists the WAF rule on API Gateway and the feed cache as steps. |
| App PRD | Section 4.3 | Says the feed may be served from a CloudFront cache. |
| App PRD | Section 8, Step 4 | Says `imageKey`. It is `imageKeys`. |
| App PRD | Section 7 | Lists deleting posts, moderation and likes as out of scope. |

---

## 15. Capacity notes and upgrade paths

Approximate ceilings for this design, for the record. None of them need action now.

| Limit | Rough ceiling | How to raise it later |
|---|---|---|
| Likes on a single post | About 250 per second (every like updates that post's one count row) | Stop updating the count in the transaction. Add a stream on `Reactions` and a small Lambda that sums likes in batches. |
| Feed page loads | About 1,200 per second on one GSI partition | Wrap `fetchPage` in the post-authorizer cache described in infra PRD section 12. |
| New posts | Several hundred per second into the current month's GSI partition | Add a shard suffix to the `Type` value. Requires rewriting existing values. |

---

## 16. Questions to raise with the owner if they block you

1. Do the existing alarms have a notification target? If not, should one be added?
2. Is the suggested list of blocked moderation categories acceptable?
3. What is the current upload size cap, and does it need lowering for Rekognition?
4. What is the current feed page size? It must be 50 or fewer.
