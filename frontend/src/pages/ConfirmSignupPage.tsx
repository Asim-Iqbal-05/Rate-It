import { useState, type FormEvent } from "react";
import { useNavigate, useLocation, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import { AuthLayout } from "../components/AuthLayout";
import { FormField } from "../components/FormField";
import { Button } from "../components/Button";
import { Alert } from "../components/Alert";

export function ConfirmSignupPage() {
  const { confirmSignUp } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

  const initialUsername = (location.state as { username?: string } | null)?.username ?? "";

  const [username, setUsername] = useState(initialUsername);
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await confirmSignUp(username, code);
      navigate("/login", { state: { confirmed: true } });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Confirmation failed");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <AuthLayout title="Confirm your email" subtitle="Enter the verification code we emailed you.">
      <form className="flex flex-col gap-4" onSubmit={handleSubmit}>
        <FormField
          label="Username"
          name="username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          required
          autoComplete="username"
        />

        <FormField
          label="Verification code"
          name="code"
          value={code}
          onChange={(e) => setCode(e.target.value)}
          required
          inputMode="numeric"
        />

        {error && <Alert variant="error">{error}</Alert>}

        <Button type="submit" loading={submitting} className="mt-2 w-full">
          {submitting ? "Confirming..." : "Confirm"}
        </Button>

        <p className="text-center text-sm text-neutral-500 dark:text-neutral-400">
          <Link to="/login" className="font-medium text-indigo-600 hover:text-indigo-700 dark:text-indigo-400">
            Back to login
          </Link>
        </p>
      </form>
    </AuthLayout>
  );
}
