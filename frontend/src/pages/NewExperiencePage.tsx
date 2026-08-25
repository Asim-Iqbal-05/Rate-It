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

type UploadStatus = "idle" | "uploading" | "uploaded" | "error";

export function NewExperiencePage() {
  const { getIdToken } = useAuth();
  const navigate = useNavigate();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [file, setFile] = useState<File | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [uploadStatus, setUploadStatus] = useState<UploadStatus>("idle");
  const [imageKey, setImageKey] = useState<string | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [largeFileWarning, setLargeFileWarning] = useState(false);

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [rating, setRating] = useState(0);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Upload and submit fail independently and need different next
  // actions from the user - app PRD §6. Keeping them as separate
  // status/error pairs (uploadStatus/uploadError vs submitError) is
  // what keeps that distinction visible in the UI below.
  const runUpload = async (toUpload: File) => {
    setUploadStatus("uploading");
    setUploadError(null);
    try {
      const uploadUrl = await getUploadUrl(getIdToken);
      await uploadImageToS3(uploadUrl, toUpload);
      setImageKey(uploadUrl.imageKey);
      setUploadStatus("uploaded");
    } catch (err) {
      setUploadStatus("error");
      setImageKey(null);
      setUploadError(
        err instanceof UnauthorizedError
          ? "Your session expired - log in again to upload."
          : err instanceof Error
            ? err.message
            : "Upload failed",
      );
    }
  };

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const picked = e.target.files?.[0];
    if (!picked) return;

    if (previewUrl) URL.revokeObjectURL(previewUrl);

    setFile(picked);
    setPreviewUrl(URL.createObjectURL(picked));
    setImageKey(null);
    setLargeFileWarning(picked.size > LARGE_FILE_WARNING_BYTES);
    runUpload(picked);
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!imageKey) return;

    setSubmitting(true);
    setSubmitError(null);
    try {
      await createExperience(getIdToken, { title, description, rating, imageKey });
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
    uploadStatus === "uploaded" &&
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
              onChange={handleFileChange}
              className="hidden"
            />

            {!previewUrl ? (
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                className="flex h-48 w-full flex-col items-center justify-center gap-2 rounded-xl
                  border-2 border-dashed border-stone-300 text-stone-500 transition-colors
                  hover:border-rose-400 hover:text-rose-700
                  dark:border-stone-700 dark:text-stone-400 dark:hover:border-rose-700 dark:hover:text-rose-400"
              >
                <svg viewBox="0 0 24 24" fill="none" className="h-8 w-8" aria-hidden="true">
                  <path
                    d="M12 16V4m0 0L7 9m5-5l5 5M5 20h14"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
                Choose a photo
              </button>
            ) : (
              <div className="relative">
                <img
                  src={previewUrl}
                  alt="Selected"
                  className="h-64 w-full rounded-xl border border-stone-200 object-cover dark:border-stone-800"
                />

                {uploadStatus === "uploading" && (
                  <div className="absolute inset-0 flex items-center justify-center rounded-xl bg-black/40">
                    <svg className="h-8 w-8 animate-spin text-white" viewBox="0 0 24 24" fill="none">
                      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                      <path
                        className="opacity-75"
                        fill="currentColor"
                        d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
                      />
                    </svg>
                  </div>
                )}

                {uploadStatus === "uploaded" && (
                  <span className="absolute right-2 top-2 rounded-full bg-emerald-600 p-1 text-white">
                    <svg viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4" aria-hidden="true">
                      <path
                        fillRule="evenodd"
                        d="M16.704 5.29a1 1 0 010 1.415l-7.5 7.5a1 1 0 01-1.414 0l-3.5-3.5a1 1 0 111.414-1.414l2.793 2.792 6.793-6.793a1 1 0 011.414 0z"
                        clipRule="evenodd"
                      />
                    </svg>
                  </span>
                )}

                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  className="absolute bottom-2 right-2 rounded-lg bg-white/90 px-3 py-1 text-xs font-medium
                    text-stone-700 shadow-sm hover:bg-white dark:bg-stone-900/90 dark:text-stone-200"
                >
                  Change
                </button>
              </div>
            )}

            {largeFileWarning && uploadStatus !== "error" && (
              <p className="mt-2 text-xs text-stone-500 dark:text-stone-400">
                That&apos;s a large file - upload may take a moment.
              </p>
            )}

            {uploadStatus === "error" && (
              <div className="mt-2 flex items-center justify-between gap-2">
                <Alert variant="error">{uploadError ?? "Upload failed"}</Alert>
                <button
                  type="button"
                  onClick={() => file && runUpload(file)}
                  className="shrink-0 text-sm font-medium text-rose-700 hover:text-rose-800 dark:text-rose-400"
                >
                  Retry
                </button>
              </div>
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
