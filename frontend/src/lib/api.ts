const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

export class UnauthorizedError extends Error {}
export class RateLimitedError extends Error {}
export class NotFoundError extends Error {}

/**
 * Fetch wrapper for the RateIt API. Attaches the bearer token and
 * throws UnauthorizedError on a 401 so callers (or a top-level
 * boundary) can bounce to login without losing typed-in form state -
 * app PRD §4.2 "session expired mid-flow".
 */
export async function apiFetch(
  path: string,
  getIdToken: () => Promise<string | null>,
  options: RequestInit = {},
): Promise<Response> {
  const idToken = await getIdToken();
  if (!idToken) {
    throw new UnauthorizedError("No active session");
  }

  const response = await fetch(`${API_BASE_URL}${path}`, {
    ...options,
    headers: {
      ...options.headers,
      Authorization: `Bearer ${idToken}`,
      "Content-Type": "application/json",
    },
  });

  if (response.status === 401) {
    throw new UnauthorizedError("Session expired");
  }

  // WAF's rate limiting (infra PRD §7) can hit any endpoint, not just
  // submit - centralized here so every caller gets the same friendly
  // message instead of duplicating this check per API function.
  if (response.status === 429) {
    throw new RateLimitedError("Too many requests - slow down and try again.");
  }

  return response;
}

export class ValidationApiError extends Error {
  field: string;
  constructor(field: string, message: string) {
    super(message);
    this.field = field;
  }
}

export interface UploadUrlResponse {
  url: string;
  fields: Record<string, string>;
  imageKey: string;
}

// Rekognition (moderation) only reads JPEG and PNG, so those are the
// only upload types the backend issues URLs for (extension PRD §7.5).
// Mirrors ALLOWED_CONTENT_TYPES in services/media/handler.py - keep in sync.
export const ALLOWED_IMAGE_TYPES = ["image/jpeg", "image/png"];

export async function getUploadUrl(
  getIdToken: () => Promise<string | null>,
  contentType: string,
): Promise<UploadUrlResponse> {
  const res = await apiFetch(
    `/api/media/upload-url?contentType=${encodeURIComponent(contentType)}`,
    getIdToken,
    { method: "GET" },
  );
  if (!res.ok) {
    throw new Error("Could not get an upload URL");
  }
  return res.json();
}

/**
 * Direct browser-to-S3 upload (app PRD §3.2) - never goes through our
 * own backend. Field order matters for S3's POST policy: the "file"
 * part must come last, matching the order verified working during
 * Phase 3's manual curl test.
 */
export async function uploadImageToS3(
  { url, fields }: UploadUrlResponse,
  file: File,
): Promise<void> {
  const formData = new FormData();
  for (const [key, value] of Object.entries(fields)) {
    formData.append(key, value);
  }
  // The S3 POST policy requires Content-Type to equal the type the upload
  // URL was requested for. The server includes it in `fields` once it
  // enforces that; until then (and as a fallback) send the file's own
  // type, which is the same value the URL was requested with.
  if (!("Content-Type" in fields)) {
    formData.append("Content-Type", file.type);
  }
  formData.append("file", file);

  const res = await fetch(url, { method: "POST", body: formData });
  if (!res.ok) {
    // Surface S3's actual reason (e.g. a specific policy condition
    // that failed, or an expired upload URL) instead of a generic
    // message - the difference matters for diagnosing failures we
    // can't easily reproduce locally (e.g. mobile-only issues).
    const body = await res.text().catch(() => "");
    const message = /<Message>(.*?)<\/Message>/.exec(body)?.[1];
    console.error("S3 upload failed", res.status, body);
    throw new Error(message ? `Upload failed: ${message}` : "Image upload failed");
  }
}

export interface FeedItem {
  experienceId: string;
  userId: string;
  title: string;
  description: string;
  rating: number;
  imageUrls: string[];
  createdAt: string;
  likeCount: number;
  likedByMe: boolean;
  /** True only for the caller's own taken-down posts, in the "My posts" view. */
  removed: boolean;
}

export interface FeedResponse {
  items: FeedItem[];
  nextPageToken: string | null;
}

export async function getFeed(
  getIdToken: () => Promise<string | null>,
  options: { pageToken?: string; author?: "me" } = {},
): Promise<FeedResponse> {
  const params = new URLSearchParams();
  if (options.pageToken) params.set("pageToken", options.pageToken);
  if (options.author) params.set("author", options.author);
  const query = params.size > 0 ? `?${params}` : "";
  const res = await apiFetch(`/api/feed${query}`, getIdToken, { method: "GET" });
  if (!res.ok) {
    throw new Error("Could not load the feed");
  }
  return res.json();
}

/**
 * Sets the caller's like on a post to the given state. Idempotent on the
 * server, so it is safe to send the final state after a burst of toggles.
 * A 404 means the post no longer exists (deleted or taken down).
 */
export async function setLike(
  getIdToken: () => Promise<string | null>,
  experienceId: string,
  liked: boolean,
): Promise<void> {
  const res = await apiFetch(`/api/experiences/${experienceId}/like`, getIdToken, {
    method: liked ? "PUT" : "DELETE",
  });
  if (res.status === 404) throw new NotFoundError("Post not found");
  if (!res.ok) throw new Error("Could not update your like");
}

export async function deleteExperience(
  getIdToken: () => Promise<string | null>,
  experienceId: string,
): Promise<void> {
  const res = await apiFetch(`/api/experiences/${experienceId}`, getIdToken, {
    method: "DELETE",
  });
  // Already gone is the outcome the user wanted - callers treat it like success.
  if (res.status === 404) throw new NotFoundError("Post not found");
  if (res.status === 403) throw new Error("You can only delete your own posts.");
  if (!res.ok) throw new Error("Could not delete that post");
}

export interface CreateExperienceInput {
  title: string;
  description: string;
  rating: number;
  imageKeys: string[];
}

export interface CreateExperienceResponse {
  experienceId: string;
  createdAt: string;
}

export async function createExperience(
  getIdToken: () => Promise<string | null>,
  input: CreateExperienceInput,
): Promise<CreateExperienceResponse> {
  const res = await apiFetch("/api/experiences", getIdToken, {
    method: "POST",
    body: JSON.stringify(input),
  });

  if (res.status === 400) {
    const body = await res.json().catch(() => null);
    throw new ValidationApiError(body?.error?.field ?? "form", body?.error?.message ?? "Invalid input");
  }
  if (res.status === 413) {
    throw new Error("That image is too large.");
  }
  if (!res.ok) {
    throw new Error("Could not create post");
  }

  return res.json();
}
