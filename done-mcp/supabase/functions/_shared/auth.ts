// Shared auth: resolves user_id from either a Supabase JWT or a long-lived dk_ API key.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";
import { createRemoteJWKSet, jwtVerify } from "https://esm.sh/jose@5.9.6";

export async function resolveUserId(authHeader: string | null): Promise<string | null> {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7);

  // Long-lived API key (dk_...)
  if (token.startsWith("dk_")) {
    return await resolveApiKey(token);
  }

  // Supabase JWT — verify the signature against the project's own signing
  // keys (JWKS, ES256) before trusting `sub`. Decoding without verifying let
  // anyone name another user's id; every function here reads with the
  // secret key, so the token is the only thing standing between users.
  return await resolveSupabaseJwt(token);
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const jwks = createRemoteJWKSet(new URL(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`));

async function resolveSupabaseJwt(token: string): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, jwks, {
      issuer: `${SUPABASE_URL}/auth/v1`,
      audience: "authenticated",
    });
    return typeof payload.sub === "string" && payload.sub.length > 0 ? payload.sub : null;
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
    (Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"))!
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
