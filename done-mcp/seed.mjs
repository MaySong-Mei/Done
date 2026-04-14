import crypto from "crypto";

const SB_URL = "https://uqnvtzblppjblwgbpqhf.supabase.co";
const SB_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjE2MzA5MiwiZXhwIjoyMDkxNzM5MDkyfQ.LUwM3Kq6UbPiPeucHfn5iKaNh1RhEY5X1dU61BRS4Ng";
const UID = "9c415221-a561-46eb-b562-f81f62e2af51";

const uuid = () => crypto.randomUUID();

async function post(table, data) {
  const resp = await fetch(`${SB_URL}/rest/v1/${table}`, {
    method: "POST",
    headers: {
      apikey: SB_KEY,
      Authorization: `Bearer ${SB_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(data),
  });
  if (!resp.ok) {
    console.error(`${table} FAILED:`, await resp.text());
  } else {
    console.log(`${table}: OK`);
  }
}

const e1 = uuid(), e2 = uuid(), e3 = uuid(), e4 = uuid();

await post("event_types", [
  { id: uuid(), user_id: UID, title: "Exercise", color_hex: "#FF6B35" },
  { id: uuid(), user_id: UID, title: "Study", color_hex: "#4ECDC4" },
  { id: uuid(), user_id: UID, title: "Work", color_hex: "#2C3E50" },
  { id: uuid(), user_id: UID, title: "Sleep", color_hex: "#9B59B6" },
]);

await post("events", [
  { id: e1, user_id: UID, kind: "calendar", title: "Morning Run", type: "Exercise", note: "", time_ranges: [{ start: "2026-04-14T07:00:00Z", end: "2026-04-14T07:45:00Z" }], status: "completed", is_done: true },
  { id: e2, user_id: UID, kind: "calendar", title: "Read DDIA Chapter 5", type: "Study", note: "Distributed data replication", time_ranges: [{ start: "2026-04-14T10:00:00Z", end: "2026-04-14T11:30:00Z" }], status: "completed", is_done: true },
  { id: e3, user_id: UID, kind: "calendar", title: "iOS MCP Server Dev", type: "Work", note: "Building MCP server for Done app", time_ranges: [{ start: "2026-04-14T14:00:00Z", end: "2026-04-14T17:00:00Z" }], status: "active", is_done: false },
  { id: e4, user_id: UID, kind: "todo", title: "Buy groceries", type: "", note: "", time_ranges: [], status: "active", is_done: false },
]);

await post("event_logs", [
  { id: `log-${e1}`, user_id: UID, event_id: e1, occurrence_date: "2026-04-14T00:00:00Z", completion_status: "completed", actual_duration_minutes: 45, summary: "Good pace, felt strong", effort: 3, emotions: ["energized", "happy"], behaviors: ["consistent", "as_planned"] },
  { id: `log-${e2}`, user_id: UID, event_id: e2, occurrence_date: "2026-04-14T00:00:00Z", completion_status: "completed", actual_duration_minutes: 90, summary: "Dense chapter but understood key concepts", effort: 4, emotions: ["focused", "calm"], behaviors: ["deep_work"] },
]);

await post("skill_insights", [
  { id: uuid(), user_id: UID, skill_name: "Running", points: 0.75, date: "2026-04-14T07:00:00Z", event_title: "Morning Run", reasoning: "45 min steady run" },
  { id: uuid(), user_id: UID, skill_name: "Distributed Systems", points: 1.5, date: "2026-04-14T10:00:00Z", event_title: "Read DDIA Chapter 5", reasoning: "Deep study of replication strategies" },
  { id: uuid(), user_id: UID, skill_name: "Swift", points: 3.0, date: "2026-04-14T14:00:00Z", event_title: "iOS MCP Server Dev", reasoning: "3 hours of active development" },
]);

console.log("Seed complete!");
