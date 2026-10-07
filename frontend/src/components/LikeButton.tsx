import { useEffect, useRef, useState } from "react";
import { useAuth } from "../context/AuthContext";
import { NotFoundError, setLike, UnauthorizedError } from "../lib/api";

// Wait this long after the last tap before telling the server, so a
// burst of toggles becomes one request carrying only the final state.
const DEBOUNCE_MS = 500;
const MESSAGE_MS = 3000;

interface LikeButtonProps {
  experienceId: string;
  likedByMe: boolean;
  likeCount: number;
  /** The post no longer exists (the server said 404) - drop its card. */
  onGone: () => void;
}

export function LikeButton({ experienceId, likedByMe, likeCount, onGone }: LikeButtonProps) {
  const { getIdToken, signOut } = useAuth();

  // What the user sees (optimistic), vs. what the server last confirmed.
  const [liked, setLiked] = useState(likedByMe);
  const [count, setCount] = useState(likeCount);
  const [message, setMessage] = useState<string | null>(null);

  const confirmed = useRef({ liked: likedByMe, count: likeCount });
  const wanted = useRef(likedByMe);
  const timer = useRef<ReturnType<typeof setTimeout>>();
  const messageTimer = useRef<ReturnType<typeof setTimeout>>();
  const inFlight = useRef(false);
  const unmounted = useRef(false);

  useEffect(() => {
    unmounted.current = false;
    return () => {
      unmounted.current = true;
      clearTimeout(timer.current);
      clearTimeout(messageTimer.current);
    };
  }, []);

  // Reconcile with a fresh feed fetch - but never stomp on a tap the
  // server hasn't heard about yet.
  useEffect(() => {
    if (timer.current || inFlight.current) return;
    confirmed.current = { liked: likedByMe, count: likeCount };
    wanted.current = likedByMe;
    setLiked(likedByMe);
    setCount(likeCount);
  }, [likedByMe, likeCount]);

  const flash = (text: string) => {
    setMessage(text);
    clearTimeout(messageTimer.current);
    messageTimer.current = setTimeout(() => setMessage(null), MESSAGE_MS);
  };

  const revert = () => {
    wanted.current = confirmed.current.liked;
    setLiked(confirmed.current.liked);
    setCount(confirmed.current.count);
  };

  const send = async () => {
    timer.current = undefined;
    if (inFlight.current) return; // the in-flight request re-checks when it ends
    if (wanted.current === confirmed.current.liked) return;

    inFlight.current = true;
    const target = wanted.current;
    try {
      await setLike(getIdToken, experienceId, target);
      confirmed.current = {
        liked: target,
        count: confirmed.current.count + (target ? 1 : -1),
      };
    } catch (err) {
      inFlight.current = false;
      if (unmounted.current) return;
      if (err instanceof NotFoundError) {
        onGone();
      } else if (err instanceof UnauthorizedError) {
        signOut();
      } else {
        revert();
        flash(err instanceof Error ? err.message : "Could not update your like");
      }
      return;
    }
    inFlight.current = false;
    if (unmounted.current) return;
    // The user tapped again while that request was out.
    if (wanted.current !== confirmed.current.liked) {
      clearTimeout(timer.current);
      timer.current = setTimeout(send, DEBOUNCE_MS);
    }
  };

  const toggle = () => {
    const next = !wanted.current;
    wanted.current = next;
    setLiked(next);
    // Count shown = server's count with my like added or removed.
    setCount(confirmed.current.count + (next === confirmed.current.liked ? 0 : next ? 1 : -1));
    clearTimeout(timer.current);
    timer.current = setTimeout(send, DEBOUNCE_MS);
  };

  return (
    <div className="flex items-center gap-2">
      <button
        type="button"
        onClick={toggle}
        aria-pressed={liked}
        aria-label={liked ? "Unlike" : "Like"}
        className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-sm font-medium transition-colors
          focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700
          ${
            liked
              ? "bg-rose-50 text-rose-700 dark:bg-rose-950/40 dark:text-rose-400"
              : "text-stone-500 hover:bg-stone-100 dark:text-stone-400 dark:hover:bg-stone-800"
          }`}
      >
        <svg
          viewBox="0 0 24 24"
          className={`h-5 w-5 ${liked ? "fill-rose-600 stroke-rose-600" : "fill-none stroke-current"}`}
          strokeWidth="1.75"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M12 20.5s-7.5-4.6-9.2-9.4C1.6 7.6 3.6 4.5 6.9 4.5c2 0 3.5 1 5.1 3 1.6-2 3.1-3 5.1-3 3.3 0 5.3 3.1 4.1 6.6-1.7 4.8-9.2 9.4-9.2 9.4z" />
        </svg>
        <span aria-label={`${count} likes`}>{count}</span>
      </button>
      {message && (
        <span className="text-xs text-red-700 dark:text-red-400" role="status">
          {message}
        </span>
      )}
    </div>
  );
}
