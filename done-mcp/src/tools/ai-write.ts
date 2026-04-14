import { z } from "zod";
import { getDb, getUserId } from "../db.js";

// --- save_insight ---

export const saveInsightSchema = z.object({
  insight_type: z
    .enum(["pattern", "trend", "milestone", "observation"])
    .describe("Category of insight."),
  content: z.string().describe("The insight text."),
  related_event_ids: z
    .array(z.string())
    .optional()
    .describe("UUIDs of related events."),
  period_start: z
    .string()
    .optional()
    .describe("Start of the period this insight covers (ISO 8601)."),
  period_end: z
    .string()
    .optional()
    .describe("End of the period this insight covers (ISO 8601)."),
});

export async function saveInsight(input: z.infer<typeof saveInsightSchema>) {
  const db = getDb();
  const userId = getUserId();

  const { data, error } = await db
    .from("ai_insights")
    .insert({
      user_id: userId,
      insight_type: input.insight_type,
      content: input.content,
      related_event_ids: input.related_event_ids ?? [],
      period_start: input.period_start ?? null,
      period_end: input.period_end ?? null,
      model: "mcp-caller",
    })
    .select("id")
    .single();

  if (error) throw new Error(`save_insight failed: ${error.message}`);
  return { id: data.id, status: "saved" };
}

// --- save_summary ---

export const saveSummarySchema = z.object({
  period_start: z.string().describe("Start of summarized period (ISO 8601)."),
  period_end: z.string().describe("End of summarized period (ISO 8601)."),
  content: z.string().describe("The summary text."),
});

export async function saveSummary(input: z.infer<typeof saveSummarySchema>) {
  const db = getDb();
  const userId = getUserId();

  const { data, error } = await db
    .from("ai_summaries")
    .insert({
      user_id: userId,
      period_start: input.period_start,
      period_end: input.period_end,
      content: input.content,
      model: "mcp-caller",
    })
    .select("id")
    .single();

  if (error) throw new Error(`save_summary failed: ${error.message}`);
  return { id: data.id, status: "saved" };
}

// --- leave_question ---

export const leaveQuestionSchema = z.object({
  content: z
    .string()
    .describe("A question the AI wants to ask the user."),
  related_event_ids: z
    .array(z.string())
    .optional()
    .describe("UUIDs of related events."),
});

export async function leaveQuestion(
  input: z.infer<typeof leaveQuestionSchema>
) {
  const db = getDb();
  const userId = getUserId();

  const { data, error } = await db
    .from("ai_questions")
    .insert({
      user_id: userId,
      content: input.content,
      related_event_ids: input.related_event_ids ?? [],
      model: "mcp-caller",
    })
    .select("id")
    .single();

  if (error) throw new Error(`leave_question failed: ${error.message}`);
  return { id: data.id, status: "saved" };
}
