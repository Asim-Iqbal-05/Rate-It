import { Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

export function AppHeader() {
  const { username, signOut } = useAuth();

  return (
    <header className="border-b border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
      <div className="mx-auto flex max-w-2xl items-center justify-between gap-2 px-4 py-3">
        <Link
          to="/"
          className="shrink-0 text-lg font-bold tracking-tight text-rose-700 dark:text-rose-400"
        >
          RateIt
        </Link>

        <div className="flex min-w-0 items-center gap-1.5 sm:gap-3">
          <Link
            to="/new"
            className="shrink-0 rounded-lg bg-rose-700 px-3 py-1.5 text-sm font-medium text-white transition-colors hover:bg-rose-800"
          >
            + New
          </Link>
          <span className="hidden min-w-0 truncate text-sm text-stone-600 dark:text-stone-400 sm:inline">
            {username}
          </span>
          <button
            onClick={signOut}
            className="shrink-0 rounded-lg px-3 py-1.5 text-sm font-medium text-stone-600 transition-colors
              hover:bg-stone-100 hover:text-stone-900
              dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-100"
          >
            Log out
          </button>
        </div>
      </div>
    </header>
  );
}
