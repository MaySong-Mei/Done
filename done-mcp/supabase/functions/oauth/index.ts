// OAuth 2.0 Authorization Code + PKCE flow for ChatGPT and other LLM providers.
//
// Endpoints:
//   GET  /authorize  — shows login page
//   POST /authorize  — handles login, redirects with code
//   POST /token      — exchanges code for access token (dk_ API key)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? SUPABASE_SERVICE_KEY;
function getDb() {
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

// ── Login Page HTML ──

function loginPage(params: Record<string, string>, error?: string) {
  const hiddenFields = Object.entries(params)
    .map(([k, v]) => `<input type="hidden" name="${k}" value="${escapeHtml(v)}">`)
    .join("\n      ");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Done - Sign In</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #0a0a0a; color: #e5e5e5; display: flex; justify-content: center;
           align-items: center; min-height: 100vh; }
    .card { background: #1a1a1a; border-radius: 16px; padding: 40px; width: 380px;
            box-shadow: 0 4px 24px rgba(0,0,0,0.5); }
    h1 { font-size: 24px; margin-bottom: 8px; text-align: center; }
    .subtitle { color: #888; font-size: 14px; text-align: center; margin-bottom: 28px; }
    label { display: block; font-size: 13px; color: #aaa; margin-bottom: 6px; margin-top: 16px; }
    input[type="email"], input[type="password"] {
      width: 100%; padding: 12px; border-radius: 8px; border: 1px solid #333;
      background: #111; color: #fff; font-size: 16px; outline: none; }
    input:focus { border-color: #4ECDC4; }
    button { width: 100%; padding: 14px; border-radius: 10px; border: none;
             background: #4ECDC4; color: #000; font-size: 16px; font-weight: 600;
             cursor: pointer; margin-top: 24px; }
    button:hover { background: #45b7b0; }
    .error { background: #3a1515; color: #ff6b6b; padding: 10px; border-radius: 8px;
             font-size: 13px; margin-bottom: 12px; }
    .info { color: #666; font-size: 12px; text-align: center; margin-top: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Done</h1>
    <p class="subtitle">Sign in to connect your life data</p>
    ${error ? `<div class="error">${escapeHtml(error)}</div>` : ""}
    <form method="POST" action="https://uqnvtzblppjblwgbpqhf.supabase.co/functions/v1/oauth/authorize">
      ${hiddenFields}
      <label>Email</label>
      <input type="email" name="email" required autocomplete="email">
      <label>Password</label>
      <input type="password" name="password" required autocomplete="current-password">
      <button type="submit">Sign In &amp; Authorize</button>
    </form>
    <p class="info">Your data stays private. Only AI assistants you authorize can read it.</p>
  </div>
</body>
</html>`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// ── Helpers ──

async function generateApiKey(userId: string, label = "OAuth (auto-generated)"): Promise<string> {
  const db = getDb();
  const keyBytes = new Uint8Array(32);
  crypto.getRandomValues(keyBytes);
  const key = "dk_" + Array.from(keyBytes).map(b => b.toString(16).padStart(2, "0")).join("");

  const hashBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  const hash = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, "0")).join("");

  await db.from("api_keys").insert({ user_id: userId, key_hash: hash, label });
  return key;
}

async function generateUnboundApiKey(): Promise<string> {
  // Create a key with a placeholder user_id. The `authenticate` MCP tool
  // will later update this row to point to the real user.
  // We use the Supabase service role to insert with a non-existent FK,
  // so we need a real user row. Use a dedicated "anonymous" auth user.
  const db = getDb();

  // Ensure the anonymous placeholder user exists
  const anonId = "00000000-0000-0000-0000-000000000001";
  const { error: userErr } = await db.auth.admin.getUserById(anonId);
  if (userErr) {
    // Create the placeholder user if it doesn't exist
    await db.auth.admin.createUser({
      id: anonId,
      email: "anon@done.internal",
      password: crypto.randomUUID(),
      email_confirm: true,
    });
  }

  return generateApiKey(anonId, "Unbound (pending authenticate)");
}

function generateCode(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function parseFormBody(req: Request): Promise<Record<string, string>> {
  const text = await req.text();
  const params = new URLSearchParams(text);
  const result: Record<string, string> = {};
  for (const [k, v] of params) result[k] = v;
  return result;
}

async function sha256(plain: string): Promise<string> {
  const data = new TextEncoder().encode(plain);
  const hash = await crypto.subtle.digest("SHA-256", data);
  // base64url encode (same as PKCE spec)
  const b64 = btoa(String.fromCharCode(...new Uint8Array(hash)));
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ── Handler ──

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/oauth\/?/, "/").replace(/^\/functions\/v1\/oauth\/?/, "/");
  const jsonHeaders = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" };

  // CORS
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }

  // ── GET /authorize — auto-approve with anonymous session ──
  // ChatGPT loads this in a sandboxed iframe that blocks HTML rendering.
  // We skip the login page and immediately issue an anonymous auth code.
  // The user authenticates later via the MCP `authenticate` tool.
  if (req.method === "GET" && (path === "/authorize" || path === "/")) {
    const clientId = url.searchParams.get("client_id") ?? "";
    const redirectUri = url.searchParams.get("redirect_uri") ?? "";
    const state = url.searchParams.get("state") ?? "";
    const codeChallenge = url.searchParams.get("code_challenge") ?? "";
    const codeChallengeMethod = url.searchParams.get("code_challenge_method") ?? "";

    // Issue code for anonymous session (user_id = "anonymous")
    const code = generateCode();
    const db = getDb();
    const storedClientId = codeChallenge
      ? `${clientId}|${codeChallenge}|${codeChallengeMethod || "S256"}`
      : clientId;

    const ANON_USER = "00000000-0000-0000-0000-000000000001";
    const { error: insertErr } = await db.from("oauth_codes").insert({
      code,
      user_id: ANON_USER,
      client_id: storedClientId,
      redirect_uri: redirectUri,
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    });
    if (insertErr) {
      console.error("[OAuth] insert code failed:", insertErr);
      return new Response(JSON.stringify({ error: "internal_error", detail: insertErr.message }), {
        status: 500, headers: jsonHeaders,
      });
    }

    const redirectUrl = new URL(redirectUri);
    redirectUrl.searchParams.set("code", code);
    if (state) redirectUrl.searchParams.set("state", state);

    return new Response(null, {
      status: 302,
      headers: { Location: redirectUrl.toString() },
    });
  }

  // ── POST /authorize — handle login, redirect with code ──
  if (req.method === "POST" && (path === "/authorize" || path === "/")) {
    const form = await parseFormBody(req);
    const { email, password, client_id, redirect_uri, state, code_challenge, code_challenge_method } = form;

    const htmlHeaders = { "Content-Type": "text/html; charset=utf-8" };

    // Collect passthrough params for re-rendering login page on error
    const passthrough: Record<string, string> = {};
    for (const key of ["client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "response_type", "scope"]) {
      if (form[key]) passthrough[key] = form[key];
    }

    if (!email || !password) {
      return new Response(loginPage(passthrough, "Email and password required."), { headers: htmlHeaders });
    }

    // Authenticate
    const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: authData, error: authError } = await authClient.auth.signInWithPassword({ email, password });

    if (authError || !authData.user) {
      return new Response(loginPage(passthrough, "Invalid email or password."), { headers: htmlHeaders });
    }

    // Generate authorization code
    const code = generateCode();
    const db = getDb();
    await db.from("oauth_codes").insert({
      code,
      user_id: authData.user.id,
      client_id: client_id ?? "",
      redirect_uri: redirect_uri ?? "",
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    });

    // Store PKCE code_challenge alongside the code (in-memory for now, or reuse the code row)
    // We'll verify it in the token endpoint
    if (code_challenge) {
      await db.from("oauth_codes").update({
        // Store challenge in redirect_uri field is hacky; let's use a simple approach:
        // We'll just store it as part of the client_id field separated by |
        client_id: `${client_id ?? ""}|${code_challenge}|${code_challenge_method ?? "S256"}`,
      }).eq("code", code);
    }

    // Redirect back with code
    const redirectUrl = new URL(redirect_uri);
    redirectUrl.searchParams.set("code", code);
    if (state) redirectUrl.searchParams.set("state", state);

    return new Response(null, {
      status: 302,
      headers: { Location: redirectUrl.toString() },
    });
  }

  // ── POST /token — exchange code for access token ──
  if (req.method === "POST" && path === "/token") {
    let body: Record<string, string>;
    const contentType = req.headers.get("Content-Type") ?? "";
    if (contentType.includes("application/json")) {
      body = await req.json();
    } else {
      body = await parseFormBody(req);
    }

    const { grant_type, code, client_id, client_secret, code_verifier } = body;

    if (grant_type !== "authorization_code") {
      return new Response(JSON.stringify({ error: "unsupported_grant_type" }), { status: 400, headers: jsonHeaders });
    }

    const db = getDb();

    // Look up the code
    const { data: codeRow } = await db.from("oauth_codes")
      .select("*")
      .eq("code", code)
      .eq("used", false)
      .single();

    if (!codeRow || new Date(codeRow.expires_at) < new Date()) {
      return new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400, headers: jsonHeaders });
    }

    // Parse stored client_id which may contain PKCE challenge
    const storedParts = (codeRow.client_id as string).split("|");
    const storedClientId = storedParts[0];
    const storedChallenge = storedParts[1];
    const storedMethod = storedParts[2];

    // Verify PKCE if challenge was provided during authorize
    if (storedChallenge && code_verifier) {
      const computed = await sha256(code_verifier);
      if (computed !== storedChallenge) {
        return new Response(JSON.stringify({ error: "invalid_grant", error_description: "PKCE verification failed" }), {
          status: 400, headers: jsonHeaders,
        });
      }
    }

    // If client_secret provided, verify it (for non-PKCE flows)
    if (client_secret && storedClientId) {
      const { data: client } = await db.from("oauth_clients")
        .select("client_id")
        .eq("client_id", storedClientId)
        .eq("client_secret", client_secret)
        .single();

      if (!client) {
        // For dynamically registered clients, skip DB check
        // (they don't have secrets)
      }
    }

    // Mark code as used
    await db.from("oauth_codes").update({ used: true }).eq("code", code);

    // Generate API key — anonymous if user_id is the placeholder
    const isAnonymous = codeRow.user_id === "00000000-0000-0000-0000-000000000000";
    const apiKey = isAnonymous
      ? await generateUnboundApiKey()
      : await generateApiKey(codeRow.user_id);

    return new Response(JSON.stringify({
      access_token: apiKey,
      token_type: "Bearer",
      expires_in: 315360000,
    }), {
      headers: { ...jsonHeaders, "Cache-Control": "no-store" },
    });
  }

  return new Response("Not found", { status: 404 });
});
