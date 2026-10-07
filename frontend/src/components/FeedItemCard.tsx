import type { FeedItem } from "../lib/api";
import { formatRelativeTime } from "../lib/format";
import { DeletePostButton } from "./DeletePostButton";
import { ImageGallery } from "./ImageGallery";
import { LikeButton } from "./LikeButton";
import { StarRatingDisplay } from "./StarRatingDisplay";

interface FeedItemCardProps {
  item: FeedItem;
  /** True when the signed-in user wrote this post. */
  isOwner: boolean;
  /** The post is gone (deleted, or the server says it no longer exists). */
  onGone: (experienceId: string) => void;
}

export function FeedItemCard({ item, isOwner, onGone }: FeedItemCardProps) {
  return (
    <article className="flex flex-col gap-3 rounded-xl border border-stone-200 bg-white p-4 shadow-sm dark:border-stone-800 dark:bg-stone-900">
      {item.removed ? (
        <div className="flex aspect-video w-full flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-stone-300 bg-stone-50 px-4 text-center dark:border-stone-700 dark:bg-stone-800/50">
          <span className="text-sm font-medium text-stone-700 dark:text-stone-200">
            Removed by moderation
          </span>
          <span className="text-xs text-stone-500 dark:text-stone-400">
            This post isn't visible to anyone else.
          </span>
        </div>
      ) : (
        <ImageGallery urls={item.imageUrls} alt={item.title} />
      )}

      <div className="flex items-start justify-between gap-2">
        <h2 className="font-semibold text-stone-900 dark:text-stone-100">{item.title}</h2>
        <StarRatingDisplay rating={item.rating} />
      </div>

      <p className="text-sm text-stone-600 dark:text-stone-400">{item.description}</p>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <time
          dateTime={item.createdAt}
          className="text-xs text-stone-400 dark:text-stone-500"
          title={new Date(item.createdAt).toLocaleString()}
        >
          {formatRelativeTime(item.createdAt)}
        </time>

        <div className="flex items-center gap-1">
          {!item.removed && (
            <LikeButton
              experienceId={item.experienceId}
              likedByMe={item.likedByMe}
              likeCount={item.likeCount}
              onGone={() => onGone(item.experienceId)}
            />
          )}
          {isOwner && (
            <DeletePostButton
              experienceId={item.experienceId}
              onDeleted={() => onGone(item.experienceId)}
            />
          )}
        </div>
      </div>
    </article>
  );
}
