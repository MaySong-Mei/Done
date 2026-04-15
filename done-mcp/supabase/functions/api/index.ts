// Done REST API for ChatGPT Actions / external integrations.
// Exposes the same tools as the MCP server but as standard REST endpoints.
// Auth: Bearer token (Supabase JWT or dk_ API key).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";
import { resolveUserId } from "../_shared/auth.ts";

function getDb() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
}

// ── Handlers ──

async function getUserContext(userId: string) {
  const db = getDb();
  const [typesRes, statsRes, skillsRes, recentLogsRes] = await Promise.all([
    db.from("event_types").select("id, title, color_hex").eq("user_id", userId),
    db.from("events").select("kind, type, status", { count: "exact" }).eq("user_id", userId),
    db.from("skill_insights").select("skill_name, points").eq("user_id", userId),
    db.from("event_logs")
      .select("occurrence_date, effort, emotions, behaviors, completion_status")
      .eq("user_id", userId).order("occurrence_date", { ascending: false }).limit(20),
  ]);

  const typeCounts: Record<string, number> = {};
  for (const e of statsRes.data ?? []) {
    const t = (e as any).type || "(untyped)";
    typeCounts[t] = (typeCounts[t] || 0) + 1;
  }
  const skillTotals: Record<string, number> = {};
  for (const s of skillsRes.data ?? [])
    skillTotals[(s as any).skill_name] = (skillTotals[(s as any).skill_name] || 0) + (s as any).points;
  const topSkills = Object.entries(skillTotals).sort((a, b) => b[1] - a[1]).slice(0, 10)
    .map(([name, points]) => ({ name, totalHours: Math.round(points * 10) / 10 }));

  const emotionCounts: Record<string, number> = {};
  const behaviorCounts: Record<string, number> = {};
  for (const log of recentLogsRes.data ?? []) {
    for (const e of (log as any).emotions ?? []) emotionCounts[e] = (emotionCounts[e] || 0) + 1;
    for (const b of (log as any).behaviors ?? []) behaviorCounts[b] = (behaviorCounts[b] || 0) + 1;
  }

  return {
    event_types: (typesRes.data ?? []).map((t: any) => ({ title: t.title, color: t.color_hex })),
    event_type_distribution: typeCounts,
    total_events: statsRes.count ?? (statsRes.data ?? []).length,
    top_skills: topSkills,
    recent_emotion_frequency: emotionCounts,
    recent_behavior_frequency: behaviorCounts,
  };
}

async function queryEvents(userId: string, params: URLSearchParams) {
  const db = getDb();
  const limit = Math.min(parseInt(params.get("limit") || "50"), 200);
  let query = db.from("events")
    .select("id, kind, title, note, location, type, tags, status, is_done, time_ranges, created_at")
    .eq("user_id", userId).order("created_at", { ascending: false }).limit(limit);

  const types = params.get("types");
  if (types) query = query.in("type", types.split(","));
  const kind = params.get("kind");
  if (kind) query = query.eq("kind", kind);
  const status = params.get("status");
  if (status) query = query.eq("status", status);
  const keyword = params.get("keyword");
  if (keyword) query = query.or(`title.ilike.%${keyword}%,note.ilike.%${keyword}%`);
  const dateFrom = params.get("date_from");
  if (dateFrom) query = query.gte("created_at", dateFrom);

  const { data, error } = await query;
  if (error) throw error;

  let results = data ?? [];
  if (dateFrom || params.get("date_to")) {
    const from = dateFrom ? new Date(dateFrom).getTime() : 0;
    const to = params.get("date_to") ? new Date(params.get("date_to")!).getTime() : Number.MAX_SAFE_INTEGER;
    results = results.filter((e: any) => {
      const ranges = e.time_ranges as Array<{ start: string; end: string }>;
      if (!ranges?.length) { const ct = new Date(e.created_at).getTime(); return ct >= from && ct <= to; }
      return ranges.some((r) => new Date(r.end).getTime() >= from && new Date(r.start).getTime() <= to);
    });
  }
  return { count: results.length, events: results };
}

async function queryLogs(userId: string, params: URLSearchParams) {
  const db = getDb();
  const limit = Math.min(parseInt(params.get("limit") || "50"), 200);
  let query = db.from("event_logs").select("*").eq("user_id", userId)
    .order("occurrence_date", { ascending: false }).limit(limit);

  const dateFrom = params.get("date_from");
  if (dateFrom) query = query.gte("occurrence_date", dateFrom);
  const dateTo = params.get("date_to");
  if (dateTo) query = query.lte("occurrence_date", dateTo);
  const emotions = params.get("emotions");
  if (emotions) query = query.overlaps("emotions", emotions.split(","));
  const behaviors = params.get("behaviors");
  if (behaviors) query = query.overlaps("behaviors", behaviors.split(","));
  const minEffort = params.get("min_effort");
  if (minEffort) query = query.gte("effort", parseInt(minEffort));
  const maxEffort = params.get("max_effort");
  if (maxEffort) query = query.lte("effort", parseInt(maxEffort));

  const { data, error } = await query;
  if (error) throw error;
  return { count: (data ?? []).length, logs: data ?? [] };
}

async function getSkills(userId: string, params: URLSearchParams) {
  const db = getDb();
  const limit = Math.min(parseInt(params.get("limit") || "100"), 200);
  let query = db.from("skill_insights").select("*").eq("user_id", userId)
    .order("date", { ascending: false }).limit(limit);

  const name = params.get("skill_name");
  if (name) query = query.eq("skill_name", name);
  const dateFrom = params.get("date_from");
  if (dateFrom) query = query.gte("date", dateFrom);
  const dateTo = params.get("date_to");
  if (dateTo) query = query.lte("date", dateTo);

  const { data, error } = await query;
  if (error) throw error;

  const totals: Record<string, number> = {};
  for (const s of data ?? []) totals[s.skill_name] = (totals[s.skill_name] || 0) + s.points;
  const aggregated = Object.entries(totals).sort((a, b) => b[1] - a[1])
    .map(([skill, hours]) => ({ skill, total_hours: Math.round(hours * 10) / 10 }));
  return { count: (data ?? []).length, insights: data ?? [], aggregated };
}

async function saveInsight(userId: string, body: any) {
  const db = getDb();
  const { data, error } = await db.from("ai_insights").insert({
    user_id: userId, insight_type: body.insight_type, content: body.content,
    related_event_ids: body.related_event_ids ?? [],
    period_start: body.period_start ?? null, period_end: body.period_end ?? null,
    model: "chatgpt",
  }).select("id").single();
  if (error) throw error;
  return { id: data.id, status: "saved" };
}

async function saveSummary(userId: string, body: any) {
  const db = getDb();
  const { data, error } = await db.from("ai_summaries").insert({
    user_id: userId, period_start: body.period_start, period_end: body.period_end,
    content: body.content, model: "chatgpt",
  }).select("id").single();
  if (error) throw error;
  return { id: data.id, status: "saved" };
}

async function leaveQuestion(userId: string, body: any) {
  const db = getDb();
  const { data, error } = await db.from("ai_questions").insert({
    user_id: userId, content: body.content,
    related_event_ids: body.related_event_ids ?? [], model: "chatgpt",
  }).select("id").single();
  if (error) throw error;
  return { id: data.id, status: "saved" };
}

// ── Router ──

Deno.serve(async (req) => {
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

  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/api\/?/, "/").replace(/^\/functions\/v1\/api\/?/, "/");
  const headers = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" };

  // OpenAPI spec
  if (req.method === "GET" && (path === "/" || path === "/openapi.json")) {
    return new Response(JSON.stringify(OPENAPI_SPEC), { headers });
  }

  // Auth
  const userId = await resolveUserId(req.headers.get("Authorization"));
  if (!userId) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers });
  }

  try {
    const params = url.searchParams;

    if (req.method === "GET" && path === "/context") {
      return new Response(JSON.stringify(await getUserContext(userId)), { headers });
    }
    if (req.method === "GET" && path === "/events") {
      return new Response(JSON.stringify(await queryEvents(userId, params)), { headers });
    }
    if (req.method === "GET" && path === "/logs") {
      return new Response(JSON.stringify(await queryLogs(userId, params)), { headers });
    }
    if (req.method === "GET" && path === "/skills") {
      return new Response(JSON.stringify(await getSkills(userId, params)), { headers });
    }
    if (req.method === "POST" && path === "/insights") {
      const body = await req.json();
      return new Response(JSON.stringify(await saveInsight(userId, body)), { status: 201, headers });
    }
    if (req.method === "POST" && path === "/summaries") {
      const body = await req.json();
      return new Response(JSON.stringify(await saveSummary(userId, body)), { status: 201, headers });
    }
    if (req.method === "POST" && path === "/questions") {
      const body = await req.json();
      return new Response(JSON.stringify(await leaveQuestion(userId, body)), { status: 201, headers });
    }

    return new Response(JSON.stringify({ error: "Not found" }), { status: 404, headers });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500, headers });
  }
});

// ── OpenAPI Spec ──

const BASE_URL = "https://uqnvtzblppjblwgbpqhf.supabase.co/functions/v1/api";

const OPENAPI_SPEC = {
  openapi: "3.1.0",
  info: {
    title: "Done Life Log API",
    description: "Query a user's life activities, emotions, behaviors, and skills from the Done app. Save AI-generated insights and questions.",
    version: "0.1.0",
  },
  servers: [{ url: BASE_URL }],
  paths: {
    "/context": {
      get: {
        operationId: "getUserContext",
        summary: "Get user profile, event types, skill summary, and recent emotional patterns",
        responses: { "200": { description: "User context", content: { "application/json": { schema: {
          type: "object",
          properties: {
            event_types: { type: "array", items: { type: "object", properties: { title: { type: "string" }, color: { type: "string" } } } },
            event_type_distribution: { type: "object", additionalProperties: { type: "integer" } },
            total_events: { type: "integer" },
            top_skills: { type: "array", items: { type: "object", properties: { name: { type: "string" }, totalHours: { type: "number" } } } },
            recent_emotion_frequency: { type: "object", additionalProperties: { type: "integer" } },
            recent_behavior_frequency: { type: "object", additionalProperties: { type: "integer" } },
          },
        } } } } },
      },
    },
    "/events": {
      get: {
        operationId: "queryEvents",
        summary: "Query calendar events and todos",
        parameters: [
          { name: "types", in: "query", schema: { type: "string" }, description: "Comma-separated event types (e.g. Exercise,Study)" },
          { name: "kind", in: "query", schema: { type: "string", enum: ["calendar", "todo"] } },
          { name: "status", in: "query", schema: { type: "string", enum: ["active", "completed", "archived"] } },
          { name: "keyword", in: "query", schema: { type: "string" }, description: "Search in title and note" },
          { name: "date_from", in: "query", schema: { type: "string", format: "date-time" } },
          { name: "date_to", in: "query", schema: { type: "string", format: "date-time" } },
          { name: "limit", in: "query", schema: { type: "integer", default: 50, maximum: 200 } },
        ],
        responses: { "200": { description: "Events list", content: { "application/json": { schema: {
          type: "object",
          properties: {
            count: { type: "integer" },
            events: { type: "array", items: { type: "object", properties: {
              id: { type: "string" }, title: { type: "string" }, type: { type: "string" },
              kind: { type: "string" }, status: { type: "string" }, note: { type: "string" },
              time_ranges: { type: "array", items: { type: "object", properties: { start: { type: "string" }, end: { type: "string" } } } },
            } } },
          },
        } } } } },
      },
    },
    "/logs": {
      get: {
        operationId: "queryLogs",
        summary: "Query activity logs with emotions, behaviors, effort ratings",
        parameters: [
          { name: "emotions", in: "query", schema: { type: "string" }, description: "Comma-separated: calm,focused,energized,happy,neutral,stressed,anxious,frustrated,tired,overwhelmed" },
          { name: "behaviors", in: "query", schema: { type: "string" }, description: "Comma-separated: deep_work,distracted,proactive,avoidant,consistent,rushed,interrupted,collaborative,delayed,as_planned" },
          { name: "min_effort", in: "query", schema: { type: "integer", minimum: 1, maximum: 5 } },
          { name: "max_effort", in: "query", schema: { type: "integer", minimum: 1, maximum: 5 } },
          { name: "date_from", in: "query", schema: { type: "string", format: "date-time" } },
          { name: "date_to", in: "query", schema: { type: "string", format: "date-time" } },
          { name: "limit", in: "query", schema: { type: "integer", default: 50, maximum: 200 } },
        ],
        responses: { "200": { description: "Activity logs", content: { "application/json": { schema: {
          type: "object",
          properties: {
            count: { type: "integer" },
            logs: { type: "array", items: { type: "object", properties: {
              event_id: { type: "string" }, occurrence_date: { type: "string" },
              completion_status: { type: "string" }, actual_duration_minutes: { type: "integer" },
              summary: { type: "string" }, effort: { type: "integer" },
              emotions: { type: "array", items: { type: "string" } },
              behaviors: { type: "array", items: { type: "string" } },
            } } },
          },
        } } } } },
      },
    },
    "/skills": {
      get: {
        operationId: "getSkills",
        summary: "Get skill practice insights with aggregated hours",
        parameters: [
          { name: "skill_name", in: "query", schema: { type: "string" } },
          { name: "date_from", in: "query", schema: { type: "string", format: "date-time" } },
          { name: "date_to", in: "query", schema: { type: "string", format: "date-time" } },
          { name: "limit", in: "query", schema: { type: "integer", default: 100, maximum: 200 } },
        ],
        responses: { "200": { description: "Skill insights", content: { "application/json": { schema: {
          type: "object",
          properties: {
            count: { type: "integer" },
            aggregated: { type: "array", items: { type: "object", properties: {
              skill: { type: "string" }, total_hours: { type: "number" },
            } } },
          },
        } } } } },
      },
    },
    "/insights": {
      post: {
        operationId: "saveInsight",
        summary: "Save an AI-discovered pattern, trend, or milestone",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["insight_type", "content"],
                properties: {
                  insight_type: { type: "string", enum: ["pattern", "trend", "milestone", "observation"] },
                  content: { type: "string" },
                  related_event_ids: { type: "array", items: { type: "string" } },
                  period_start: { type: "string", format: "date-time" },
                  period_end: { type: "string", format: "date-time" },
                },
              },
            },
          },
        },
        responses: { "201": { description: "Insight saved", content: { "application/json": { schema: {
          type: "object", properties: { id: { type: "string" }, status: { type: "string" } },
        } } } } },
      },
    },
    "/summaries": {
      post: {
        operationId: "saveSummary",
        summary: "Save a period summary",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["period_start", "period_end", "content"],
                properties: {
                  period_start: { type: "string", format: "date-time" },
                  period_end: { type: "string", format: "date-time" },
                  content: { type: "string" },
                },
              },
            },
          },
        },
        responses: { "201": { description: "Summary saved", content: { "application/json": { schema: {
          type: "object", properties: { id: { type: "string" }, status: { type: "string" } },
        } } } } },
      },
    },
    "/questions": {
      post: {
        operationId: "leaveQuestion",
        summary: "Leave a question for the user to answer in the app",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["content"],
                properties: {
                  content: { type: "string" },
                  related_event_ids: { type: "array", items: { type: "string" } },
                },
              },
            },
          },
        },
        responses: { "201": { description: "Question saved", content: { "application/json": { schema: {
          type: "object", properties: { id: { type: "string" }, status: { type: "string" } },
        } } } } },
      },
    },
  },
};
