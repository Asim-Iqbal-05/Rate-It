import { useState, type FormEvent } from "react";
import { useNavigate, useLocation, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

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
    <form className="auth-form" onSubmit={handleSubmit}>
      <h1>Confirm your email</h1>
      <p>Enter the verification code we emailed you.</p>

      <label>
        Username
        <input
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          required
          autoComplete="username"
        />
      </label>

      <label>
        Verification code
        <input
          value={code}
          onChange={(e) => setCode(e.target.value)}
          required
          inputMode="numeric"
        />
      </label>

      {error && <p className="error-message">{error}</p>}

      <button type="submit" disabled={submitting}>
        {submitting ? "Confirming..." : "Confirm"}
      </button>

      <p>
        <Link to="/login">Back to login</Link>
      </p>
    </form>
  );
}
