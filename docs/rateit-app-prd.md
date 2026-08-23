# Application PRD: "RateIt"

**Status:** Draft v1
**Audience:** Frontend/product engineers
**Companion doc:** `rateit-infra-prd.md` (network, compute, deployment, security architecture)

This document covers **what the app does and how the frontend talks to the backend.** It assumes the infra in the companion doc exists and treats it as a black box behind three API endpoints.

---

## 1. Project Overview

"RateIt" is a lightweight web app that lets users upload a photo, write a brief review, and rate literally anything they experience — a weird park bench, a fantastic taco, a confusing street sign. The product surface is intentionally simple: log in, post something, see everyone else's posts.

---

## 2. Core Features

| Feature | Description |
|---|---|
| **Authentication** | Users must create an account and log in (Cognito-backed). The entire app, including viewing the feed, requires an authenticated session. |
| **Image Upload** | Users upload a single image directly from their device. Shown at full quality — no compression or resizing. |
| **Submit Experience** | Users write a text description, give a title, and provide a 1–5 star rating alongside their uploaded image. |
| **Global Feed** | Users view a chronological feed of all experiences posted by everyone on the platform. |

---

## 3. User Flows

### 3.1 Sign up / Log in
1. User lands on the app → redirected to login if no valid session.
2. Cognito-hosted or custom UI collects credentials.
3. On success, app receives a JWT (ID token / access token) and stores it in memory (not localStorage — see §6 security note).
4. Every subsequent API call sends `Authorization: Bearer <token>`.
5. Token refresh handled silently before expiry; on refresh failure, bounce to login.

### 3.2 Upload + Submit an Experience
1. User picks an image from their device.
2. Frontend calls `GET /api/media/upload-url` → receives a presigned S3 POST policy.
3. Frontend uploads the file **directly to S3** using that policy (never through the app's own backend).
4. On successful S3 upload, frontend shows the image preview inline with the form (title, description, star rating).
5. User fills in title/description/rating, hits submit.
6. Frontend calls `POST /api/experiences` with the image key + form data.
7. On success, show confirmation and route to the feed (or optimistically prepend the new post).
8. On failure, **do not** treat the image as posted — surface a retry, since the S3 object may now be an orphaned `pending`-tagged upload (harmless — it'll expire in ~48h server-side, but the user should know their post didn't go through).

### 3.3 View Feed
1. On load, frontend calls `GET /api/feed`.
2. Renders posts newest-first: image, title, description, rating, author, timestamp.
3. No filtering, sorting, search, pagination controls beyond "load more" if the API returns a pagination token (see §4.3) — keep it simple for v1.

---

## 4. API Contract

These are the three endpoints the frontend integrates against. All require `Authorization: Bearer <JWT>` except where noted; a missing/invalid token returns `401` before any application code runs.

### 4.1 `GET /api/media/upload-url`
Issues a short-lived, scoped S3 presigned POST policy.

**Response `200`:**
```json
{
  "url": "https://<bucket>.s3.amazonaws.com/",
  "fields": {
    "key": "{userId}/{uuid}.jpg",
    "Content-Type": "image/jpeg",
    "policy": "...",
    "x-amz-signature": "...",
    "...": "other S3 POST policy fields"
  },
  "imageKey": "{userId}/{uuid}.jpg"
}
```
- Frontend posts the actual file to `url` using `fields` as a multipart form, per standard S3 presigned POST usage.
- Policy expires in ~5 minutes — if the user stalls on the form, re-request before submitting.
- `imageKey` is what gets sent back in `POST /api/experiences` below.

### 4.2 `POST /api/experiences`
Persists the post.

**Request:**
```json
{
  "title": "Confusing street sign on 5th",
  "description": "Genuinely unclear if this means no parking or no walking.",
  "rating": 4,
  "imageKey": "{userId}/{uuid}.jpg"
}
```

**Response `201`:**
```json
{
  "experienceId": "uuid",
  "createdAt": "2026-08-21T10:15:00Z"
}
```

**Client-side validation before calling this endpoint** (mirrors server-side checks — see infra PRD §6):
- `title`: required, keep short (recommend enforcing a max length in the form itself).
- `description`: required, cap length client-side to match server-side cap.
- `rating`: integer 1–5, enforced by the star UI so an invalid value can't be sent.
- `imageKey`: must come from a completed §4.1 flow — don't allow submit without a successful S3 upload.

**Error responses to handle in the UI:**
- `400` — validation failure (show field-level errors).
- `401` — session expired mid-flow → refresh token or bounce to login, don't lose the user's typed text.
- `413` — payload too large.
- `429` — rate-limited (WAF). Show a generic "slow down and try again" message, don't expose the mechanism.

### 4.3 `GET /api/feed`
Returns the chronological global feed.

**Response `200`:**
```json
{
  "items": [
    {
      "experienceId": "uuid",
      "userId": "cognito-sub",
      "title": "...",
      "description": "...",
      "rating": 4,
      "imageUrl": "https://.../image.jpg",
      "createdAt": "2026-08-21T10:15:00Z"
    }
  ],
  "nextPageToken": "opaque-token-or-null"
}
```
- Newest first.
- If `nextPageToken` is present, a "load more" action can re-call with it; if the backend doesn't yet support pagination params, treat the first page as the whole feed for v1 and add this later — don't build UI for a capability the backend doesn't expose yet.
- This endpoint may be served from a CloudFront cache with a short TTL (10–30s) — the frontend doesn't need to know or care, but don't assume every call reflects the literal instant of the request.

---

## 5. Data Model (as consumed by the frontend)

Mirrors the backend `Experiences` table — the frontend should treat these as read-only fields it never constructs itself except where noted:

| Field | Type | Notes |
|---|---|---|
| `experienceId` | string | Server-generated, never set by client. |
| `userId` | string | Cognito `sub` of the author — use for "is this my post" checks. |
| `title` | string | Client-provided. |
| `description` | string | Client-provided. |
| `rating` | number | Client-provided, 1–5. |
| `imageUrl` | string | Server-resolved; frontend just renders it as an `<img>` src. |
| `createdAt` | string (ISO) | Server-generated, drives sort order. |

---

## 6. Non-Functional Requirements

- **Image quality:** uploads are shown exactly as uploaded — no client-side compression or resizing before upload (this is a deliberate product decision, not an oversight; see infra PRD §7.2). Do warn users if a file is very large before upload, since there's no server-side resize to fall back on.
- **Token storage:** keep JWTs in memory (or a secure httpOnly cookie if the auth flow supports it) — not `localStorage`, to reduce XSS token-theft exposure given there's no server-side session to revoke against.
- **Optimistic UI:** acceptable for feed prepend after a successful post, but always reconcile with the next real `GET /api/feed` call rather than trusting client state indefinitely.
- **Offline/slow network:** the upload step (§3.2) is the most failure-prone part of the flow — design the UI so a failed upload is clearly distinguishable from a failed submit, since they fail independently and the user needs different next actions for each.

---

## 7. Out of Scope (v1)

- Editing or deleting posts.
- Content moderation (automated or manual).
- User profiles or avatars.
- Comments, likes, or upvotes.
- Complex filtering (sort by rating, keyword search).
- Image compression/resizing.
- Per-user personalized feeds (relevant if you ever revisit the CloudFront caching strategy in the infra PRD).

---

## 8. Build Sequence (Frontend)

This assumes the infra Phase 4 (write path) and Phase 5 (feed path) from the infra PRD are done enough to hit against a `dev` environment — frontend work can start once those endpoints exist, even before CloudFront/production delivery (infra Phase 6) is wired up.

**Step 1 — Auth shell**
Login/signup screens wired to Cognito, token storage, protected-route wrapper, silent refresh. Nothing else in the app matters until this works, since every other screen sits behind it.

**Step 2 — Feed (read-only)**
Build the feed screen against `GET /api/feed` first, even with no way to post yet. This gets you a visible, testable screen early and validates the auth token is actually being accepted end-to-end.

**Step 3 — Upload flow**
Image picker → `GET /api/media/upload-url` → direct S3 POST → preview. Build and test this in isolation before wiring it into the submit form — the direct-to-S3 step is the one most likely to need debugging (CORS on the bucket, form field mismatches).

**Step 4 — Submit form**
Title/description/rating form → `POST /api/experiences`, using the `imageKey` from Step 3. Wire success to route back to the feed (Step 2) and prepend the new post optimistically.

**Step 5 — Error/edge states**
401 mid-session, 429 rate-limit messaging, failed upload vs. failed submit distinction (§6), large-file warning.

**Step 6 — Polish**
Loading states, empty feed state, responsive layout — once the functional path is fully working end-to-end.

Build in this order because each step is independently testable against a real backend without needing the next step to exist — you're never blocked waiting on a later piece to validate an earlier one.
