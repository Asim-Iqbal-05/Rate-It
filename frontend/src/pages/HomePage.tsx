import { AppHeader } from "../components/AppHeader";

// Placeholder for the real feed screen (app PRD §8 Step 2) - this page
// only exists to prove the auth shell works end-to-end: if you can see
// this, your token was accepted and the protected route held.
export function HomePage() {
  return (
    <div className="min-h-screen bg-stone-50 dark:bg-stone-950">
      <AppHeader />
      <main className="mx-auto max-w-2xl px-4 py-16 text-center">
        <p className="text-stone-500 dark:text-stone-400">
          The feed screen isn&apos;t built yet - this page just confirms the auth shell works.
        </p>
      </main>
    </div>
  );
}
