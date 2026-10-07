import { useState } from "react";
import { useAuth } from "../context/AuthContext";
import { deleteExperience, NotFoundError, UnauthorizedError } from "../lib/api";

interface DeletePostButtonProps {
  experienceId: string;
  /** The post is gone (deleted now, or already gone) - drop its card. */
  onDeleted: () => void;
}

// Two-step inline confirm rather than window.confirm: deleting is
// permanent (the post, its photos and its likes), and the native dialog
// can't be styled or reliably tested.
export function DeletePostButton({ experienceId, onDeleted }: DeletePostButtonProps) {
  const { getIdToken, signOut } = useAuth();
  const [confirming, setConfirming] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleDelete = async () => {
    setDeleting(true);
    setError(null);
    try {
      await deleteExperience(getIdToken, experienceId);
      onDeleted();
    } catch (err) {
      if (err instanceof NotFoundError) {
        onDeleted();
        return;
      }
      setDeleting(false);
      setConfirming(false);
      if (err instanceof UnauthorizedError) {
        signOut();
        return;
      }
      setError(err instanceof Error ? err.message : "Could not delete that post");
    }
  };

  if (!confirming) {
    return (
      <div className="flex items-center gap-2">
        {error && (
          <span className="text-xs text-red-700 dark:text-red-400" role="status">
            {error}
          </span>
        )}
        <button
          type="button"
          onClick={() => setConfirming(true)}
          className="rounded-lg px-2.5 py-1 text-sm font-medium text-stone-500 transition-colors
            hover:bg-stone-100 hover:text-red-700 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-red-400"
        >
          Delete
        </button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2 text-sm" role="alertdialog" aria-label="Confirm delete">
      <span className="text-stone-600 dark:text-stone-300">Delete this post?</span>
      <button
        type="button"
        onClick={() => setConfirming(false)}
        disabled={deleting}
        className="rounded-lg px-2.5 py-1 font-medium text-stone-600 hover:bg-stone-100 disabled:opacity-60 dark:text-stone-300 dark:hover:bg-stone-800"
      >
        Cancel
      </button>
      <button
        type="button"
        onClick={handleDelete}
        disabled={deleting}
        className="rounded-lg bg-red-700 px-2.5 py-1 font-medium text-white hover:bg-red-800 disabled:opacity-60"
      >
        {deleting ? "Deleting..." : "Delete"}
      </button>
    </div>
  );
}
