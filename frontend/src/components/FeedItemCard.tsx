import type { FeedItem } from "../lib/api";
import { formatRelativeTime } from "../lib/format";
import { ImageGallery } from "./ImageGallery";
import { StarRatingDisplay } from "./StarRatingDisplay";

export function FeedItemCard({ item }: { item: FeedItem }) {
  return (
    <article className="flex flex-col gap-3 rounded-xl border border-stone-200 bg-white p-4 shadow-sm dark:border-stone-800 dark:bg-stone-900">
      <ImageGallery urls={item.imageUrls} alt={item.title} />

      <div className="flex items-start justify-between gap-2">
        <h2 className="font-semibold text-stone-900 dark:text-stone-100">{item.title}</h2>
        <StarRatingDisplay rating={item.rating} />
      </div>

      <p className="text-sm text-stone-600 dark:text-stone-400">{item.description}</p>

      <time
        dateTime={item.createdAt}
        className="text-xs text-stone-400 dark:text-stone-500"
        title={new Date(item.createdAt).toLocaleString()}
      >
        {formatRelativeTime(item.createdAt)}
      </time>
    </article>
  );
}
