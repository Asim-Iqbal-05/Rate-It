import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { Hub } from "aws-amplify/utils";
import {
  signUp as amplifySignUp,
  confirmSignUp as amplifyConfirmSignUp,
  signIn as amplifySignIn,
  signOut as amplifySignOut,
  getCurrentUser,
  fetchAuthSession,
} from "aws-amplify/auth";

type AuthStatus = "loading" | "authenticated" | "unauthenticated";

interface AuthContextValue {
  status: AuthStatus;
  username: string | null;
  /** Cognito `sub` - what a post's `userId` is compared against to know "my" posts. */
  userId: string | null;
  signUp: (username: string, email: string, password: string) => Promise<void>;
  confirmSignUp: (username: string, code: string) => Promise<void>;
  signIn: (username: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  /** Bearer token for API calls - null if there's no valid session. */
  getIdToken: () => Promise<string | null>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<AuthStatus>("loading");
  const [username, setUsername] = useState<string | null>(null);
  const [userId, setUserId] = useState<string | null>(null);

  const refreshFromSession = async () => {
    try {
      const user = await getCurrentUser();
      setUsername(user.username);
      setUserId(user.userId);
      setStatus("authenticated");
    } catch {
      setUsername(null);
      setUserId(null);
      setStatus("unauthenticated");
    }
  };

  useEffect(() => {
    refreshFromSession();

    // Silent refresh failures (expired refresh token, revoked session,
    // etc.) bounce the user to login rather than leaving a half-broken
    // authenticated UI up - app PRD §3.1.
    const unsubscribe = Hub.listen("auth", ({ payload }) => {
      if (payload.event === "signedOut" || payload.event === "tokenRefresh_failure") {
        setUsername(null);
        setUserId(null);
        setStatus("unauthenticated");
      }
    });

    return unsubscribe;
  }, []);

  const signUp = async (username: string, email: string, password: string) => {
    await amplifySignUp({
      username,
      password,
      options: { userAttributes: { email } },
    });
  };

  const confirmSignUp = async (username: string, code: string) => {
    await amplifyConfirmSignUp({ username, confirmationCode: code });
  };

  const signIn = async (username: string, password: string) => {
    await amplifySignIn({ username, password });
    await refreshFromSession();
  };

  const signOut = async () => {
    await amplifySignOut();
    setUsername(null);
    setUserId(null);
    setStatus("unauthenticated");
  };

  const getIdToken = async () => {
    try {
      // Amplify refreshes automatically here if the token is near expiry.
      const session = await fetchAuthSession();
      return session.tokens?.idToken?.toString() ?? null;
    } catch {
      return null;
    }
  };

  return (
    <AuthContext.Provider
      value={{ status, username, userId, signUp, confirmSignUp, signIn, signOut, getIdToken }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
