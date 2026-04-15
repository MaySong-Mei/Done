// OAuth 2.0 Authorization Code flow for ChatGPT and other LLM providers.
//
// Endpoints:
//   GET  /authorize  — shows login page, issues authorization code
//   POST /token      — exchanges code for access token (dk_ API key)
//
// Flow:
//   1. ChatGPT redirects user to /authorize?client_id=...&redirect_uri=...&state=...
//   2. User logs in with email/password (or Apple ID in the future)
//   3. We redirect back to ChatGPT with ?code=...&state=...
//   4. ChatGPT calls POST /token with code → gets dk_ access token

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

function getDb() {
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
}

// ── Login Page HTML ──

function loginPage(clientId: string, redirectUri: string, state: string, error?: string) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Done — Sign In</title>
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
    input { width: 100%; padding: 12px; border-radius: 8px; border: 1px solid #333;
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
    ${error ? `<div class="error">${error}</div>` : ''}
    <form method="POST" action="">
      <input type="hidden" name="client_id" value="${clientId}">
      <input type="hidden" name="redirect_uri" value="${redirectUri}">
      <input type="hidden" name="state" value="${state}">
      <label>Email</label>
      <input type="email" name="email" required autocomplete="email">
      <label>Password</label>
      <input type="password" name="password" required autocomplete="current-password">
      <button type="submit">Sign In & Authorize</button>
    </form>
    <p class="info">Your data stays private. Only AI assistants you authorize can read it.</p>
  </div>
</body>
</html>`;
}

// ── Helpers ──

async function generateApiKey(userId: string): Promise<string> {
  const db = getDb();
  const keyBytes = new Uint8Array(32);
  crypto.getRandomValues(keyBytes);
  const key = "dk_" + Array.from(keyBytes).map(b => b.toString(16).padStart(2, '0')).join('');

  const hashBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  const hash = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');

  await db.from("api_keys").insert({
    user_id: userId,
    key_hash: hash,
    label: "OAuth (auto-generated)",
  });

  return key;
}

function generateCode(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function parseFormBody(req: Request): Promise<Record<string, string>> {
  const text = await req.text();
  const params = new URLSearchParams(text);
  const result: Record<string, string> = {};
  for (const [k, v] of params) result[k] = v;
  return result;
}

// ── Handler ──

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/oauth\/?/, "/").replace(/^\/functions\/v1\/oauth\/?/, "/");

  // ── GET /authorize — show login page ──
  if (req.method === "GET" && (path === "/authorize" || path === "/")) {
    const clientId = url.searchParams.get("client_id") ?? "";
    const redirectUri = url.searchParams.get("redirect_uri") ?? "";
    const state = url.searchParams.get("state") ?? "";
    const responseType = url.searchParams.get("response_type") ?? "code";

    if (responseType !== "code") {
      return new Response("Unsupported response_type", { status: 400 });
    }

    // Validate client
    const db = getDb();
    const { data: client } = await db.from("oauth_clients").select("client_id").eq("client_id", clientId).single();
    if (!client) {
      return new Response(loginPage(clientId, redirectUri, state, "Unknown application."), {
        headers: { "Content-Type": "text/html" },
      });
    }

    return new Response(loginPage(clientId, redirectUri, state), {
      headers: { "Content-Type": "text/html" },
    });
  }

  // ── POST /authorize — handle login form submission ──
  if (req.method === "POST" && (path === "/authorize" || path === "/")) {
    const form = await parseFormBody(req);
    const { email, password, client_id, redirect_uri, state } = form;

    if (!email || !password) {
      return new Response(loginPage(client_id, redirect_uri, state, "Email and password required."), {
        headers: { "Content-Type": "text/html" },
      });
    }

    // Authenticate with Supabase Auth
    const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: authData, error: authError } = await authClient.auth.signInWithPassword({
      email, password,
    });

    if (authError || !authData.user) {
      return new Response(loginPage(client_id, redirect_uri, state, "Invalid email or password."), {
        headers: { "Content-Type": "text/html" },
      });
    }

    // Generate authorization code
    const code = generateCode();
    const db = getDb();
    await db.from("oauth_codes").insert({
      code,
      user_id: authData.user.id,
      client_id,
      redirect_uri,
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(), // 10 min
    });

    // Redirect back to ChatGPT with code
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

    const { grant_type, code, client_id, client_secret } = body;

    if (grant_type !== "authorization_code") {
      return new Response(JSON.stringify({ error: "unsupported_grant_type" }), {
        status: 400, headers: { "Content-Type": "application/json" },
      });
    }

    const db = getDb();

    // Validate client credentials
    const { data: client } = await db.from("oauth_clients")
      .select("client_id")
      .eq("client_id", client_id)
      .eq("client_secret", client_secret)
      .single();

    if (!client) {
      return new Response(JSON.stringify({ error: "invalid_client" }), {
        status: 401, headers: { "Content-Type": "application/json" },
      });
    }

    // Validate and consume code
    const { data: codeRow } = await db.from("oauth_codes")
      .select("*")
      .eq("code", code)
      .eq("client_id", client_id)
      .eq("used", false)
      .single();

    if (!codeRow || new Date(codeRow.expires_at) < new Date()) {
      return new Response(JSON.stringify({ error: "invalid_grant" }), {
        status: 400, headers: { "Content-Type": "application/json" },
      });
    }

    // Mark code as used
    await db.from("oauth_codes").update({ used: true }).eq("code", code);

    // Generate a long-lived API key
    const apiKey = await generateApiKey(codeRow.user_id);

    return new Response(JSON.stringify({
      access_token: apiKey,
      token_type: "Bearer",
      // dk_ keys don't expire, but we report a long lifetime
      expires_in: 315360000, // 10 years
    }), {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    });
  }

  // ── CORS ──
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }

  return new Response("Not found", { status: 404 });
});
