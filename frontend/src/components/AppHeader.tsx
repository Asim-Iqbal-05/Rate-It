import { useAuth } from "../context/AuthContext";

export function AppHeader() {
  const { username, signOut } = useAuth();

  return (
    <header className="border-b border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900">
      <div className="mx-auto flex max-w-2xl items-center justify-between px-4 py-3">
        <span className="text-lg font-bold tracking-tight text-indigo-600 dark:text-indigo-400">
          RateIt
        </span>

        <div className="flex items-center gap-3">
          <span className="text-sm text-neutral-600 dark:text-neutral-400">{username}</span>
          <button
            onClick={signOut}
            className="rounded-lg px-3 py-1.5 text-sm font-medium text-neutral-600 transition-colors
              hover:bg-neutral-100 hover:text-neutral-900
              dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
          >
            Log out
          </button>
        </div>
      </div>
    </header>
  );
}
