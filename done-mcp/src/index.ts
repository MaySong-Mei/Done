import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { queryEventsSchema, queryEvents } from "./tools/query-events.js";
import { queryLogsSchema, queryLogs } from "./tools/query-logs.js";
import { getUserContext } from "./tools/get-context.js";
import { getSkillsSchema, getSkills } from "./tools/get-skills.js";
import {
  saveInsightSchema,
  saveInsight,
  saveSummarySchema,
  saveSummary,
  leaveQuestionSchema,
  leaveQuestion,
} from "./tools/ai-write.js";

const server = new McpServer({
  name: "done-life-log",
  version: "0.1.0",
});

// ── Read tools ─────────────────────────────────────────────

server.tool(
  "get_user_context",
  "Get the user's profile, event type definitions, skill summary, and recent emotional/behavioral patterns. Call this first to understand who the user is.",
  {},
  async () => {
    const ctx = await getUserContext();
    return { content: [{ type: "text", text: JSON.stringify(ctx, null, 2) }] };
  }
);

server.tool(
  "query_events",
  "Query the user's calendar events and todos. Filter by date range, event type, status, or keyword. Returns event details including title, time, type, location, and notes.",
  queryEventsSchema.shape,
  async (input) => {
    const result = await queryEvents(input);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }
);

server.tool(
  "query_logs",
  "Query activity logs — the user's reflections after completing events. Includes completion status, effort rating (1-5), emotions, behaviors, notes, and duration. Great for understanding how the user felt and performed.",
  queryLogsSchema.shape,
  async (input) => {
    const result = await queryLogs(input);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }
);

server.tool(
  "get_skills",
  "Get skill insights extracted from the user's activities. Shows practice hours per skill, with reasoning for attribution. Can filter by skill name and date range.",
  getSkillsSchema.shape,
  async (input) => {
    const result = await getSkills(input);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }
);

// ── AI write tools ─────────────────────────────────────────

server.tool(
  "save_insight",
  "Save an insight you've discovered about the user's patterns, trends, or milestones. These are stored separately from the user's own data. The user can see them in the app.",
  saveInsightSchema.shape,
  async (input) => {
    const result = await saveInsight(input);
    return {
      content: [{ type: "text", text: JSON.stringify(result) }],
    };
  }
);

server.tool(
  "save_summary",
  "Save a summary of the user's activities for a specific time period. Stored in the AI-owned section — the user can review but not edit.",
  saveSummarySchema.shape,
  async (input) => {
    const result = await saveSummary(input);
    return {
      content: [{ type: "text", text: JSON.stringify(result) }],
    };
  }
);

server.tool(
  "leave_question",
  "Leave a question for the user to answer next time they open the app. Use this when you notice something interesting but need more context from the user.",
  leaveQuestionSchema.shape,
  async (input) => {
    const result = await leaveQuestion(input);
    return {
      content: [{ type: "text", text: JSON.stringify(result) }],
    };
  }
);

// ── Start ──────────────────────────────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Done MCP server running on stdio");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
