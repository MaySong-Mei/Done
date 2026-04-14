import { getDb, getUserId } from "../db.js";

export async function getUserContext() {
  const db = getDb();
  const userId = getUserId();

  // Fetch event types, recent activity stats, and skill summary in parallel
  const [typesRes, statsRes, skillsRes, recentLogsRes] = await Promise.all([
    db
      .from("event_types")
      .select("id, title, color_hex")
      .eq("user_id", userId),

    db
      .from("events")
      .select("kind, type, status", { count: "exact" })
      .eq("user_id", userId),

    db
      .from("skill_insights")
      .select("skill_name, points")
      .eq("user_id", userId),

    db
      .from("event_logs")
      .select("occurrence_date, effort, emotions, behaviors, completion_status")
      .eq("user_id", userId)
      .order("occurrence_date", { ascending: false })
      .limit(20),
  ]);

  // Compute event type distribution
  const typeCounts: Record<string, number> = {};
  for (const e of statsRes.data ?? []) {
    const t = (e as any).type || "(untyped)";
    typeCounts[t] = (typeCounts[t] || 0) + 1;
  }

  // Compute skill totals
  const skillTotals: Record<string, number> = {};
  for (const s of skillsRes.data ?? []) {
    const name = (s as any).skill_name;
    skillTotals[name] = (skillTotals[name] || 0) + (s as any).points;
  }
  const topSkills = Object.entries(skillTotals)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([name, points]) => ({ name, totalHours: Math.round(points * 10) / 10 }));

  // Recent emotion/behavior frequency
  const emotionCounts: Record<string, number> = {};
  const behaviorCounts: Record<string, number> = {};
  for (const log of recentLogsRes.data ?? []) {
    for (const e of (log as any).emotions ?? [])
      emotionCounts[e] = (emotionCounts[e] || 0) + 1;
    for (const b of (log as any).behaviors ?? [])
      behaviorCounts[b] = (behaviorCounts[b] || 0) + 1;
  }

  return {
    user_id: userId,
    event_types: (typesRes.data ?? []).map((t: any) => ({
      title: t.title,
      color: t.color_hex,
    })),
    event_type_distribution: typeCounts,
    total_events: statsRes.count ?? (statsRes.data ?? []).length,
    top_skills: topSkills,
    recent_emotion_frequency: emotionCounts,
    recent_behavior_frequency: behaviorCounts,
    available_emotions: [
      "calm", "focused", "energized", "happy", "neutral",
      "stressed", "anxious", "frustrated", "tired", "overwhelmed",
    ],
    available_behaviors: [
      "deep_work", "distracted", "proactive", "avoidant", "consistent",
      "rushed", "interrupted", "collaborative", "delayed", "as_planned",
    ],
  };
}
