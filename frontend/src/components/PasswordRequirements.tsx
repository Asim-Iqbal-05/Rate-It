// Mirrors the Cognito user pool's actual password policy (infra
// modules/cognito/main.tf) so the frontend never asks for something
// the backend doesn't, or lets through something it'll reject.
const RULES: { label: string; test: (password: string) => boolean }[] = [
  { label: "At least 8 characters", test: (p) => p.length >= 8 },
  { label: "One uppercase letter", test: (p) => /[A-Z]/.test(p) },
  { label: "One lowercase letter", test: (p) => /[a-z]/.test(p) },
  { label: "One number", test: (p) => /[0-9]/.test(p) },
];

export function PasswordRequirements({ password }: { password: string }) {
  return (
    <ul className="flex flex-col gap-1 text-xs">
      {RULES.map(({ label, test }) => {
        const met = test(password);
        return (
          <li
            key={label}
            className={`flex items-center gap-1.5 transition-colors ${
              met ? "text-emerald-600 dark:text-emerald-400" : "text-stone-400 dark:text-stone-500"
            }`}
          >
            <svg viewBox="0 0 20 20" fill="currentColor" className="h-3.5 w-3.5 shrink-0" aria-hidden="true">
              {met ? (
                <path
                  fillRule="evenodd"
                  d="M16.704 5.29a1 1 0 010 1.415l-7.5 7.5a1 1 0 01-1.414 0l-3.5-3.5a1 1 0 111.414-1.414l2.793 2.792 6.793-6.793a1 1 0 011.414 0z"
                  clipRule="evenodd"
                />
              ) : (
                <circle cx="10" cy="10" r="3" />
              )}
            </svg>
            {label}
          </li>
        );
      })}
    </ul>
  );
}
