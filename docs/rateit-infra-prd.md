# Infrastructure PRD: "RateIt"

**Status:** Draft v1
**Audience:** Platform/infra engineers, DevOps, SRE
**Companion doc:** `rateit-app-prd.md` (product features, API contracts, frontend flows)
**Compute model:** Hybrid — Lambda for stateless write/utility endpoints, ECS Fargate for the read-heavy feed service, unified behind a single API Gateway.

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
   ├── /*      → S3 frontend bucket (private, OAC-only)
   └── /api/*  → API Gateway (HTTP API)
                     │
              WAF (rate-based rules: per-user sub, per-IP)
                     │
              Cognito JWT Authorizer (validates bearer token)
                     │
        ┌────────────┼────────────────────┐
        │            │                    │
  Media Service  Experience Service   VPC Link (private)
  (Lambda)       (Lambda)                  │
        │            │              Internal ALB
        S3       DynamoDB, S3            │
                                    ECS Fargate: Feed Service
                                          │
                                     DynamoDB (GSI)
```

**Compute split rationale:**
- **Media & Experience Services** — short, stateless, single-purpose (sign a URL, write one record). No long-lived process needed, no VPC-only dependency. Lambda fits exactly; neither runs inside a VPC.
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
  - `/api/*` → API Gateway, **not cached** by default (dynamic, authenticated calls) — **except** `GET /api/feed`, which should get a short TTL (10–30s). The feed is identical for every user in v1 (no personalization), so this single cache setting removes the majority of read load from DynamoDB for free. Revisit if per-user feeds are ever introduced.
- **S3 frontend bucket** — private, reachable only via CloudFront through **Origin Access Control (OAC)**.
- **HTTPS enforced** at the CloudFront viewer level via ACM certificate.

---

## 5. API Layer (API Gateway)

**API Gateway (HTTP API)** is the single public entry point for every backend call and the one place auth is enforced — this is a deliberate architectural choice, not a default.

- **Cognito JWT authorizer** attached to `/api/*`. A bad or expired token never reaches Lambda or ECS.
- **Media & Experience routes:** Lambda proxy integrations — API Gateway invokes the function directly.
- **Feed route:** private integration over a **VPC Link**, terminating at the internal ALB.

**Why not ALB alone / why not split entry points:** A hybrid Lambda+Fargate system needs auth and rate-limiting enforced consistently in one place. Splitting into "ALB for Feed, API Gateway for the rest" would require re-implementing JWT validation a second way at the ALB (Cognito's ALB integration is a browser-redirect flow, not a Bearer-token model, so it's a poor fit for an SPA) — two independent enforcement points for the same rule is a security liability, not a simplification. **API Gateway remains the single auth boundary for all three services.**

**Why HTTP API over REST API:** supports both Lambda proxy integrations and ALB-backed VPC Link integrations under one API, at lower cost, with no need for request/response transformation features neither service uses.

---

## 6. Security & Abuse Prevention

Authentication answers *who are you*; it does not answer *how many times per second are you allowed to do this*. These are separate concerns and must be solved separately.

| Threat | Mitigation |
|---|---|
| Scripted account creation + write flooding | **AWS WAF rate-based rule on API Gateway**, keyed on the Cognito `sub` claim (falls back to IP for unauthenticated abuse). e.g. block for 5 min if >50 requests/5min from one user. |
| Stolen/replayed JWT | Short-lived tokens (Cognito default expiry); WAF rate rule limits blast radius even if a token leaks. |
| Oversized/expensive write payloads | Application-level validation in Experience Service: cap `Description` length, enforce `Rating` ∈ [1,5], reject malformed bodies before the DynamoDB write. |
| DB overload despite the above | **DynamoDB on-demand billing mode**, not provisioned+autoscaling — autoscaling reacts in minutes, too slow for a burst. On-demand fails safe (costs money, doesn't fall over). |
| Spoofed `Content-Type` on upload | Soft check only in v1 (S3 presigned POST condition is client-asserted). Documented residual risk — see §8. Upgrade path: magic-byte validation in Experience Service at claim time. |
| Abandoned/junk uploads (never claimed) | S3 lifecycle rule expires `status=pending` objects after ~48h (see §8). |

**Note on API Gateway's default throttling:** it protects at the route/stage level (overall volume), not per-user. The WAF layer above is what closes the per-user abuse gap — this is a deliberate addition on top of API Gateway defaults, not something API Gateway gives you out of the box.

---

## 7. Data & Storage Layer

### 7.1 DynamoDB
- Single-table design, `Experiences` table, **on-demand capacity mode**.
- GSI: `Type` (PK, currently constant `"POST"`) + `CreatedAt` (SK) drives chronological feed reads.
- **Known scaling limitation (accepted for v1):** the constant GSI partition key means all writes *and* all feed reads hit one logical partition. Mitigated in v1 by the CloudFront cache on `/api/feed` (§4), which absorbs most read traffic before it reaches the GSI.
- **Documented migration trigger:** if GSI consumed capacity approaches the per-partition ceiling, or feed p99 latency degrades, migrate to time-bucketed keys (`POST#2026-08` style), with Feed Service reading the current bucket first and falling back to the previous one to fill a page. Feed Service should already read via the GSI with a bounded `Limit` + pagination token so this migration is a query-layer change only, not a data-model rewrite.

### 7.2 S3 — two buckets, explicitly separate
Two buckets with opposite security/lifecycle postures should never be merged:

| Bucket | Purpose | Access | Lifecycle |
|---|---|---|---|
| **Frontend bucket** | Built SPA assets | Private, OAC via CloudFront only | None — build artifacts, no expiration |
| **Uploads bucket** | User-uploaded images (full quality, no processing) | Written via presigned POST; served via CloudFront | `status=pending` objects expire after ~48h |

- Presigned **POST** (not PUT) — supports enforceable conditions PUT cannot:
  - `content-length-range` caps file size at the S3 level.
  - `starts-with $Content-Type image/` — soft check (client-asserted, spoofable — see §6).
  - Object key scoped to `{userId}/{uuid}.jpg`, UUID generated once by Media Service at URL-issue time.
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

### 8.2 Media & Experience Services (Lambda)
- Deploy via **versioned aliases** managed by Terraform. Each deploy publishes a new version and updates the alias.
- Traffic-shifted canary releases are a **future** Terraform-level config addition (weighted alias routing) — not needed for v1, not a rearchitecture when it's wanted.

### 8.3 Blue/green vs. canary — decision for v1
Blue/green (full flip with bake-time rollback) is the right amount of safety for current traffic volume. True percentage-based canary (5% → bake → 100%) only pays off once traffic is high enough for a 5% slice to be statistically meaningful. Not needed for v1; documented as an upgrade path, not a gap.

---

## 9. Observability

- **CloudWatch Logs** for all three services (Lambda logs natively; Fargate ships via the VPC interface endpoint).
- **CloudWatch Alarms** on: Lambda error rate/duration, ECS task health, ALB target group health, DynamoDB throttled requests, WAF blocked-request rate.
- Alarm thresholds live in checked-in per-environment `.tfvars` (see §10) — changed only via reviewed PR, not ad hoc.
- Bake-time rollback decisions should be backed by an alarm or lifecycle-hook check, not manual observation, once traffic justifies it.

---

## 10. CI/CD Pipeline (Terraform)

- **All infrastructure in Terraform**, reusable modules (network, ALB, ECS service, Lambda, API Gateway, DynamoDB, S3, Cognito, WAF) composed per environment (`dev`, `staging`, `prod`).
- **Pipeline:** AWS CodePipeline, CodeBuild stages: application build → `terraform plan` → plan-review gate → `terraform apply`.
- **Feed Service** deploys via native ECS blue/green, configured directly on `aws_ecs_service` (`deployment_configuration { strategy = "BLUE_GREEN" }`).
- **Media/Experience Services** deploy via versioned Lambda aliases.
- **Per-apply variables only** for things that legitimately change every deploy (container image tag/digest, Lambda package version/hash) — injected via generated `*.auto.tfvars.json`.
- **Environment config** (CIDR ranges, task CPU/memory, bake time, alarm thresholds, WAF rate limits) lives in checked-in `.tfvars` per environment, changed only via reviewed PR.

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
- WAF rate-based rule on API Gateway, keyed on `sub`.
- Confirm DynamoDB on-demand behavior under a simulated burst.
- Add the CloudFront short-TTL cache on `/api/feed`.

**Phase 8 — CI/CD automation**
- CodePipeline/CodeBuild stages, ECS native blue/green wiring, Lambda alias deploy automation.
- Do this *after* the manual path works — automating a broken deploy path just automates the breakage.

**Phase 9 — Observability**
- CloudWatch alarms per §9, dashboards, bake-time gating.

**Phase 10 — Load & abuse testing, go-live checklist**
- Simulate the abuse patterns in §6 against staging. Confirm WAF actually blocks, confirm DynamoDB doesn't fall over, confirm blue/green rollback actually rolls back.

---

## 12. Open Items / Future Scaling Notes

- GSI hot-partition migration (time-bucketed keys) — trigger defined in §7.1, not built until triggered.
- Magic-byte upload validation — optional hardening beyond v1 soft `Content-Type` check.
- Weighted-alias Lambda canary — available when traffic justifies it, config-only addition.
- ECR pull-through cache — explicitly **not used**; noted only so it isn't confused with the S3 gateway endpoint requirement if the build process changes later.
