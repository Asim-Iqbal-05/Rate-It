import { Navigate, Outlet } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

// Nothing else in the app matters until this works, since every other
// screen sits behind it - app PRD §8 Step 1.
export function ProtectedRoute() {
  const { status } = useAuth();

  if (status === "loading") {
    return <p className="status-message">Loading...</p>;
  }

  if (status === "unauthenticated") {
    return <Navigate to="/login" replace />;
  }

  return <Outlet />;
}
