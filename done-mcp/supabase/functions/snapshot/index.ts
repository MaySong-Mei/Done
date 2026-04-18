// Done Snapshot Edge Function
// GET /functions/v1/snapshot?token=<token>
// Returns a Markdown summary of the user's life data for AI context.
// Token is valid for 5 minutes and single-use after fetch.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS });
  }

  if (req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }

  const token = new URL(req.url).searchParams.get("token");
  if (!token) {
    return new Response("Missing token", { status: 400 });
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Validate token
  const { data: snap, error: snapErr } = await db
    .from("snapshots")
    .select("user_id, expires_at")
    .eq("token", token)
    .single();

  if (snapErr || !snap) {
    return new Response("Invalid or expired token", { status: 404 });
  }

  if (new Date(snap.expires_at) < new Date()) {
    return new Response("Token expired", { status: 410 });
  }

  // Delete token immediately (single-use)
  await db.from("snapshots").delete().eq("token", token);

  const userId = snap.user_id;
  const now = new Date();
  const past30 = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const future30 = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString();

  // Fetch data in parallel
  const [eventsRes, logsRes, skillsRes] = await Promise.all([
    db
      .from("events")
      .select("title, kind, type, tags, status, is_done, time_ranges, deadline, note, priority")
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .limit(200),
    db
      .from("event_logs")
      .select("occurrence_date, effort, emotions, behaviors, summary, note, actual_duration_minutes")
      .eq("user_id", userId)
      .gte("occurrence_date", past30)
      .order("occurrence_date", { ascending: false })
      .limit(100),
    db
      .from("skill_insights")
      .select("skill_name, points, date, event_title")
      .eq("user_id", userId)
      .order("date", { ascending: false })
      .limit(200),
  ]);

  const events = eventsRes.data ?? [];
  const logs = logsRes.data ?? [];
  const skills = skillsRes.data ?? [];

  // Filter events to relevant window
  const upcomingEvents = events.filter((e: any) => {
    const ranges = e.time_ranges as Array<{ start: string; end: string }> | null;
    if (!ranges?.length) return false;
    return ranges.some((r) => new Date(r.end) >= now && new Date(r.start) <= new Date(future30));
  });

  const recentTodos = events.filter((e: any) => {
    if (e.kind !== "todo") return false;
    if (e.is_done) return false;
    return true;
  }).slice(0, 30);

  // Aggregate skills
  const skillTotals: Record<string, number> = {};
  for (const s of skills) {
    skillTotals[s.skill_name] = (skillTotals[s.skill_name] || 0) + s.points;
  }
  const topSkills = Object.entries(skillTotals)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10);

  // Aggregate recent emotions and behaviors
  const emotionCounts: Record<string, number> = {};
  const behaviorCounts: Record<string, number> = {};
  let totalEffort = 0;
  for (const log of logs) {
    for (const e of (log.emotions as string[]) ?? []) emotionCounts[e] = (emotionCounts[e] || 0) + 1;
    for (const b of (log.behaviors as string[]) ?? []) behaviorCounts[b] = (behaviorCounts[b] || 0) + 1;
    if (log.effort) totalEffort += log.effort;
  }
  const avgEffort = logs.length > 0 ? (totalEffort / logs.length).toFixed(1) : "—";

  const topEmotions = Object.entries(emotionCounts).sort((a, b) => b[1] - a[1]).slice(0, 5);
  const topBehaviors = Object.entries(behaviorCounts).sort((a, b) => b[1] - a[1]).slice(0, 5);

  // Build Markdown
  const lines: string[] = [];

  lines.push(`# Done — AI Context Snapshot`);
  lines.push(`Generated: ${now.toISOString()} | Window: past 30 days + next 30 days`);
  lines.push(``);

  // Upcoming calendar events
  lines.push(`## Upcoming Events (next 30 days)`);
  if (upcomingEvents.length === 0) {
    lines.push(`_No upcoming events._`);
  } else {
    for (const e of upcomingEvents) {
      const ranges = e.time_ranges as Array<{ start: string; end: string }>;
      const start = ranges[0]?.start ? new Date(ranges[0].start).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "?";
      const type = e.type ? ` [${e.type}]` : "";
      const note = e.note ? ` — ${e.note}` : "";
      lines.push(`- **${e.title}**${type} @ ${start}${note}`);
    }
  }
  lines.push(``);

  // Active todos
  lines.push(`## Active Todos`);
  if (recentTodos.length === 0) {
    lines.push(`_No active todos._`);
  } else {
    for (const e of recentTodos) {
      const tags = (e.tags as string[])?.length ? ` #${(e.tags as string[]).join(" #")}` : "";
      const priority = e.priority ? ` (priority: ${e.priority})` : "";
      lines.push(`- ${e.title}${tags}${priority}`);
    }
  }
  lines.push(``);

  // Recent activity logs
  lines.push(`## Recent Activity Logs (past 30 days, ${logs.length} entries)`);
  lines.push(`Average effort: ${avgEffort}/5`);
  if (logs.length > 0) {
    lines.push(``);
    for (const log of logs.slice(0, 20)) {
      const date = new Date(log.occurrence_date).toLocaleDateString("en-US", { month: "short", day: "numeric" });
      const effort = log.effort ? ` effort:${log.effort}` : "";
      const emotions = (log.emotions as string[])?.length ? ` emotions:[${(log.emotions as string[]).join(",")}]` : "";
      const behaviors = (log.behaviors as string[])?.length ? ` behaviors:[${(log.behaviors as string[]).join(",")}]` : "";
      const mins = log.actual_duration_minutes ? ` ${log.actual_duration_minutes}min` : "";
      const note = log.note ? `\n  > ${log.note}` : "";
      lines.push(`- ${date}${effort}${emotions}${behaviors}${mins}${note}`);
    }
  }
  lines.push(``);

  // Patterns
  lines.push(`## Patterns (past 30 days)`);
  if (topEmotions.length > 0) {
    lines.push(`**Top emotions:** ${topEmotions.map(([e, n]) => `${e}(${n})`).join(", ")}`);
  }
  if (topBehaviors.length > 0) {
    lines.push(`**Top behaviors:** ${topBehaviors.map(([b, n]) => `${b}(${n})`).join(", ")}`);
  }
  lines.push(``);

  // Skills
  lines.push(`## Skills (all time)`);
  if (topSkills.length === 0) {
    lines.push(`_No skill data yet._`);
  } else {
    for (const [skill, hours] of topSkills) {
      lines.push(`- **${skill}**: ${Math.round(hours * 10) / 10}h`);
    }
  }
  lines.push(``);
  lines.push(`---`);
  lines.push(`_This snapshot was generated from the Done app. Data is accurate as of generation time._`);

  return new Response(lines.join("\n"), {
    headers: {
      ...CORS,
      "Content-Type": "text/markdown; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
});
