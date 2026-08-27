const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

export class UnauthorizedError extends Error {}
export class RateLimitedError extends Error {}

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

export async function getUploadUrl(
  getIdToken: () => Promise<string | null>,
): Promise<UploadUrlResponse> {
  const res = await apiFetch("/api/media/upload-url", getIdToken, { method: "GET" });
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
  formData.append("Content-Type", file.type);
  formData.append("file", file);

  const res = await fetch(url, { method: "POST", body: formData });
  if (!res.ok) {
    throw new Error("Image upload failed");
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
}

export interface FeedResponse {
  items: FeedItem[];
  nextPageToken: string | null;
}

export async function getFeed(
  getIdToken: () => Promise<string | null>,
  pageToken?: string,
): Promise<FeedResponse> {
  const query = pageToken ? `?pageToken=${encodeURIComponent(pageToken)}` : "";
  const res = await apiFetch(`/api/feed${query}`, getIdToken, { method: "GET" });
  if (!res.ok) {
    throw new Error("Could not load the feed");
  }
  return res.json();
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
