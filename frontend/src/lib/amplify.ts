import { Amplify } from "aws-amplify";
import { cognitoUserPoolsTokenProvider } from "aws-amplify/auth/cognito";
import type { KeyValueStorageInterface } from "aws-amplify/utils";

// App PRD §6 calls for keeping JWTs out of localStorage to reduce XSS
// token-theft exposure (there's no server-side session to revoke
// against). sessionStorage is the middle ground actually used here:
// it still clears on tab/browser close (unlike localStorage, which
// persists indefinitely), but - unlike a pure in-memory store - it
// survives a page refresh, which pure in-memory storage did not.
class SessionStorageAdapter implements KeyValueStorageInterface {
  async getItem(key: string) {
    return sessionStorage.getItem(key);
  }

  async setItem(key: string, value: string) {
    sessionStorage.setItem(key, value);
  }

  async removeItem(key: string) {
    sessionStorage.removeItem(key);
  }

  async clear() {
    sessionStorage.clear();
  }
}

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId: import.meta.env.VITE_COGNITO_USER_POOL_ID,
      userPoolClientId: import.meta.env.VITE_COGNITO_APP_CLIENT_ID,
    },
  },
});

cognitoUserPoolsTokenProvider.setKeyValueStorage(new SessionStorageAdapter());
