import type { InputHTMLAttributes } from "react";

interface FormFieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
}

export function FormField({ label, id, className = "", ...props }: FormFieldProps) {
  const inputId = id ?? props.name;

  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={inputId} className="text-sm font-medium text-neutral-700 dark:text-neutral-300">
        {label}
      </label>
      <input
        id={inputId}
        className={`rounded-lg border border-neutral-300 bg-white px-3 py-2 text-neutral-900
          placeholder:text-neutral-400 transition-colors
          focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500/30
          dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-100 ${className}`}
        {...props}
      />
    </div>
  );
}
