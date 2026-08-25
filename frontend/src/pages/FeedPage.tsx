import { useEffect, useState } from "react";
import { useAuth } from "../context/AuthContext";
import { getFeed, UnauthorizedError, type FeedItem } from "../lib/api";
import { AppHeader } from "../components/AppHeader";
import { FeedItemCard } from "../components/FeedItemCard";
import { Alert } from "../components/Alert";
import { Button } from "../components/Button";

export function FeedPage() {
  const { getIdToken, signOut } = useAuth();

  const [items, setItems] = useState<FeedItem[]>([]);
  const [nextPageToken, setNextPageToken] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = async (pageToken?: string) => {
    try {
      const result = await getFeed(getIdToken, pageToken);
      setItems((prev) => (pageToken ? [...prev, ...result.items] : result.items));
      setNextPageToken(result.nextPageToken);
      setError(null);
    } catch (err) {
      if (err instanceof UnauthorizedError) {
        // No form state to lose here (this is a read-only screen) -
        // signing out flips ProtectedRoute to redirect to /login.
        signOut();
        return;
      }
      setError(err instanceof Error ? err.message : "Could not load the feed");
    }
  };

  useEffect(() => {
    setLoading(true);
    load().finally(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleLoadMore = async () => {
    if (!nextPageToken) return;
    setLoadingMore(true);
    await load(nextPageToken);
    setLoadingMore(false);
  };

  return (
    <div className="min-h-screen bg-stone-50 dark:bg-stone-950">
      <AppHeader />
      <main className="mx-auto max-w-lg px-4 py-8">
        {loading && (
          <div className="flex justify-center py-16">
            <svg className="h-6 w-6 animate-spin text-rose-700 dark:text-rose-400" viewBox="0 0 24 24" fill="none">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" />
            </svg>
          </div>
        )}

        {!loading && error && <Alert variant="error">{error}</Alert>}

        {!loading && !error && items.length === 0 && (
          <p className="py-16 text-center text-stone-500 dark:text-stone-400">
            Nothing posted yet - be the first to rate something.
          </p>
        )}

        {!loading && items.length > 0 && (
          <div className="flex flex-col gap-4">
            {items.map((item) => (
              <FeedItemCard key={item.experienceId} item={item} />
            ))}

            {nextPageToken && (
              <Button
                type="button"
                onClick={handleLoadMore}
                loading={loadingMore}
                className="mx-auto mt-2"
              >
                {loadingMore ? "Loading..." : "Load more"}
              </Button>
            )}
          </div>
        )}
      </main>
    </div>
  );
}
