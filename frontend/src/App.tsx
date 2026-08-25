import "./lib/amplify";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import { AuthProvider } from "./context/AuthContext";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { LoginPage } from "./pages/LoginPage";
import { SignupPage } from "./pages/SignupPage";
import { ConfirmSignupPage } from "./pages/ConfirmSignupPage";
import { FeedPage } from "./pages/FeedPage";
import { NewExperiencePage } from "./pages/NewExperiencePage";

function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="/signup" element={<SignupPage />} />
          <Route path="/confirm-signup" element={<ConfirmSignupPage />} />
          <Route element={<ProtectedRoute />}>
            <Route path="/" element={<FeedPage />} />
            <Route path="/new" element={<NewExperiencePage />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}

export default App;
