// Done MCP Edge Function
// Implements MCP (Model Context Protocol) over Streamable HTTP.
// Auth: Bearer token (Supabase JWT or dk_ API key).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";
import { resolveUserId } from "../_shared/auth.ts";

// ── Types ──

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: number | string;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id?: number | string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

// ── Tool Definitions ──

const TOOLS = [
  {
    name: "get_user_context",
    description:
      "Get the user's profile, event type definitions, skill summary, and recent emotional/behavioral patterns. Call this first to understand who the user is.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "query_events",
    description:
      "Query the user's calendar events and todos. Filter by date range, event type, status, or keyword.",
    inputSchema: {
      type: "object",
      properties: {
        date_from: { type: "string", description: "Start date (ISO 8601)" },
        date_to: { type: "string", description: "End date (ISO 8601)" },
        types: {
          type: "array",
          items: { type: "string" },
          description: "Filter by event type names",
        },
        kind: { type: "string", enum: ["calendar", "todo"] },
        status: { type: "string", enum: ["active", "completed", "archived"] },
        keyword: { type: "string", description: "Search in title and note" },
        limit: { type: "number", description: "Max results (default 50)" },
      },
    },
  },
  {
    name: "query_logs",
    description:
      "Query activity logs — reflections after completing events. Includes effort rating (1-5), emotions, behaviors, notes, and duration.",
    inputSchema: {
      type: "object",
      properties: {
        date_from: { type: "string" },
        date_to: { type: "string" },
        event_ids: { type: "array", items: { type: "string" } },
        emotions: {
          type: "array",
          items: { type: "string" },
          description:
            "Options: calm, focused, energized, happy, neutral, stressed, anxious, frustrated, tired, overwhelmed",
        },
        behaviors: {
          type: "array",
          items: { type: "string" },
          description:
            "Options: deep_work, distracted, proactive, avoidant, consistent, rushed, interrupted, collaborative, delayed, as_planned",
        },
        min_effort: { type: "number" },
        max_effort: { type: "number" },
        limit: { type: "number" },
      },
    },
  },
  {
    name: "get_skills",
    description:
      "Get skill insights extracted from activities. Shows practice hours per skill with reasoning.",
    inputSchema: {
      type: "object",
      properties: {
        skill_name: { type: "string" },
        date_from: { type: "string" },
        date_to: { type: "string" },
        limit: { type: "number" },
      },
    },
  },
  {
    name: "save_insight",
    description:
      "Save an insight about the user's patterns, trends, or milestones. Stored separately from user data.",
    inputSchema: {
      type: "object",
      properties: {
        insight_type: {
          type: "string",
          enum: ["pattern", "trend", "milestone", "observation"],
        },
        content: { type: "string" },
        related_event_ids: { type: "array", items: { type: "string" } },
        period_start: { type: "string" },
        period_end: { type: "string" },
      },
      required: ["insight_type", "content"],
    },
  },
  {
    name: "save_summary",
    description: "Save a summary of the user's activities for a time period.",
    inputSchema: {
      type: "object",
      properties: {
        period_start: { type: "string" },
        period_end: { type: "string" },
        content: { type: "string" },
      },
      required: ["period_start", "period_end", "content"],
    },
  },
  {
    name: "leave_question",
    description:
      "Leave a question for the user to answer in-app. Use when you notice something interesting but need more context.",
    inputSchema: {
      type: "object",
      properties: {
        content: { type: "string" },
        related_event_ids: { type: "array", items: { type: "string" } },
      },
      required: ["content"],
    },
  },
  {
    name: "authenticate",
    description:
      "Link this session to a Done account. Call this when the user wants to access their personal data. Ask the user for their Done email and password, then call this tool.",
    inputSchema: {
      type: "object",
      properties: {
        email: { type: "string", description: "User's Done account email" },
        password: { type: "string", description: "User's Done account password" },
      },
      required: ["email", "password"],
    },
  },
];

// ── DB helpers ──

function getDb() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
}

// ── Tool Implementations ──

async function getUserContext(userId: string) {
  const db = getDb();

  const [typesRes, statsRes, skillsRes, recentLogsRes] = await Promise.all([
    db.from("event_types").select("id, title, color_hex").eq("user_id", userId),
    db.from("events").select("kind, type, status", { count: "exact" }).eq("user_id", userId),
    db.from("skill_insights").select("skill_name, points").eq("user_id", userId),
    db.from("event_logs")
      .select("occurrence_date, effort, emotions, behaviors, completion_status")
      .eq("user_id", userId)
      .order("occurrence_date", { ascending: false })
      .limit(20),
  ]);

  const typeCounts: Record<string, number> = {};
  for (const e of statsRes.data ?? []) {
    const t = (e as any).type || "(untyped)";
    typeCounts[t] = (typeCounts[t] || 0) + 1;
  }

  const skillTotals: Record<string, number> = {};
  for (const s of skillsRes.data ?? []) {
    skillTotals[(s as any).skill_name] =
      (skillTotals[(s as any).skill_name] || 0) + (s as any).points;
  }
  const topSkills = Object.entries(skillTotals)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([name, points]) => ({ name, totalHours: Math.round(points * 10) / 10 }));

  const emotionCounts: Record<string, number> = {};
  const behaviorCounts: Record<string, number> = {};
  for (const log of recentLogsRes.data ?? []) {
    for (const e of (log as any).emotions ?? []) emotionCounts[e] = (emotionCounts[e] || 0) + 1;
    for (const b of (log as any).behaviors ?? []) behaviorCounts[b] = (behaviorCounts[b] || 0) + 1;
  }

  return {
    user_id: userId,
    event_types: (typesRes.data ?? []).map((t: any) => ({ title: t.title, color: t.color_hex })),
    event_type_distribution: typeCounts,
    total_events: statsRes.count ?? (statsRes.data ?? []).length,
    top_skills: topSkills,
    recent_emotion_frequency: emotionCounts,
    recent_behavior_frequency: behaviorCounts,
    available_emotions: ["calm","focused","energized","happy","neutral","stressed","anxious","frustrated","tired","overwhelmed"],
    available_behaviors: ["deep_work","distracted","proactive","avoidant","consistent","rushed","interrupted","collaborative","delayed","as_planned"],
  };
}

async function queryEvents(userId: string, input: any) {
  const db = getDb();
  let query = db
    .from("events")
    .select("id, kind, title, note, location, type, additional_types, tags, priority, status, is_all_day, is_done, color_depth, time_ranges, deadline, complete_at, repeat_unit, repeat_interval, display_kind, created_at, updated_at")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(input.limit ?? 50);

  if (input.kind) query = query.eq("kind", input.kind);
  if (input.status) query = query.eq("status", input.status);
  if (input.types?.length) query = query.in("type", input.types);
  if (input.keyword) query = query.or(`title.ilike.%${input.keyword}%,note.ilike.%${input.keyword}%`);
  if (input.date_from) query = query.gte("created_at", input.date_from);

  const { data, error } = await query;
  if (error) throw new Error(`query_events: ${error.message}`);

  let results = data ?? [];
  if (input.date_from || input.date_to) {
    const from = input.date_from ? new Date(input.date_from).getTime() : 0;
    const to = input.date_to ? new Date(input.date_to).getTime() : Number.MAX_SAFE_INTEGER;
    results = results.filter((e: any) => {
      const ranges = e.time_ranges as Array<{ start: string; end: string }>;
      if (!ranges?.length) return new Date(e.created_at).getTime() >= from && new Date(e.created_at).getTime() <= to;
      return ranges.some((r) => new Date(r.end).getTime() >= from && new Date(r.start).getTime() <= to);
    });
  }
  return { count: results.length, events: results };
}

async function queryLogs(userId: string, input: any) {
  const db = getDb();
  let query = db.from("event_logs").select("*").eq("user_id", userId)
    .order("occurrence_date", { ascending: false }).limit(input.limit ?? 50);

  if (input.date_from) query = query.gte("occurrence_date", input.date_from);
  if (input.date_to) query = query.lte("occurrence_date", input.date_to);
  if (input.event_ids?.length) query = query.in("event_id", input.event_ids);
  if (input.emotions?.length) query = query.overlaps("emotions", input.emotions);
  if (input.behaviors?.length) query = query.overlaps("behaviors", input.behaviors);
  if (input.min_effort != null) query = query.gte("effort", input.min_effort);
  if (input.max_effort != null) query = query.lte("effort", input.max_effort);

  const { data, error } = await query;
  if (error) throw new Error(`query_logs: ${error.message}`);
  return { count: (data ?? []).length, logs: data ?? [] };
}

async function getSkills(userId: string, input: any) {
  const db = getDb();
  let query = db.from("skill_insights").select("*").eq("user_id", userId)
    .order("date", { ascending: false }).limit(input.limit ?? 100);

  if (input.skill_name) query = query.eq("skill_name", input.skill_name);
  if (input.date_from) query = query.gte("date", input.date_from);
  if (input.date_to) query = query.lte("date", input.date_to);

  const { data, error } = await query;
  if (error) throw new Error(`get_skills: ${error.message}`);

  const totals: Record<string, number> = {};
  for (const s of data ?? []) totals[s.skill_name] = (totals[s.skill_name] || 0) + s.points;
  const aggregated = Object.entries(totals).sort((a, b) => b[1] - a[1])
    .map(([skill, hours]) => ({ skill, total_hours: Math.round(hours * 10) / 10 }));

  return { count: (data ?? []).length, insights: data ?? [], aggregated };
}

async function saveInsight(userId: string, input: any) {
  const db = getDb();
  const { data, error } = await db.from("ai_insights").insert({
    user_id: userId, insight_type: input.insight_type, content: input.content,
    related_event_ids: input.related_event_ids ?? [],
    period_start: input.period_start ?? null, period_end: input.period_end ?? null,
    model: "mcp-remote",
  }).select("id").single();
  if (error) throw new Error(`save_insight: ${error.message}`);
  return { id: data.id, status: "saved" };
}

async function saveSummary(userId: string, input: any) {
  const db = getDb();
  const { data, error } = await db.from("ai_summaries").insert({
    user_id: userId, period_start: input.period_start, period_end: input.period_end,
    content: input.content, model: "mcp-remote",
  }).select("id").single();
  if (error) throw new Error(`save_summary: ${error.message}`);
  return { id: data.id, status: "saved" };
}

async function leaveQuestion(userId: string, input: any) {
  const db = getDb();
  const { data, error } = await db.from("ai_questions").insert({
    user_id: userId, content: input.content,
    related_event_ids: input.related_event_ids ?? [], model: "mcp-remote",
  }).select("id").single();
  if (error) throw new Error(`leave_question: ${error.message}`);
  return { id: data.id, status: "saved" };
}

// ── Authenticate tool ──

const ANON_USER_ID = "00000000-0000-0000-0000-000000000001";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

async function authenticateUser(currentUserId: string, bearerToken: string, args: { email: string; password: string }) {
  // Sign in with Supabase Auth to verify credentials
  const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { data, error } = await authClient.auth.signInWithPassword({
    email: args.email,
    password: args.password,
  });

  if (error || !data.user) {
    throw new Error("Invalid email or password. Please try again.");
  }

  const realUserId = data.user.id;

  // Rebind the API key from anonymous to real user
  if (bearerToken.startsWith("dk_")) {
    const db = getDb();
    const hashBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(bearerToken));
    const keyHash = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, "0")).join("");

    await db.from("api_keys").update({
      user_id: realUserId,
      label: `Linked (${args.email})`,
    }).eq("key_hash", keyHash);
  }

  return {
    status: "authenticated",
    email: data.user.email,
    message: `Successfully linked to ${data.user.email}. You can now access their life data.`,
  };
}

// ── Tool dispatch ──

async function callTool(userId: string, name: string, args: any, bearerToken: string): Promise<unknown> {
  // For data tools, check if user is authenticated
  if (name !== "authenticate" && userId === ANON_USER_ID) {
    return {
      error: "not_authenticated",
      message: "This session is not linked to a Done account yet. Please ask the user for their Done email and password, then call the `authenticate` tool.",
    };
  }

  switch (name) {
    case "authenticate": return authenticateUser(userId, bearerToken, args);
    case "get_user_context": return getUserContext(userId);
    case "query_events": return queryEvents(userId, args);
    case "query_logs": return queryLogs(userId, args);
    case "get_skills": return getSkills(userId, args);
    case "save_insight": return saveInsight(userId, args);
    case "save_summary": return saveSummary(userId, args);
    case "leave_question": return leaveQuestion(userId, args);
    default: throw new Error(`Unknown tool: ${name}`);
  }
}

// ── MCP JSON-RPC handler ──

function handleMessage(msg: JsonRpcRequest, userId: string, bearerToken: string): Promise<JsonRpcResponse> | JsonRpcResponse {
  const { id, method, params } = msg;

  switch (method) {
    case "initialize":
      return {
        jsonrpc: "2.0", id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "done-life-log", version: "0.1.0" },
        },
      };

    case "notifications/initialized":
      // No response needed for notifications
      return { jsonrpc: "2.0", id } as any;

    case "tools/list":
      return {
        jsonrpc: "2.0", id,
        result: { tools: TOOLS },
      };

    case "tools/call": {
      const toolName = (params as any)?.name;
      const toolArgs = (params as any)?.arguments ?? {};
      return (async (): Promise<JsonRpcResponse> => {
        try {
          const result = await callTool(userId, toolName, toolArgs, bearerToken);
          return {
            jsonrpc: "2.0", id,
            result: {
              content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
            },
          };
        } catch (err: any) {
          return {
            jsonrpc: "2.0", id,
            error: { code: -32000, message: err.message },
          };
        }
      })();
    }

    default:
      return {
        jsonrpc: "2.0", id,
        error: { code: -32601, message: `Method not found: ${method}` },
      };
  }
}

// ── OAuth Discovery Metadata ──

const MCP_BASE = "https://uqnvtzblppjblwgbpqhf.supabase.co/functions/v1/mcp";
const OAUTH_BASE = "https://uqnvtzblppjblwgbpqhf.supabase.co/functions/v1/oauth";

const PROTECTED_RESOURCE_METADATA = {
  resource: MCP_BASE,
  authorization_servers: [MCP_BASE],
  bearer_methods_supported: ["header"],
};

const AUTHORIZATION_SERVER_METADATA = {
  issuer: MCP_BASE,
  authorization_endpoint: `${OAUTH_BASE}/authorize`,
  token_endpoint: `${OAUTH_BASE}/token`,
  registration_endpoint: `${MCP_BASE}/register`,
  response_types_supported: ["code"],
  grant_types_supported: ["authorization_code"],
  code_challenge_methods_supported: ["S256"],
  token_endpoint_auth_methods_supported: ["client_secret_post", "none"],
  scopes_supported: ["read", "write"],
};

// ── Dynamic Client Registration ──

const dynamicClients = new Map<string, { client_id: string; redirect_uris: string[] }>();

function handleRegister(body: any): Response {
  const clientId = "dyn_" + crypto.randomUUID().replace(/-/g, "").slice(0, 16);
  const redirectUris = body.redirect_uris ?? [];
  dynamicClients.set(clientId, { client_id: clientId, redirect_uris: redirectUris });

  return new Response(JSON.stringify({
    client_id: clientId,
    client_name: body.client_name ?? "ChatGPT",
    redirect_uris: redirectUris,
    grant_types: ["authorization_code"],
    response_types: ["code"],
    token_endpoint_auth_method: body.token_endpoint_auth_method ?? "none",
  }), {
    status: 201,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}

// ── HTTP handler ──

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;
  const jsonHeaders = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" };

  // CORS
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id",
      },
    });
  }

  // ── Well-known OAuth discovery endpoints ──
  // ChatGPT may request these with various path patterns:
  //   /.well-known/oauth-protected-resource
  //   /.well-known/oauth-authorization-server
  //   /.well-known/oauth-authorization-server/functions/v1/mcp  (path-scoped)
  if (req.method === "GET" && path.includes("/.well-known/oauth-protected-resource")) {
    return new Response(JSON.stringify(PROTECTED_RESOURCE_METADATA), { headers: jsonHeaders });
  }

  if (req.method === "GET" && path.includes("/.well-known/oauth-authorization-server")) {
    return new Response(JSON.stringify(AUTHORIZATION_SERVER_METADATA), { headers: jsonHeaders });
  }

  // ── Dynamic Client Registration ──
  if (req.method === "POST" && path.endsWith("/register")) {
    try {
      const body = await req.json();
      return handleRegister(body);
    } catch {
      return new Response(JSON.stringify({ error: "Invalid JSON" }), { status: 400, headers: jsonHeaders });
    }
  }

  // GET → server info
  if (req.method === "GET") {
    return new Response(JSON.stringify({ name: "done-life-log", version: "0.1.0" }), {
      headers: jsonHeaders,
    });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  // Auth: extract user_id from JWT, API key header, or ?token= query param
  const authHeader = req.headers.get("Authorization");
  const queryToken = new URL(req.url).searchParams.get("token");
  const effectiveAuth = authHeader ?? (queryToken ? `Bearer ${queryToken}` : null);
  const userId = await resolveUserId(effectiveAuth);

  // Parse JSON-RPC
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400, headers: jsonHeaders,
    });
  }

  // Allow initialize / tools/list without auth so Claude.ai can verify
  // this is an MCP server before starting the OAuth flow.
  const messages = Array.isArray(body) ? body : [body];
  const firstMethod = (messages[0] as any)?.method;
  const isPublicMethod = firstMethod === "initialize"
    || firstMethod === "tools/list"
    || firstMethod === "notifications/initialized";

  if (!userId && !isPublicMethod) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: {
        ...jsonHeaders,
        "WWW-Authenticate": `Bearer realm="Done", resource_metadata="${MCP_BASE}/.well-known/oauth-protected-resource"`,
      },
    });
  }

  const responses: JsonRpcResponse[] = [];

  // Extract the raw bearer token for authenticate tool
  const rawToken = (effectiveAuth?.startsWith("Bearer ") ? effectiveAuth.slice(7) : "") ?? "";

  for (const msg of messages) {
    const result = handleMessage(msg as JsonRpcRequest, userId ?? ANON_USER_ID, rawToken);
    const resolved = result instanceof Promise ? await result : result;
    if (msg.id !== undefined) {
      responses.push(resolved);
    }
  }

  const output = responses.length === 1 ? responses[0] : responses;
  return new Response(JSON.stringify(output), { headers: jsonHeaders });
});
