import { z } from "zod";
import { getDb, getUserId } from "../db.js";

export const queryLogsSchema = z.object({
  date_from: z
    .string()
    .optional()
    .describe("Start date (ISO 8601). Omit for no lower bound."),
  date_to: z
    .string()
    .optional()
    .describe("End date (ISO 8601). Omit for no upper bound."),
  event_ids: z
    .array(z.string())
    .optional()
    .describe("Filter by specific event IDs."),
  emotions: z
    .array(z.string())
    .optional()
    .describe(
      "Filter logs containing ANY of these emotions. Options: calm, focused, energized, happy, neutral, stressed, anxious, frustrated, tired, overwhelmed"
    ),
  behaviors: z
    .array(z.string())
    .optional()
    .describe(
      "Filter logs containing ANY of these behaviors. Options: deep_work, distracted, proactive, avoidant, consistent, rushed, interrupted, collaborative, delayed, as_planned"
    ),
  min_effort: z
    .number()
    .int()
    .min(1)
    .max(5)
    .optional()
    .describe("Minimum effort rating (1-5)."),
  max_effort: z
    .number()
    .int()
    .min(1)
    .max(5)
    .optional()
    .describe("Maximum effort rating (1-5)."),
  limit: z
    .number()
    .int()
    .min(1)
    .max(200)
    .optional()
    .describe("Max results (default 50)."),
});

export type QueryLogsInput = z.infer<typeof queryLogsSchema>;

export async function queryLogs(input: QueryLogsInput) {
  const db = getDb();
  const userId = getUserId();

  let query = db
    .from("event_logs")
    .select("*")
    .eq("user_id", userId)
    .order("occurrence_date", { ascending: false })
    .limit(input.limit ?? 50);

  if (input.date_from)
    query = query.gte("occurrence_date", input.date_from);
  if (input.date_to)
    query = query.lte("occurrence_date", input.date_to);
  if (input.event_ids?.length)
    query = query.in("event_id", input.event_ids);
  if (input.emotions?.length)
    query = query.overlaps("emotions", input.emotions);
  if (input.behaviors?.length)
    query = query.overlaps("behaviors", input.behaviors);
  if (input.min_effort != null)
    query = query.gte("effort", input.min_effort);
  if (input.max_effort != null)
    query = query.lte("effort", input.max_effort);

  const { data, error } = await query;
  if (error) throw new Error(`query_logs failed: ${error.message}`);

  return { count: (data ?? []).length, logs: data ?? [] };
}
