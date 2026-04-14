import { createClient, SupabaseClient } from "@supabase/supabase-js";

let client: SupabaseClient | null = null;

export function getDb(): SupabaseClient {
  if (!client) {
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) {
      throw new Error(
        "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env vars"
      );
    }
    client = createClient(url, key);
  }
  return client;
}

export function getUserId(): string {
  const id = process.env.DONE_USER_ID;
  if (!id) throw new Error("Missing DONE_USER_ID env var");
  return id;
}
