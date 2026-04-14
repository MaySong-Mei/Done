import { z } from "zod";
import { getDb, getUserId } from "../db.js";

export const getSkillsSchema = z.object({
  skill_name: z
    .string()
    .optional()
    .describe("Filter by skill name (exact match)."),
  date_from: z
    .string()
    .optional()
    .describe("Start date (ISO 8601)."),
  date_to: z
    .string()
    .optional()
    .describe("End date (ISO 8601)."),
  limit: z
    .number()
    .int()
    .min(1)
    .max(200)
    .optional()
    .describe("Max results (default 100)."),
});

export type GetSkillsInput = z.infer<typeof getSkillsSchema>;

export async function getSkills(input: GetSkillsInput) {
  const db = getDb();
  const userId = getUserId();

  let query = db
    .from("skill_insights")
    .select("*")
    .eq("user_id", userId)
    .order("date", { ascending: false })
    .limit(input.limit ?? 100);

  if (input.skill_name)
    query = query.eq("skill_name", input.skill_name);
  if (input.date_from) query = query.gte("date", input.date_from);
  if (input.date_to) query = query.lte("date", input.date_to);

  const { data, error } = await query;
  if (error) throw new Error(`get_skills failed: ${error.message}`);

  // Also compute aggregates
  const totals: Record<string, number> = {};
  for (const s of data ?? []) {
    totals[s.skill_name] = (totals[s.skill_name] || 0) + s.points;
  }
  const aggregated = Object.entries(totals)
    .sort((a, b) => b[1] - a[1])
    .map(([name, hours]) => ({ skill: name, total_hours: Math.round(hours * 10) / 10 }));

  return {
    count: (data ?? []).length,
    insights: data ?? [],
    aggregated,
  };
}
