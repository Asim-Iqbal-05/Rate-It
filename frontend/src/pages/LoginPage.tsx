import { useState, type FormEvent } from "react";
import { useNavigate, useLocation, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import { AuthLayout } from "../components/AuthLayout";
import { FormField } from "../components/FormField";
import { Button } from "../components/Button";
import { Alert } from "../components/Alert";

export function LoginPage() {
  const { signIn } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

  const justConfirmed = (location.state as { confirmed?: boolean } | null)?.confirmed;

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await signIn(username, password);
      navigate("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Login failed");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <AuthLayout title="Welcome back">
      <form className="flex flex-col gap-4" onSubmit={handleSubmit}>
        {justConfirmed && <Alert variant="info">Account confirmed - log in below.</Alert>}

        <FormField
          label="Username or email"
          name="username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          required
          autoComplete="username"
        />

        <FormField
          label="Password"
          name="password"
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
          autoComplete="current-password"
        />

        {error && <Alert variant="error">{error}</Alert>}

        <Button type="submit" loading={submitting} className="mt-2 w-full">
          {submitting ? "Logging in..." : "Log in"}
        </Button>

        <p className="text-center text-sm text-neutral-500 dark:text-neutral-400">
          Don&apos;t have an account?{" "}
          <Link to="/signup" className="font-medium text-indigo-600 hover:text-indigo-700 dark:text-indigo-400">
            Sign up
          </Link>
        </p>
      </form>
    </AuthLayout>
  );
}
