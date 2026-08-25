import { useAuth } from "../context/AuthContext";

export function AppHeader() {
  const { username, signOut } = useAuth();

  return (
    <header className="border-b border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
      <div className="mx-auto flex max-w-2xl items-center justify-between px-4 py-3">
        <span className="text-lg font-bold tracking-tight text-rose-700 dark:text-rose-400">
          RateIt
        </span>

        <div className="flex items-center gap-3">
          <span className="text-sm text-stone-600 dark:text-stone-400">{username}</span>
          <button
            onClick={signOut}
            className="rounded-lg px-3 py-1.5 text-sm font-medium text-stone-600 transition-colors
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
