import { useRef, useState, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import {
  getUploadUrl,
  uploadImageToS3,
  createExperience,
  UnauthorizedError,
  ValidationApiError,
} from "../lib/api";
import { AppHeader } from "../components/AppHeader";
import { FormField } from "../components/FormField";
import { Button } from "../components/Button";
import { Alert } from "../components/Alert";
import { StarRatingInput } from "../components/StarRatingInput";

const MAX_TITLE_LENGTH = 100;
const MAX_DESCRIPTION_LENGTH = 1000;
const LARGE_FILE_WARNING_BYTES = 8 * 1024 * 1024;
// Mirrors MAX_UPLOAD_BYTES in services/media/handler.py - S3's POST
// policy hard-rejects anything over this, so it's worth catching
// client-side with a clear message instead of letting the upload fail.
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
// Mirrors MAX_IMAGES in services/experience/handler.py - keep in sync.
const MAX_IMAGES = 5;

type UploadStatus = "uploading" | "uploaded" | "error";

interface ImageItem {
  id: string;
  file: File;
  previewUrl: string;
  status: UploadStatus;
  imageKey: string | null;
  error: string | null;
  large: boolean;
}

export function NewExperiencePage() {
  const { getIdToken } = useAuth();
  const navigate = useNavigate();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [images, setImages] = useState<ImageItem[]>([]);

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [rating, setRating] = useState(0);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const updateImage = (id: string, patch: Partial<ImageItem>) => {
    setImages((prev) => prev.map((img) => (img.id === id ? { ...img, ...patch } : img)));
  };

  // Upload and submit fail independently and need different next
  // actions from the user - app PRD §6. Each image tracks its own
  // upload state so one failure never blocks or hides the others.
  const runUpload = async (item: ImageItem) => {
    updateImage(item.id, { status: "uploading", error: null });
    try {
      const uploadUrl = await getUploadUrl(getIdToken);
      await uploadImageToS3(uploadUrl, item.file);
      updateImage(item.id, { status: "uploaded", imageKey: uploadUrl.imageKey });
    } catch (err) {
      updateImage(item.id, {
        status: "error",
        imageKey: null,
        error:
          err instanceof UnauthorizedError
            ? "Your session expired - log in again to upload."
            : err instanceof Error
              ? err.message
              : "Upload failed",
      });
    }
  };

  const handleFilesChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const picked = Array.from(e.target.files ?? []);
    e.target.value = ""; // allow re-picking the same file later

    const room = MAX_IMAGES - images.length;
    const toAdd = picked.slice(0, room);

    const newItems: ImageItem[] = toAdd.map((file) => {
      const tooLarge = file.size > MAX_UPLOAD_BYTES;
      return {
        id: crypto.randomUUID(),
        file,
        previewUrl: URL.createObjectURL(file),
        status: tooLarge ? "error" : "uploading",
        imageKey: null,
        error: tooLarge
          ? `That file is over the ${MAX_UPLOAD_BYTES / (1024 * 1024)}MB limit - pick a smaller one.`
          : null,
        large: file.size > LARGE_FILE_WARNING_BYTES,
      };
    });

    setImages((prev) => [...prev, ...newItems]);
    // Files over the hard limit are rejected up front (no point
    // attempting an upload that S3's own POST policy will reject
    // anyway) - only attempt ones that could actually succeed.
    newItems.filter((img) => img.status === "uploading").forEach(runUpload);
  };

  const removeImage = (id: string) => {
    setImages((prev) => {
      const target = prev.find((img) => img.id === id);
      if (target) URL.revokeObjectURL(target.previewUrl);
      return prev.filter((img) => img.id !== id);
    });
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    const imageKeys = images
      .filter((img) => img.status === "uploaded" && img.imageKey)
      .map((img) => img.imageKey as string);
    if (imageKeys.length === 0) return;

    setSubmitting(true);
    setSubmitError(null);
    try {
      await createExperience(getIdToken, { title, description, rating, imageKeys });
      navigate("/");
    } catch (err) {
      if (err instanceof UnauthorizedError) {
        // Deliberately not auto-navigating to /login here: the user's
        // typed title/description would be lost - app PRD §4.2. They
        // can finish reading the message and choose when to leave.
        setSubmitError("Your session expired. Log in again, then submit once more.");
      } else if (err instanceof ValidationApiError) {
        setSubmitError(`${err.field}: ${err.message}`);
      } else {
        setSubmitError(err instanceof Error ? err.message : "Something went wrong");
      }
    } finally {
      setSubmitting(false);
    }
  };

  const canSubmit =
    images.length > 0 &&
    images.every((img) => img.status === "uploaded") &&
    title.trim().length > 0 &&
    description.trim().length > 0 &&
    rating >= 1 &&
    !submitting;

  return (
    <div className="min-h-screen bg-stone-50 dark:bg-stone-950">
      <AppHeader />
      <main className="mx-auto max-w-lg px-4 py-10">
        <h1 className="mb-6 text-xl font-semibold text-stone-900 dark:text-stone-100">
          New experience
        </h1>

        <form className="flex flex-col gap-5" onSubmit={handleSubmit}>
          <div>
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              multiple
              onChange={handleFilesChange}
              className="hidden"
            />

            <div className="grid grid-cols-3 gap-2">
              {images.map((img) => (
                <div key={img.id} className="relative">
                  <img
                    src={img.previewUrl}
                    alt=""
                    className="aspect-square w-full rounded-lg border border-stone-200 object-cover dark:border-stone-800"
                  />

                  {img.status === "uploading" && (
                    <div className="absolute inset-0 flex items-center justify-center rounded-lg bg-black/40">
                      <svg className="h-5 w-5 animate-spin text-white" viewBox="0 0 24 24" fill="none">
                        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                        <path
                          className="opacity-75"
                          fill="currentColor"
                          d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
                        />
                      </svg>
                    </div>
                  )}

                  {img.status === "uploaded" && (
                    <span className="absolute right-1 top-1 rounded-full bg-emerald-600 p-0.5 text-white">
                      <svg viewBox="0 0 20 20" fill="currentColor" className="h-3 w-3" aria-hidden="true">
                        <path
                          fillRule="evenodd"
                          d="M16.704 5.29a1 1 0 010 1.415l-7.5 7.5a1 1 0 01-1.414 0l-3.5-3.5a1 1 0 111.414-1.414l2.793 2.792 6.793-6.793a1 1 0 011.414 0z"
                          clipRule="evenodd"
                        />
                      </svg>
                    </span>
                  )}

                  {img.status === "error" && img.file.size <= MAX_UPLOAD_BYTES && (
                    <button
                      type="button"
                      onClick={() => runUpload(img)}
                      className="absolute inset-0 flex items-center justify-center rounded-lg bg-red-950/60 text-xs font-medium text-white"
                    >
                      Retry
                    </button>
                  )}

                  {img.status === "error" && img.file.size > MAX_UPLOAD_BYTES && (
                    <div className="absolute inset-0 flex items-center justify-center rounded-lg bg-red-950/60 p-1 text-center text-[10px] font-medium text-white">
                      Too large
                    </div>
                  )}

                  <button
                    type="button"
                    onClick={() => removeImage(img.id)}
                    aria-label="Remove image"
                    className="absolute -right-1.5 -top-1.5 rounded-full bg-stone-900 p-0.5 text-white shadow-sm dark:bg-stone-100 dark:text-stone-900"
                  >
                    <svg viewBox="0 0 20 20" fill="currentColor" className="h-3.5 w-3.5" aria-hidden="true">
                      <path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z" />
                    </svg>
                  </button>
                </div>
              ))}

              {images.length < MAX_IMAGES && (
                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  className="flex aspect-square flex-col items-center justify-center gap-1 rounded-lg
                    border-2 border-dashed border-stone-300 text-stone-500 transition-colors
                    hover:border-rose-400 hover:text-rose-700
                    dark:border-stone-700 dark:text-stone-400 dark:hover:border-rose-700 dark:hover:text-rose-400"
                >
                  <svg viewBox="0 0 24 24" fill="none" className="h-6 w-6" aria-hidden="true">
                    <path
                      d="M12 16V4m0 0L7 9m5-5l5 5M5 20h14"
                      stroke="currentColor"
                      strokeWidth="1.5"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                  <span className="text-xs">Add photo</span>
                </button>
              )}
            </div>

            <p className="mt-2 text-xs text-stone-500 dark:text-stone-400">
              {images.length}/{MAX_IMAGES} photos
              {images.length === 0 && " - hold Ctrl (Cmd on Mac) to pick several at once"}
              {images.some((img) => img.large) && " - large files may take a moment to upload"}
            </p>

            {images.some((img) => img.status === "error" && img.file.size > MAX_UPLOAD_BYTES) && (
              <Alert variant="error">
                {`One or more photos are over the ${MAX_UPLOAD_BYTES / (1024 * 1024)}MB limit - remove them and pick a smaller file.`}
              </Alert>
            )}

            {images.some((img) => img.status === "error" && img.file.size <= MAX_UPLOAD_BYTES) && (
              <Alert variant="error">One or more photos failed to upload - tap to retry.</Alert>
            )}
          </div>

          <FormField
            label="Title"
            name="title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            maxLength={MAX_TITLE_LENGTH}
            required
          />

          <div className="flex flex-col gap-1.5">
            <label htmlFor="description" className="text-sm font-medium text-stone-700 dark:text-stone-300">
              Description
            </label>
            <textarea
              id="description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              maxLength={MAX_DESCRIPTION_LENGTH}
              required
              rows={4}
              className="rounded-lg border border-stone-300 bg-white px-3 py-2 text-stone-900
                placeholder:text-stone-400 transition-colors
                focus:border-rose-600 focus:outline-none focus:ring-2 focus:ring-rose-600/30
                dark:border-stone-700 dark:bg-stone-900 dark:text-stone-100"
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-stone-700 dark:text-stone-300">Rating</span>
            <StarRatingInput value={rating} onChange={setRating} />
          </div>

          {submitError && <Alert variant="error">{submitError}</Alert>}

          <Button type="submit" disabled={!canSubmit} loading={submitting} className="w-full">
            {submitting ? "Posting..." : "Post"}
          </Button>
        </form>
      </main>
    </div>
  );
}
