// Shared auth: resolves user_id from either a Supabase JWT or a long-lived dk_ API key.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

export async function resolveUserId(authHeader: string | null): Promise<string | null> {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7);

  // Long-lived API key (dk_...)
  if (token.startsWith("dk_")) {
    return await resolveApiKey(token);
  }

  // Supabase JWT — decode and extract sub claim
  try {
    const payload = JSON.parse(atob(token.split(".")[1]));
    return payload.sub ?? null;
  } catch {
    return null;
  }
}

async function resolveApiKey(key: string): Promise<string | null> {
  // Hash the key and look it up
  const encoder = new TextEncoder();
  const data = encoder.encode(key);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashHex = Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const { data: rows, error } = await db
    .from("api_keys")
    .select("user_id")
    .eq("key_hash", hashHex)
    .limit(1);

  if (error || !rows?.length) return null;

  // Update last_used_at (fire-and-forget)
  db.from("api_keys")
    .update({ last_used_at: new Date().toISOString() })
    .eq("key_hash", hashHex)
    .then(() => {});

  return rows[0].user_id;
}
