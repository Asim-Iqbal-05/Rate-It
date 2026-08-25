import { useAuth } from "../context/AuthContext";

// Placeholder for the real feed screen (app PRD §8 Step 2) - this page
// only exists to prove the auth shell works end-to-end: if you can see
// this, your token was accepted and the protected route held.
export function HomePage() {
  const { username, signOut } = useAuth();

  return (
    <div className="home-page">
      <h1>Logged in as {username}</h1>
      <p>The feed screen isn't built yet - this confirms the auth shell works.</p>
      <button onClick={signOut}>Log out</button>
    </div>
  );
}
