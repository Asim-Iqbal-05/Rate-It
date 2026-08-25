const API_BASE_URL = import.meta.env.VITE_API_BASE_URL;

export class UnauthorizedError extends Error {}

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

  return response;
}
