import { Amplify } from "aws-amplify";
import { cognitoUserPoolsTokenProvider } from "aws-amplify/auth/cognito";
import type { KeyValueStorageInterface } from "aws-amplify/utils";

// App PRD §6: JWTs live in memory, never localStorage, to reduce
// XSS token-theft exposure (there's no server-side session to revoke
// against). Trade-off: a page reload loses the session and requires
// re-login - that's the deliberate cost of this security choice.
class InMemoryStorage implements KeyValueStorageInterface {
  private store = new Map<string, string>();

  async getItem(key: string) {
    return this.store.get(key) ?? null;
  }

  async setItem(key: string, value: string) {
    this.store.set(key, value);
  }

  async removeItem(key: string) {
    this.store.delete(key);
  }

  async clear() {
    this.store.clear();
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

cognitoUserPoolsTokenProvider.setKeyValueStorage(new InMemoryStorage());
