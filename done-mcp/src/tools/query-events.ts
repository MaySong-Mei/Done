import { z } from "zod";
import { getDb, getUserId } from "../db.js";

export const queryEventsSchema = z.object({
  date_from: z
    .string()
    .optional()
    .describe("Start date (ISO 8601). Omit for no lower bound."),
  date_to: z
    .string()
    .optional()
    .describe("End date (ISO 8601). Omit for no upper bound."),
  types: z
    .array(z.string())
    .optional()
    .describe("Filter by event type names, e.g. ['Exercise', 'Study']"),
  kind: z
    .enum(["calendar", "todo"])
    .optional()
    .describe("Filter by event kind. Omit for both."),
  status: z
    .enum(["active", "completed", "archived"])
    .optional()
    .describe("Filter by status. Omit for all."),
  keyword: z
    .string()
    .optional()
    .describe("Search in title and note (case-insensitive)."),
  limit: z
    .number()
    .int()
    .min(1)
    .max(200)
    .optional()
    .describe("Max results (default 50)."),
});

export type QueryEventsInput = z.infer<typeof queryEventsSchema>;

export async function queryEvents(input: QueryEventsInput) {
  const db = getDb();
  const userId = getUserId();

  let query = db
    .from("events")
    .select(
      "id, kind, title, note, location, type, additional_types, tags, priority, status, is_all_day, is_done, color_depth, time_ranges, deadline, complete_at, repeat_unit, repeat_interval, display_kind, created_at, updated_at"
    )
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(input.limit ?? 50);

  if (input.kind) query = query.eq("kind", input.kind);
  if (input.status) query = query.eq("status", input.status);
  if (input.types?.length) query = query.in("type", input.types);
  if (input.keyword) {
    query = query.or(
      `title.ilike.%${input.keyword}%,note.ilike.%${input.keyword}%`
    );
  }

  // Date filtering on time_ranges is done post-query since it's JSONB.
  // For efficiency we use created_at as a rough pre-filter.
  if (input.date_from) {
    query = query.gte("created_at", input.date_from);
  }

  const { data, error } = await query;
  if (error) throw new Error(`query_events failed: ${error.message}`);

  // Post-filter by actual time ranges if date bounds given
  let results = data ?? [];
  if (input.date_from || input.date_to) {
    const from = input.date_from ? new Date(input.date_from).getTime() : 0;
    const to = input.date_to
      ? new Date(input.date_to).getTime()
      : Number.MAX_SAFE_INTEGER;

    results = results.filter((e: any) => {
      const ranges = e.time_ranges as Array<{ start: string; end: string }>;
      if (!ranges?.length) {
        // For todos without time ranges, fall back to created_at
        const ct = new Date(e.created_at).getTime();
        return ct >= from && ct <= to;
      }
      return ranges.some((r) => {
        const s = new Date(r.start).getTime();
        const end = new Date(r.end).getTime();
        return end >= from && s <= to;
      });
    });
  }

  return { count: results.length, events: results };
}
