const VARIANT_CLASSES = {
  error:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/50 dark:bg-red-950/40 dark:text-red-400",
  info: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/50 dark:bg-emerald-950/40 dark:text-emerald-400",
};

export function Alert({ variant, children }: { variant: "error" | "info"; children: string }) {
  return (
    <p className={`rounded-lg border px-3 py-2 text-sm ${VARIANT_CLASSES[variant]}`} role="status">
      {children}
    </p>
  );
}
