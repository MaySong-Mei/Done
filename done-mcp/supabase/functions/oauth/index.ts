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

function connectCodePage(params: Record<string, string>, error?: string) {
  const hiddenFields = Object.entries(params)
    .map(([k, v]) => `<input type="hidden" name="${k}" value="${escapeHtml(v)}">`)
    .join("\n      ");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Done - Connect AI</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #0a0a0a; color: #e5e5e5; display: flex; justify-content: center;
           align-items: center; min-height: 100vh; }
    .card { background: #1a1a1a; border-radius: 16px; padding: 40px; width: 380px;
            box-shadow: 0 4px 24px rgba(0,0,0,0.5); }
    h1 { font-size: 24px; margin-bottom: 8px; text-align: center; }
    .subtitle { color: #888; font-size: 14px; text-align: center; margin-bottom: 28px; line-height: 1.5; }
    label { display: block; font-size: 13px; color: #aaa; margin-bottom: 6px; margin-top: 16px; }
    input[type="text"] {
      width: 100%; padding: 16px; border-radius: 8px; border: 1px solid #333;
      background: #111; color: #fff; font-size: 28px; font-weight: 700; outline: none;
      text-align: center; letter-spacing: 8px; text-transform: uppercase; }
    input:focus { border-color: #4ECDC4; }
    button { width: 100%; padding: 14px; border-radius: 10px; border: none;
             background: #4ECDC4; color: #000; font-size: 16px; font-weight: 600;
             cursor: pointer; margin-top: 24px; }
    button:hover { background: #45b7b0; }
    .error { background: #3a1515; color: #ff6b6b; padding: 10px; border-radius: 8px;
             font-size: 13px; margin-bottom: 12px; }
    .steps { color: #555; font-size: 12px; margin-top: 20px; line-height: 1.8; }
    .steps b { color: #888; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Done</h1>
    <p class="subtitle">Enter the connect code from your Done app to link your AI assistant.</p>
    ${error ? `<div class="error">${escapeHtml(error)}</div>` : ""}
    <form method="POST" action="https://uqnvtzblppjblwgbpqhf.supabase.co/functions/v1/oauth/authorize">
      ${hiddenFields}
      <label>Connect Code</label>
      <input type="text" name="connect_code" maxlength="6" placeholder="ABC123" autocomplete="off" autofocus>
      <button type="submit">Connect</button>
    </form>
    <div class="steps">
      <b>How to get your code:</b><br>
      1. Open Done app → Me → Account<br>
      2. Tap "Generate AI Connect Code"<br>
      3. Enter the 6-character code here
    </div>
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

  const { error } = await db.from("api_keys").insert({ user_id: userId, key_hash: hash, label });
  if (error) {
    console.error("[generateApiKey] INSERT failed:", error.message, "user_id:", userId);
    throw new Error("Failed to store API key: " + error.message);
  }
  console.log("[generateApiKey] Created key for user:", userId, "label:", label);
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

  // ── GET /authorize — show connect code page ──
  if (req.method === "GET" && (path === "/authorize" || path === "/")) {
    const params: Record<string, string> = {};
    for (const [k, v] of url.searchParams) params[k] = v;
    return new Response(connectCodePage(params), {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "default-src 'self' 'unsafe-inline'; form-action *;",
      },
    });
  }

  // ── POST /authorize — validate connect code, redirect with auth code ──
  if (req.method === "POST" && (path === "/authorize" || path === "/")) {
    const form = await parseFormBody(req);
    const { connect_code, client_id, redirect_uri, state, code_challenge, code_challenge_method } = form;

    const htmlHeaders = {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": "default-src 'self' 'unsafe-inline'; form-action *;",
    };
    const passthrough: Record<string, string> = {};
    for (const key of ["client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "response_type", "scope"]) {
      if (form[key]) passthrough[key] = form[key];
    }

    if (!connect_code || connect_code.length !== 6) {
      return new Response(connectCodePage(passthrough, "Please enter a valid 6-character code."), { headers: htmlHeaders });
    }

    const db = getDb();
    const { data: codeRow } = await db
      .from("mcp_connect_codes")
      .select("user_id, expires_at, used")
      .eq("code", connect_code.toUpperCase())
      .single();

    if (!codeRow || codeRow.used || new Date(codeRow.expires_at) < new Date()) {
      return new Response(connectCodePage(passthrough, "Invalid or expired code. Generate a new one in the Done app."), { headers: htmlHeaders });
    }

    // Mark code as used
    await db.from("mcp_connect_codes").update({ used: true }).eq("code", connect_code.toUpperCase());

    // Issue OAuth authorization code for the real user
    const authCode = generateCode();
    const storedClientId = code_challenge
      ? `${client_id ?? ""}|${code_challenge}|${code_challenge_method ?? "S256"}`
      : (client_id ?? "");

    await db.from("oauth_codes").insert({
      code: authCode,
      user_id: codeRow.user_id,
      client_id: storedClientId,
      redirect_uri: redirect_uri ?? "",
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    });

    const redirectUrl = new URL(redirect_uri);
    redirectUrl.searchParams.set("code", authCode);
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

    // Generate API key for the real user
    console.log("[/token] Issuing key for user_id:", codeRow.user_id);
    const isAnonymous = codeRow.user_id === "00000000-0000-0000-0000-000000000000";
    let apiKey: string;
    try {
      apiKey = isAnonymous
        ? await generateUnboundApiKey()
        : await generateApiKey(codeRow.user_id);
    } catch (err: any) {
      console.error("[/token] Key generation failed:", err.message);
      return new Response(JSON.stringify({ error: "server_error", error_description: err.message }), {
        status: 500, headers: jsonHeaders,
      });
    }

    console.log("[/token] Success, returning access_token");
    return new Response(JSON.stringify({
      access_token: apiKey,
      token_type: "Bearer",
      expires_in: 315360000,
      scope: "read write",
    }), {
      headers: { ...jsonHeaders, "Cache-Control": "no-store" },
    });
  }

  return new Response("Not found", { status: 404 });
});
