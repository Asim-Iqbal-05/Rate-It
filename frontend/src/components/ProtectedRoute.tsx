import { Navigate, Outlet } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Nothing else in the app matters until this works, since every other
// screen sits behind it - app PRD §8 Step 1.
export function ProtectedRoute() {
  const { status } = useAuth();

  if (status === "loading") {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <svg
          className="h-6 w-6 animate-spin text-rose-700 dark:text-rose-400"
          viewBox="0 0 24 24"
          fill="none"
          aria-label="Loading"
        >
          <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
          <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" />
        </svg>
      </div>
    );
  }

  if (status === "unauthenticated") {
    return <Navigate to="/login" replace />;
  }

  return <Outlet />;
}
