import { useState } from "react";

// Posts can have 1-5 images (multi-image support added post-launch -
// see app PRD §4.3 note). A single image just renders directly; more
// than one gets a swipeable/clickable gallery with dot indicators so
// viewers can browse them without leaving the feed.
export function ImageGallery({ urls, alt }: { urls: string[]; alt: string }) {
  const [index, setIndex] = useState(0);

  if (urls.length === 0) {
    return (
      <div className="flex aspect-video w-full items-center justify-center rounded-lg bg-stone-100 text-sm text-stone-400 dark:bg-stone-800">
        No image
      </div>
    );
  }

  return (
    <div className="relative">
      <img
        src={urls[index]}
        alt={alt}
        className="aspect-video w-full rounded-lg border border-stone-200 object-cover dark:border-stone-800"
      />

      {urls.length > 1 && (
        <>
          <button
            type="button"
            aria-label="Previous image"
            onClick={() => setIndex((i) => (i - 1 + urls.length) % urls.length)}
            className="absolute left-2 top-1/2 -translate-y-1/2 rounded-full bg-black/50 p-1.5 text-white hover:bg-black/70"
          >
            <svg viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4">
              <path
                fillRule="evenodd"
                d="M12.79 5.23a.75.75 0 01-.02 1.06L8.832 10l3.938 3.71a.75.75 0 11-1.04 1.08l-4.5-4.25a.75.75 0 010-1.08l4.5-4.25a.75.75 0 011.06.02z"
                clipRule="evenodd"
              />
            </svg>
          </button>
          <button
            type="button"
            aria-label="Next image"
            onClick={() => setIndex((i) => (i + 1) % urls.length)}
            className="absolute right-2 top-1/2 -translate-y-1/2 rounded-full bg-black/50 p-1.5 text-white hover:bg-black/70"
          >
            <svg viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4">
              <path
                fillRule="evenodd"
                d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
                clipRule="evenodd"
              />
            </svg>
          </button>

          <div className="absolute bottom-2 left-1/2 flex -translate-x-1/2 gap-1">
            {urls.map((_, i) => (
              <button
                key={i}
                type="button"
                aria-label={`Go to image ${i + 1}`}
                onClick={() => setIndex(i)}
                className={`h-1.5 w-1.5 rounded-full transition-colors ${
                  i === index ? "bg-white" : "bg-white/50"
                }`}
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
}
