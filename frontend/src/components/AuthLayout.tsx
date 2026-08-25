import type { ReactNode } from "react";

export function AuthLayout({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
}) {
  return (
    <div
      className="flex min-h-screen items-center justify-center px-4 py-12
        bg-[radial-gradient(circle_at_top,_theme(colors.rose.100),_theme(colors.stone.50)_60%)]
        dark:bg-[radial-gradient(circle_at_top,_theme(colors.rose.950),_theme(colors.stone.950)_60%)]"
    >
      <div className="w-full max-w-sm">
        <div className="mb-8 text-center">
          <span className="text-2xl font-bold tracking-tight text-rose-700 dark:text-rose-400">
            RateIt
          </span>
        </div>

        <div className="rounded-2xl border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-800 dark:bg-stone-900">
          <h1 className="text-xl font-semibold text-stone-900 dark:text-stone-100">{title}</h1>
          {subtitle && (
            <p className="mt-1 text-sm text-stone-500 dark:text-stone-400">{subtitle}</p>
          )}
          <div className="mt-6">{children}</div>
        </div>
      </div>
    </div>
  );
}
