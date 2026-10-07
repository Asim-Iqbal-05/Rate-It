import { useEffect, useState } from "react";
import { useAuth } from "../context/AuthContext";
import { getFeed, UnauthorizedError, type FeedItem } from "../lib/api";
import { AppHeader } from "../components/AppHeader";
import { FeedItemCard } from "../components/FeedItemCard";
import { Alert } from "../components/Alert";
import { Button } from "../components/Button";

export function FeedPage() {
  const { getIdToken, signOut, userId } = useAuth();

  const [view, setView] = useState<"all" | "mine">("all");
  const [items, setItems] = useState<FeedItem[]>([]);
  const [nextPageToken, setNextPageToken] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = async (pageToken?: string) => {
    try {
      const result = await getFeed(getIdToken, {
        pageToken,
        author: view === "mine" ? "me" : undefined,
      });
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

  // Switching views starts a fresh list - tokens from one view mean
  // nothing to the other.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setItems([]);
    setNextPageToken(null);
    load().finally(() => {
      if (!cancelled) setLoading(false);
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view]);

  const handleGone = (experienceId: string) => {
    setItems((prev) => prev.filter((item) => item.experienceId !== experienceId));
  };

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
        <div className="mb-5 flex gap-1 rounded-lg bg-stone-200/60 p-1 dark:bg-stone-800/60" role="tablist">
          {(
            [
              ["all", "All posts"],
              ["mine", "My posts"],
            ] as const
          ).map(([key, label]) => (
            <button
              key={key}
              type="button"
              role="tab"
              aria-selected={view === key}
              onClick={() => setView(key)}
              className={`flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
                view === key
                  ? "bg-white text-rose-700 shadow-sm dark:bg-stone-900 dark:text-rose-400"
                  : "text-stone-600 hover:text-stone-900 dark:text-stone-400 dark:hover:text-stone-100"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

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
            {view === "mine"
              ? "You haven't posted anything yet."
              : "Nothing posted yet - be the first to rate something."}
          </p>
        )}

        {!loading && items.length > 0 && (
          <div className="flex flex-col gap-4">
            {items.map((item) => (
              <FeedItemCard
                key={item.experienceId}
                item={item}
                isOwner={item.userId === userId}
                onGone={handleGone}
              />
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
