# Infrastructure PRD: "RateIt"

**Status:** Draft v1
**Audience:** Platform/infra engineers, DevOps, SRE
**Companion doc:** `rateit-app-prd.md` (product features, API contracts, frontend flows)
**Compute model:** Hybrid — Lambda for stateless write/utility endpoints, ECS Fargate for the read-heavy feed service, unified behind a single API Gateway.
**Extension:** reactions (likes), moderation and post deletion were added on top of this design — see §13 and `rateit-extension-prd.md`.

---

## 1. Purpose & Scope

This document defines the **infrastructure architecture** for rateit: networking, compute, data storage, edge delivery, security/abuse-prevention, deployment strategy, and CI/CD. It intentionally excludes product features, UX, and API request/response contracts — see the companion App PRD for those.

The guiding principle: **one public entry point, one auth enforcement point, mixed compute behind it, protected by an edge WAF layer.**

---

## 2. Architecture Overview

```
Route 53 (DNS)
      │
CloudFront (single entry point, HTTPS enforced, OAC to origins)
   │  WAF (rate-based rules: per-token via Authorization header, per-IP fallback)
   ├── /*         → S3 frontend bucket (private, OAC-only)
   ├── /images/*  → S3 uploads bucket (private, OAC-only)
   └── /api/*     → API Gateway (HTTP API)
                        │
                 Cognito JWT Authorizer (validates bearer token)
                        │
        ┌───────────────┬────────────┴───────┬──────────────────┐
        │               │                    │                  │
  Media Service   Experience Service   Reactions Service   VPC Link (private)
  (Lambda)        (Lambda)             (Lambda)                 │
        │               │                    │             Internal ALB
        S3        DynamoDB, S3          DynamoDB                │
                  (post + delete)    (Likes table)       ECS Fargate: Feed Service
                                                                │
                                      DynamoDB (Experiences GSIs + Likes + LikeCounters)

  Async, not on the request path:
  Likes stream (INSERT/REMOVE) → Counter Lambda → LikeCounters table   (+ weekly Reconciliation Lambda)
  Experiences stream (INSERT) → Moderation Service (Lambda) → S3 (read) + Rekognition
                                        │ failures → SQS dead-letter queue
                                        └ redrive mapping (disabled until an operator enables it)
```

**WAF placement — deviation from the original diagram, decided during Phase 7:** originally drawn sitting directly in front of API Gateway. In practice, AWS WAF's `AssociateWebACL` does not support HTTP API (v2) stages as a resource type at all (only REST API stages, ALB, AppSync, Cognito pools, App Runner, Verified Access, Amplify) — confirmed against the live AWS API reference, not assumed. WAF is attached to CloudFront instead (`web_acl_id` directly on the distribution), which also means it now covers every path, not just `/api/*` — a strictly broader protection surface than originally planned, not a narrower one.

**Compute split rationale:**
- **Media, Experience, Reactions, Moderation, Counter & Reconciliation Services** — short, stateless, single-purpose (sign a URL, write or delete one post, toggle a like, check a post's images). No long-lived process needed, no VPC-only dependency. Lambda fits exactly; none runs inside a VPC. Moderation is the one that is not on a request path: it is triggered by the DynamoDB stream.
- **Feed Service** — the one service likely to benefit from a long-lived process (connection pooling, future in-memory caching). Runs on ECS Fargate behind an internal ALB to preserve native blue/green deployments.

---

## 3. Network Layer (VPC)

The VPC exists **only** to host Feed Service. Media and Experience never touch it.

- **Private subnets only**, across 2 Availability Zones. No public subnets, no Internet Gateway, no NAT Gateway — nothing inside needs to initiate outbound internet connections.
- **VPC interface endpoints:** ECR API, ECR DKR, CloudWatch Logs — let Fargate pull manifests, authenticate to the registry, and ship logs with no internet path.
- **VPC gateway endpoints (free):**
  - **DynamoDB** — keeps Feed Service reads off the public internet.
  - **S3** — required because ECR stores image *layers* in S3, not in ECR itself. Without this endpoint, Fargate task launches fail at the image-pull step. This is a hard functional dependency, not an optimization.
- **VPC Link** is the *only* path into this VPC from outside — it terminates at the internal ALB in front of Feed Service.
- **Verify endpoint routing in a lower environment before first prod deploy** — a missing route table association here is a silent, first-deploy-only failure mode.

---

## 4. Edge & Delivery Layer

- **Route 53** — hosted zone + alias record → CloudFront distribution.
- **CloudFront** — single entry point for all traffic, path-based behaviors:
  - `/*` → S3 frontend bucket, **cached**, serves built SPA assets.
  - `/api/*` → API Gateway, **not cached at any path** (dynamic, authenticated calls; allows `GET`, `PUT`, `POST`, `DELETE` and the rest). This includes `GET /api/feed`: a shared edge cache that ignores `Authorization` would serve the feed with no token required, and the feed is now per-caller anyway (`likedByMe`). See §12 for the decision and the safe upgrade path.
- **S3 frontend bucket** — private, reachable only via CloudFront through **Origin Access Control (OAC)**.
- **HTTPS enforced** at the CloudFront viewer level via ACM certificate.

---

## 5. API Layer (API Gateway)

**API Gateway (HTTP API)** is the single public entry point for every backend call and the one place auth is enforced — this is a deliberate architectural choice, not a default.

- **Cognito JWT authorizer** attached to `/api/*`. A bad or expired token never reaches Lambda or ECS.
- **Media, Experience & Reactions routes:** Lambda proxy integrations — API Gateway invokes the function directly. Routes with a path parameter (`/api/experiences/{experienceId}…`) are supported; the Lambda permission IDs strip the braces because Lambda statement IDs only allow `[A-Za-z0-9_-]`.
- **Feed route:** private integration over a **VPC Link**, terminating at the internal ALB. The integration **overwrites** an `x-user-sub` request header with the verified JWT's `sub` (`$context.authorizer.claims.sub`), so Feed Service knows the caller and a client cannot forge it; the ALB is reachable only through the VPC Link.

**Why not ALB alone / why not split entry points:** A hybrid Lambda+Fargate system needs auth and rate-limiting enforced consistently in one place. Splitting into "ALB for Feed, API Gateway for the rest" would require re-implementing JWT validation a second way at the ALB (Cognito's ALB integration is a browser-redirect flow, not a Bearer-token model, so it's a poor fit for an SPA) — two independent enforcement points for the same rule is a security liability, not a simplification. **API Gateway remains the single auth boundary for all three services.**

**Why HTTP API over REST API:** supports both Lambda proxy integrations and ALB-backed VPC Link integrations under one API, at lower cost, with no need for request/response transformation features neither service uses.

---

## 6. Security & Abuse Prevention

Authentication answers *who are you*; it does not answer *how many times per second are you allowed to do this*. These are separate concerns and must be solved separately.

| Threat | Mitigation |
|---|---|
| Scripted account creation + write flooding | **AWS WAF rate-based rules on CloudFront** (HTTP APIs cannot take a WAF — see §2): one keyed on the `Authorization` header value (approximates per-user without decoding the JWT), one keyed on IP for requests with no token. Limit is **300 requests / 5 min** (`waf_rate_limit`), raised from 50 so liking while scrolling does not trip it. Returns `429`. |
| Stolen/replayed JWT | Short-lived tokens (Cognito default expiry); WAF rate rule limits blast radius even if a token leaks. |
| Oversized/expensive write payloads | Application-level validation in Experience Service: cap `Description` length, enforce `Rating` ∈ [1,5], reject malformed bodies before the DynamoDB write. |
| DB overload despite the above | **DynamoDB on-demand billing mode**, not provisioned+autoscaling — autoscaling reacts in minutes, too slow for a burst. On-demand fails safe (costs money, doesn't fall over). |
| Spoofed `Content-Type` on upload | The presigned POST requires an **exact** `Content-Type` (`image/jpeg` or `image/png`), which is still client-asserted. The **Moderation Service** checks the real bytes (JPEG/PNG magic bytes) after the post is written and takes down anything else (`invalid_file_type`). |
| Abandoned/junk uploads (never claimed) | S3 lifecycle rule expires `status=pending` objects after ~48h (see §8). |

**Note on API Gateway's default throttling:** it protects at the route/stage level (overall volume), not per-user. The WAF layer above is what closes the per-user abuse gap — this is a deliberate addition on top of API Gateway defaults, not something API Gateway gives you out of the box.

---

## 7. Data & Storage Layer

### 7.1 DynamoDB
- Single-table design, `Experiences` table, **on-demand capacity mode**.
- Feed GSI `TypeCreatedAtIndex`: `Type` (PK) + `CreatedAt` (SK) drives chronological feed reads. `Type` is a **monthly bucket** (`POST#YYYY-MM`); Feed Service reads the current month first and walks back month by month to fill a page (bounded to 24 months). There is no feed cache (§12).
- Author GSI `userId-CreatedAt-index`: `userId` (PK) + `CreatedAt` (SK), projection `ALL`, used by "My posts" (`GET /api/feed?author=me`). A taken-down post has no `Type` so it is absent from the feed GSI, but it keeps `userId` so its author still sees it.
- Stream: `NEW_IMAGE`, consumed only by the Moderation Service, filtered to `INSERT`.
- Two more tables hold likes (§13.1): `Likes` (the rows) and `LikeCounters` (the derived counts).
- **Design invariants — the feed GSI is the one shared hot spot, so nothing frequent may write to it:**
  1. A post item is written only at **creation, takedown and delete**. Never for a like, an unlike, or a clean moderation result. A post that passes moderation gets no write at all; there is no stored "approved" status, and the absence of `removed` means the post is live.
  2. Likes and like counts live **only** in the `Likes` and `LikeCounters` tables. No like data is stored on, or projected from, a post item.
  3. Do not add frequently changing attributes to post items: the feed GSI projects `ALL`, so any attribute added to a post is copied into the index and every update to it becomes an index write.
- **Known limits and upgrade paths:** see §12 and §13.4 (single-post like rate, feed page loads on one GSI partition, new-post rate into the current month).

### 7.2 S3 — two buckets, explicitly separate
Two buckets with opposite security/lifecycle postures should never be merged:

| Bucket | Purpose | Access | Lifecycle |
|---|---|---|---|
| **Frontend bucket** | Built SPA assets | Private, OAC via CloudFront only | None — build artifacts, no expiration |
| **Uploads bucket** | User-uploaded images (full quality, no processing) | Written via presigned POST; served via CloudFront | `status=pending` objects expire after ~48h |

- Presigned **POST** (not PUT) — supports enforceable conditions PUT cannot:
  - `content-length-range` caps file size at the S3 level.
  - `eq $Content-Type` the requested type — `image/jpeg` or `image/png` only (`GET /api/media/upload-url?contentType=`; default `image/jpeg`; anything else is `400`). Rekognition reads only those two formats. Client-asserted; the Moderation Service verifies the real bytes (see §6).
  - Object key scoped to `{userId}/{uuid}.jpg` or `.png`, UUID generated once by Media Service at URL-issue time. Size cap is 10 MB, under Rekognition's 15 MB limit for S3-referenced images.
  - ~5 minute policy expiration.
- **Tag-based lifecycle, not blanket expiration** (the bucket is permanent storage, not staging):
  1. Presigned POST tags every new object `status=pending`.
  2. Experience Service, immediately after the DynamoDB write succeeds, updates the tag to `status=claimed`.
  3. Lifecycle rule expires objects still `status=pending` after ~48h — only ever catches genuinely abandoned uploads.

---

## 8. Deployment Strategy

### 8.1 Feed Service (ECS Fargate) — native blue/green
Uses **ECS's built-in blue/green deployment capability** (deployment controller type `ECS`, strategy `BLUE_GREEN` — no CodeDeploy dependency, this is a first-class ECS feature):
- New "green" task set stands up alongside "blue" while blue still serves traffic.
- Traffic shifts via the ALB's two target groups.
- **Bake time** window after full shift where instant rollback to blue is available before blue is torn down.
- **Deployment lifecycle hooks** (optional, recommended for later): Lambda functions invoked at defined stages (post scale-up, post traffic shift, etc.) that can run synthetic validation and return `SUCCEEDED`/`FAILED`/`IN_PROGRESS` to gate or roll back the deployment automatically.
- Requires the internal ALB with two target groups — this is structurally required for blue/green, not incidental cost.

**Image pull dependency:** every task launch (deploy, restart, scale event, cutover) requires a fresh ECR pull, which depends on both the ECR interface endpoints *and* the S3 gateway endpoint (§3). Verify in a lower environment before first prod deployment.

### 8.2 Lambda Services (Media, Experience, Reactions, Moderation, Counter, Reconciliation)
- Deploy via **versioned aliases** managed by Terraform. Each deploy publishes a new version and updates the alias.
- New functions get their **log group created in Terraform** (`manage_log_group`): the account's SCP rejects untagged `CreateLogGroup`, which is what Lambda's automatic creation sends, so without it the function silently has no logs.
- Traffic-shifted canary releases are a **future** Terraform-level config addition (weighted alias routing) — not needed for v1, not a rearchitecture when it's wanted.

### 8.3 Blue/green vs. canary — decision for v1
Blue/green (full flip with bake-time rollback) is the right amount of safety for current traffic volume. True percentage-based canary (5% → bake → 100%) only pays off once traffic is high enough for a 5% slice to be statistically meaningful. Not needed for v1; documented as an upgrade path, not a gap.

---

## 9. Observability

- **CloudWatch Logs** for all three services (Lambda logs natively; Fargate ships via the VPC interface endpoint).
- **CloudWatch Alarms** on: Lambda error rate/duration (all four Lambdas; moderation errors only, since its duration is dominated by Rekognition), ECS task health, ALB target group health, DynamoDB throttled requests on every table (`Likes` and `LikeCounters` included) **and on each `Experiences` index** (a throttled index also throttles base-table writes), WAF blocked-request rate, **moderation queue not empty** and **moderation stream falling behind** (`IteratorAge` > 5 min), plus for likes: **counter falling behind** (`IteratorAge` > 60 s), **like-counter queue not empty**, counter/reconciliation errors, and **count drift** (the weekly reconciliation's metric). Notifications go to the SNS email topic (plus a second us-east-1 topic for the WAF alarms).
- The Moderation Service writes one structured log line per decision: `experienceId`, `outcome` (`clean`, `removed`, `queued`), `reason`, `durationMs`.
- Alarm thresholds live in checked-in per-environment `.tfvars` (see §10) — changed only via reviewed PR, not ad hoc.
- Bake-time rollback decisions should be backed by an alarm or lifecycle-hook check, not manual observation, once traffic justifies it.

---

## 10. CI/CD Pipeline (Terraform)

- **All infrastructure in Terraform**, reusable modules (network, ALB, ECS service, Lambda, API Gateway, DynamoDB, S3, Cognito, WAF) composed per environment (`dev`, `staging`, `prod`).
- **Pipeline:** AWS CodePipeline, CodeBuild stages: application build → `terraform plan` → plan-review gate → `terraform apply`.
- **Feed Service** deploys via native ECS blue/green, configured directly on `aws_ecs_service` (`deployment_configuration { strategy = "BLUE_GREEN" }`).
- **Media/Experience Services** deploy via versioned Lambda aliases.
- **Per-apply variables only** for things that legitimately change every deploy (container image tag/digest, Lambda package version/hash) — injected via generated `*.auto.tfvars.json`.
- **Environment config** (CIDR ranges, task CPU/memory, bake time, alarm thresholds, WAF rate limits) lives in checked-in `.tfvars` per environment, changed only via reviewed PR. *(This project runs a single environment, so these are variable defaults in `infra/env/variables.tf` rather than per-environment files.)*
- **Account constraints (shared sandbox SCP):** every resource must carry `owner` and `environment` tags at creation (set once through `default_tags` on both AWS providers; an untagged `CreateQueue` or `CreateLogGroup` is denied), and the account allows only two CodeBuild projects, which is why the frontend deploy shares the `rateit-plan` project.

---

## 11. Build Sequence (Recommended Order)

Build bottom-up: foundation → simplest compute → most complex compute → edge → hardening → automation.

**Phase 0 — Terraform bootstrap**
Remote state backend (S3 + DynamoDB lock table), provider config, environment scaffolding (`dev`/`staging`/`prod`). Nothing else depends on this being right later.

**Phase 1 — Identity & foundation**
- Cognito User Pool + App Client (needed before anything can be authenticated).
- Baseline IAM roles/policies per service (least privilege from day one, not retrofitted).

**Phase 2 — Data layer**
- DynamoDB table + GSI (on-demand mode from the start).
- S3 buckets: uploads (with tagging/lifecycle config) and frontend (private, OAC-ready).

**Phase 3 — Lambda services (no VPC, fastest to stand up and test)**
- Media Service: presigned POST URL issuance. Test directly via Lambda invoke before wiring to API Gateway.
- Experience Service: DynamoDB write + S3 tag update. Test the same way.

**Phase 4 — API Gateway + write path live**
- HTTP API, Cognito JWT authorizer, Lambda proxy integrations for Media + Experience.
- **At this point you have a working authenticated upload+write path**, testable end-to-end without Feed Service or the frontend existing yet.

**Phase 5 — Feed Service (the more complex path — networking-heavy)**
- VPC (private subnets, all endpoints from §3), ECR repo, task definition, Fargate service, internal ALB, VPC Link.
- Wire the `GET /api/feed` route into API Gateway.
- Verify the ECR/S3 gateway endpoint image-pull dependency here, before this ever hits staging/prod.

**Phase 6 — Edge delivery**
- ACM cert, CloudFront distribution (both behaviors), Route 53 alias record.
- Deploy a real frontend build to the frontend bucket (coordinate with App PRD frontend sequence).

**Phase 7 — Abuse hardening**
- WAF rate-based rules, attached to **CloudFront** (not API Gateway — HTTP APIs cannot take a WAF), keyed on the `Authorization` header with an IP fallback.
- Confirm DynamoDB on-demand behavior under a simulated burst.
- ~~Add the CloudFront short-TTL cache on `/api/feed`~~ — **deliberately not built**, see §12.

**Phase 8 — CI/CD automation**
- CodePipeline/CodeBuild stages, ECS native blue/green wiring, Lambda alias deploy automation.
- Do this *after* the manual path works — automating a broken deploy path just automates the breakage.

**Phase 9 — Observability**
- CloudWatch alarms per §9, dashboards, bake-time gating.

**Phase 10 — Load & abuse testing, go-live checklist**
- Simulate the abuse patterns in §6 against staging. Confirm WAF actually blocks, confirm DynamoDB doesn't fall over, confirm blue/green rollback actually rolls back.

---

## 12. Open Items / Future Scaling Notes

- GSI hot-partition migration — **done**: the feed GSI is monthly-bucketed (§7.1). A finer shard suffix on `Type` remains the next step if one month's partition ever runs hot (requires rewriting existing values).
- ~~Magic-byte upload validation~~ — **done**, by the Moderation Service (§13.2).
- Weighted-alias Lambda canary — available when traffic justifies it, config-only addition.
- ECR pull-through cache — explicitly **not used**; noted only so it isn't confused with the S3 gateway endpoint requirement if the build process changes later.
- **`GET /api/feed` caching — deliberately not built, decided during Phase 7.** The originally-considered approach (CloudFront edge cache with a shared cache key that ignores `Authorization`, per this doc's §4) turns out to be a real, named vulnerability class (cacheable-authenticated-response / "web cache deception") — it would serve feed data with zero token required during the cache window, not just skip re-validating one user's token. The safe alternative (cache *after* the JWT authorizer — an in-process TTL cache in Feed Service, or DAX for a shared cache across multiple tasks) was evaluated and also rejected for now: it trades an immediately-noticeable cost (your own new post doesn't appear for up to the TTL window) for a benefit that doesn't exist yet — a burst test (200 concurrent `Query` calls) showed DynamoDB on-demand handles this table's load with zero throttling. **Trigger to revisit:** Feed Service scaled to multiple tasks with real concurrent traffic, or measured DynamoDB read cost/latency actually becoming a problem. Until then, `/api/feed` is uncached at every layer and authenticated on every single request.

---

## 13. Extension: Reactions, Moderation and Post Management

Full specification: `rateit-extension-prd.md`. This section records what is built.

### 13.1 Likes: Reactions Service, Counter, Reconciliation (Lambda, outside the VPC)
Redesigned after launch (`rateit-likes-redesign-prd.md`) so a like is one cheap write and no single post has a like-rate ceiling. **The public API is unchanged.**

- **`Likes` table** (on-demand, PITR, stream `KEYS_ONLY`): partition key `userId` (the liker's Cognito `sub`), sort key `experienceId`, plus `createdAt`. **The like row is the source of truth** and is written before the user gets a response. Keyed by user first so writes spread evenly. There is deliberately **no index on `experienceId`** (it would recreate the hot partition) — so the table cannot list who liked a post, and nothing needs that.
- **`LikeCounters` table** (on-demand, TTL on `expiresAt`): `pk = POST#<experienceId>` holds `likeCount`; `pk = BATCH#<batchId>#<chunk>` are 48-hour idempotency markers. A missing counter means zero likes.
- **Reactions Service** (256 MB, 5 s): **like** = a plain read of the post (missing or `removed` → `404`) then one `PutItem` into `Likes` with `attribute_not_exists(userId)`; a failed condition means already liked → `204`. **Unlike** = one `DeleteItem` with `attribute_exists(userId)`; failed condition → `204`. No transactions and no counts. A failed condition changes nothing, so it produces no stream event and can never be counted. Neither route writes to `Experiences` (invariant 1) — the earlier design's 2-write-unit `ConditionCheck` is gone. Routes: `PUT`/`DELETE /api/experiences/{experienceId}/like`.
- **Counter Lambda** (256 MB, 30 s): triggered by the `Likes` stream, `INSERT`/`REMOVE` only, batch 500 with a 2 s window, parallelization 1, 10 retries, 6 h max record age, failures to `rateit-like-counter-dlq`. It sums +1/−1 per post, drops net-zero posts, and applies the rest in one `TransactWriteItems` per ≤99 posts. Each transaction also writes a marker `BATCH#<hash of first eventID, last eventID, count>#<chunk>` (`attribute_not_exists`, put first), so a batch Lambda delivers twice is detected and applied zero additional times. **Batch bisecting and partial-batch responses are deliberately OFF**: the duplicate protection requires a retried batch to be identical to the original, and both features change its boundaries. Measured live: 200 simultaneous likes on one post became 9 counter updates and ended at exactly 200.
- **The count is derived and lags a like by about 2 s.** Feed Service reads the caller's like row (consistent) and the counter in one `BatchGetItem` (two keys per post, page size ≤ 50) and returns `likeCount = max(stored, likedByMe ? 1 : 0, 0)`, so the liker never sees a filled heart beside zero.
- **Reconciliation Lambda** (512 MB, 300 s): weekly (Saturday 21:00 UTC via EventBridge Scheduler, detect only) and invocable by hand. Detect compares real like rows with counters and publishes the `RateIt/Likes` `CountDrift` metric (0 when healthy); `{"repair": true}` applies `ADD` (actual − stored), never `SET`, so concurrent likes are not overwritten. It **ignores deleted posts** (their like rows outlive them) and reports a difference only if it is identical on two passes 10 s apart (so counter lag is not drift). A scan inside one Lambda is fine to a few million like rows; beyond that move to a DynamoDB export to S3.
- **Accepted trade-offs** (also in the README): deleting a post leaves its like rows behind (harmless, never read); no "who liked this" query; a counter can reappear — even briefly negative — if likes are still in the stream when its post is deleted (nothing reads it, and the feed clamps at 0).
- **Migration** was done live in one pass: new tables and Lambdas first, then the app switched over, then `scripts/one-off/likes-redesign/backfill_likes.py` copied the existing like rows (the Counter rebuilt the counts; reconciliation confirmed 0 drift). The old `Reactions` table was then removed in a separate apply, along with its throttling alarm.

### 13.2 Moderation Service (Lambda, outside the VPC) and the dead-letter queue
- One function, two triggers, told apart by `eventSource`. 512 MB, 60 s.
- **Stream mapping:** `INSERT` only (takedowns and deletes must not re-trigger), batch 10, 3 retries, bisect on error, max record age 1 h, `ReportBatchItemFailures`, on-failure destination = the queue, targets the `live` alias, starts at `LATEST` (so posts that existed before it was enabled are **not** moderated).
- **Per post:** for each image, check the first bytes are JPEG (`FF D8 FF`) or PNG (`89 50 4E 47 0D 0A 1A 0A`) — otherwise takedown `invalid_file_type` — then `DetectModerationLabels` at confidence 80. A post is flagged when a label falls under a blocked **top-level** category: `Explicit`, `Violence`, `Visually Disturbing`, `Hate Symbols` (configurable; names verified against the published taxonomy). Swimwear, alcohol, drugs, gambling, rude gestures and non-explicit nudity are deliberately allowed, since a review app legitimately shows bars and beaches.
- **Takedown** = one `UpdateItem`: `REMOVE Type`, set `removed`, `removedReason`, `removedAt`, conditioned on the post still existing (author deleted it first = success). A clean post gets **no write**.
- **Fails open.** Transient errors are retried 3× in the function; if still failing, or the failure is terminal (unreadable image, missing object) or an access error, the post stays visible and a message goes to the queue (`retryable` true/false), and the record counts as handled so one bad post cannot block the shard. Only if the queue send itself fails is the record reported as a batch failure.
- **Queue** `rateit-moderation-dlq`: standard, SSE on, 14-day retention, 360 s visibility. **Redrive mapping** (queue → function, batch 5) is created **disabled** on purpose; enabling it is an operator action (README runbook), and a later `terraform apply` resetting it to disabled is intended. The redrive path re-reads the post, skips it if deleted or already removed, and returns failures to the queue without re-queueing; Lambda's own stream-failure pointer messages (no `experienceId`) are logged at error level with their full body and dropped.

### 13.3 Post management and feed changes
- **Delete own post** (`DELETE /api/experiences/{experienceId}`, Experience Service, now 30 s): `GetItem` (`404` missing, `403` not yours), conditional `DeleteItem` (leaves both GSIs, so the post leaves the feed immediately), then best-effort deletion of the S3 objects and the post's `LikeCounters` row (its like rows are deliberately left, §13.1). A cleanup failure is logged with the `experienceId` and still returns `204`; leftovers are harmless orphans. The Experience Lambda is back to its default timeout, since delete no longer walks likes.
- **Feed Service** is two steps — `fetch_page` (identical for every caller; the cache seam) and `decorate` (one `BatchGetItem` spanning `Likes` and `LikeCounters`, two keys per post, so page size must stay ≤ 50) — and takes `author=me` (author GSI, taken-down posts included with `removed: true` and empty `imageUrls`).
- The global feed never contains removed posts. **Known limitation:** a removed post's images stay reachable through `/images/*` for anyone who already has the URL.

### 13.4 Capacity notes (none need action now)
| Limit | Rough ceiling | How to raise it later |
|---|---|---|
| Likes on a single post | Not limited per post (a like is one write to a per-user partition; counts are batched from the stream) | Already done — this is what the likes redesign (§13.1) delivered. One user can still like ~1,000/s, which no one reaches. |
| Feed page loads | ~1,200/s on one GSI partition | Wrap `fetch_page` in the post-authorizer cache described in §12. |
| New posts | Several hundred/s into the current month's partition | Add a shard suffix to the `Type` value (requires rewriting existing values). |
