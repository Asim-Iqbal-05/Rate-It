import { STAR_PATH } from "./StarRatingInput";

export function StarRatingDisplay({ rating }: { rating: number }) {
  return (
    <div className="flex gap-0.5" aria-label={`${rating} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((star) => (
        <svg
          key={star}
          viewBox="0 0 20 20"
          className={`h-4 w-4 ${star <= rating ? "fill-amber-400" : "fill-stone-200 dark:fill-stone-700"}`}
          aria-hidden="true"
        >
          <path d={STAR_PATH} />
        </svg>
      ))}
    </div>
  );
}
