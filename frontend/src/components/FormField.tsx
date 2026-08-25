import type { InputHTMLAttributes } from "react";

interface FormFieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
}

export function FormField({ label, id, className = "", ...props }: FormFieldProps) {
  const inputId = id ?? props.name;

  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={inputId} className="text-sm font-medium text-stone-700 dark:text-stone-300">
        {label}
      </label>
      <input
        id={inputId}
        className={`rounded-lg border border-stone-300 bg-white px-3 py-2 text-stone-900
          placeholder:text-stone-400 transition-colors
          focus:border-rose-600 focus:outline-none focus:ring-2 focus:ring-rose-600/30
          dark:border-stone-700 dark:bg-stone-900 dark:text-stone-100 ${className}`}
        {...props}
      />
    </div>
  );
}
