// Generate 3 weeks of realistic life data for a software developer
import crypto from "crypto";

const SB_URL = "https://uqnvtzblppjblwgbpqhf.supabase.co";
const SB_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjE2MzA5MiwiZXhwIjoyMDkxNzM5MDkyfQ.LUwM3Kq6UbPiPeucHfn5iKaNh1RhEY5X1dU61BRS4Ng";
const UID = "9c415221-a561-46eb-b562-f81f62e2af51";
const uuid = () => crypto.randomUUID();

async function post(table, data) {
  // Batch in chunks of 20
  for (let i = 0; i < data.length; i += 20) {
    const chunk = data.slice(i, i + 20);
    const resp = await fetch(`${SB_URL}/rest/v1/${table}`, {
      method: "POST",
      headers: {
        apikey: SB_KEY,
        Authorization: `Bearer ${SB_KEY}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(chunk),
    });
    if (!resp.ok) console.error(`${table} chunk ${i} FAILED:`, await resp.text());
  }
  console.log(`${table}: ${data.length} rows OK`);
}

// ── Event Types ──
await post("event_types", [
  { id: uuid(), user_id: UID, title: "Exercise", color_hex: "#FF6B35" },
  { id: uuid(), user_id: UID, title: "Study", color_hex: "#4ECDC4" },
  { id: uuid(), user_id: UID, title: "Work", color_hex: "#2C3E50" },
  { id: uuid(), user_id: UID, title: "Sleep", color_hex: "#9B59B6" },
  { id: uuid(), user_id: UID, title: "Social", color_hex: "#E74C3C" },
  { id: uuid(), user_id: UID, title: "Personal", color_hex: "#F39C12" },
  { id: uuid(), user_id: UID, title: "Creative", color_hex: "#1ABC9C" },
]);

// ── Helpers ──
function date(y, m, d, h = 0, min = 0) {
  return new Date(Date.UTC(y, m - 1, d, h, min)).toISOString();
}
function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function pickN(arr, n) {
  const shuffled = [...arr].sort(() => Math.random() - 0.5);
  return shuffled.slice(0, n);
}

// ── Generate 21 days: March 25 - April 14, 2026 ──
const events = [];
const logs = [];
const skills = [];

const dayTemplates = [
  // Weekday productive
  {
    items: [
      { title: "Morning Run", type: "Exercise", hStart: 6, hEnd: 6, mEnd: 45, effort: 3, emotions: ["energized", "happy"], behaviors: ["consistent", "as_planned"], summary: "Solid morning run", skill: "Running", points: 0.75 },
      { title: "Deep Work: iOS App", type: "Work", hStart: 9, hEnd: 12, mEnd: 0, effort: 4, emotions: ["focused", "calm"], behaviors: ["deep_work"], summary: "Productive coding session", skill: "Swift", points: 3.0 },
      { title: "Lunch Walk", type: "Personal", hStart: 12, hEnd: 12, mEnd: 30, effort: 1, emotions: ["calm", "happy"], behaviors: ["as_planned"], summary: "Quick walk around the block", skill: null, points: 0 },
      { title: "Code Review & PR", type: "Work", hStart: 14, hEnd: 16, mEnd: 0, effort: 3, emotions: ["focused"], behaviors: ["collaborative"], summary: "Reviewed 3 PRs, left feedback", skill: "Code Review", points: 2.0 },
      { title: "Read DDIA", type: "Study", hStart: 21, hEnd: 22, mEnd: 0, effort: 4, emotions: ["focused", "tired"], behaviors: ["deep_work"], summary: "Studying distributed systems concepts", skill: "Distributed Systems", points: 1.0 },
    ],
  },
  // Weekday with gym
  {
    items: [
      { title: "Gym - Strength Training", type: "Exercise", hStart: 7, hEnd: 8, mEnd: 15, effort: 4, emotions: ["energized"], behaviors: ["consistent"], summary: "Upper body day, increased weight on bench press", skill: "Strength Training", points: 1.25 },
      { title: "Sprint Planning", type: "Work", hStart: 10, hEnd: 11, mEnd: 0, effort: 2, emotions: ["neutral"], behaviors: ["collaborative"], summary: "Planned next sprint, estimated stories", skill: null, points: 0 },
      { title: "Feature Development", type: "Work", hStart: 11, hEnd: 13, mEnd: 0, effort: 4, emotions: ["focused", "energized"], behaviors: ["deep_work", "proactive"], summary: "Implemented new gesture system", skill: "Swift", points: 2.0 },
      { title: "API Integration", type: "Work", hStart: 14, hEnd: 17, mEnd: 30, effort: 5, emotions: ["frustrated", "focused"], behaviors: ["deep_work"], summary: "Debugging API edge cases, finally cracked it", skill: "Backend", points: 3.5 },
      { title: "Piano Practice", type: "Creative", hStart: 20, hEnd: 20, mEnd: 45, effort: 3, emotions: ["calm", "happy"], behaviors: ["consistent"], summary: "Working on Chopin Nocturne", skill: "Piano", points: 0.75 },
    ],
  },
  // Weekday tired/stressful
  {
    items: [
      { title: "Slept in - no exercise", type: "Personal", hStart: 8, hEnd: 8, mEnd: 30, effort: 1, emotions: ["tired"], behaviors: ["avoidant"], summary: "Too tired, skipped morning workout", skill: null, points: 0 },
      { title: "Bug Fixing", type: "Work", hStart: 10, hEnd: 12, mEnd: 30, effort: 5, emotions: ["stressed", "frustrated"], behaviors: ["rushed", "interrupted"], summary: "Production bug, hotfix needed", skill: "Debugging", points: 2.5 },
      { title: "Team Standup", type: "Work", hStart: 13, hEnd: 13, mEnd: 15, effort: 1, emotions: ["neutral"], behaviors: ["collaborative"], summary: "Quick sync", skill: null, points: 0 },
      { title: "Continue Fix + Tests", type: "Work", hStart: 14, hEnd: 17, mEnd: 0, effort: 4, emotions: ["focused", "anxious"], behaviors: ["deep_work", "rushed"], summary: "Wrote regression tests, deployed fix", skill: "Swift", points: 3.0 },
      { title: "YouTube - Tech talks", type: "Study", hStart: 21, hEnd: 22, mEnd: 0, effort: 2, emotions: ["tired", "calm"], behaviors: ["distracted"], summary: "Watched WWDC talk but kept drifting", skill: "iOS", points: 0.5 },
    ],
  },
  // Weekend relaxed
  {
    items: [
      { title: "Long Run", type: "Exercise", hStart: 8, hEnd: 9, mEnd: 30, effort: 4, emotions: ["energized", "happy", "calm"], behaviors: ["consistent", "as_planned"], summary: "10K along the river, beautiful weather", skill: "Running", points: 1.5 },
      { title: "Brunch with friends", type: "Social", hStart: 11, hEnd: 13, mEnd: 0, effort: 1, emotions: ["happy", "energized"], behaviors: ["collaborative"], summary: "Great catch-up, talked about travel plans", skill: null, points: 0 },
      { title: "Side Project", type: "Work", hStart: 15, hEnd: 17, mEnd: 0, effort: 3, emotions: ["focused", "happy"], behaviors: ["deep_work", "proactive"], summary: "Working on MCP server for Done app", skill: "TypeScript", points: 2.0 },
      { title: "Piano Practice", type: "Creative", hStart: 19, hEnd: 20, mEnd: 0, effort: 3, emotions: ["calm", "focused"], behaviors: ["consistent"], summary: "Nailed the difficult passage in Nocturne", skill: "Piano", points: 1.0 },
    ],
  },
  // Weekend social
  {
    items: [
      { title: "Morning Yoga", type: "Exercise", hStart: 9, hEnd: 10, mEnd: 0, effort: 2, emotions: ["calm", "happy"], behaviors: ["as_planned"], summary: "Gentle flow, good stretching", skill: "Yoga", points: 1.0 },
      { title: "Hiking with friends", type: "Social", hStart: 11, hEnd: 15, mEnd: 0, effort: 3, emotions: ["happy", "energized"], behaviors: ["as_planned"], summary: "Beautiful trail, 8km hike", skill: "Running", points: 0.5 },
      { title: "Cooking dinner", type: "Personal", hStart: 17, hEnd: 18, mEnd: 30, effort: 2, emotions: ["calm", "happy"], behaviors: ["proactive"], summary: "Tried a new Thai curry recipe", skill: "Cooking", points: 1.5 },
      { title: "Read - Sapiens", type: "Study", hStart: 21, hEnd: 22, mEnd: 30, effort: 3, emotions: ["focused", "calm"], behaviors: ["deep_work"], summary: "Chapter on agricultural revolution", skill: "General Knowledge", points: 1.5 },
    ],
  },
  // Light day
  {
    items: [
      { title: "Morning Run", type: "Exercise", hStart: 7, hEnd: 7, mEnd: 30, effort: 2, emotions: ["calm"], behaviors: ["consistent"], summary: "Easy recovery run", skill: "Running", points: 0.5 },
      { title: "Refactoring", type: "Work", hStart: 10, hEnd: 12, mEnd: 0, effort: 3, emotions: ["focused", "calm"], behaviors: ["deep_work", "proactive"], summary: "Cleaned up gesture handling code", skill: "Swift", points: 2.0 },
      { title: "Dentist Appointment", type: "Personal", hStart: 14, hEnd: 15, mEnd: 0, effort: 1, emotions: ["anxious", "neutral"], behaviors: ["as_planned"], summary: "Regular checkup, all good", skill: null, points: 0 },
      { title: "Online Course - SwiftUI", type: "Study", hStart: 20, hEnd: 21, mEnd: 30, effort: 3, emotions: ["focused", "energized"], behaviors: ["deep_work"], summary: "Advanced animations module", skill: "SwiftUI", points: 1.5 },
    ],
  },
];

// Vary the templates across days
const templateOrder = [0, 1, 2, 0, 5, 3, 4, 1, 0, 2, 0, 1, 5, 3, 4, 0, 2, 0, 1, 5, 3];

for (let dayOffset = 0; dayOffset < 21; dayOffset++) {
  const d = new Date(Date.UTC(2026, 2, 25 + dayOffset)); // March 25 + offset
  const y = d.getUTCFullYear(), m = d.getUTCMonth() + 1, day = d.getUTCDate();
  const template = dayTemplates[templateOrder[dayOffset % templateOrder.length]];

  // Sometimes skip an item (life happens)
  const skipIndex = Math.random() < 0.2 ? Math.floor(Math.random() * template.items.length) : -1;

  for (let i = 0; i < template.items.length; i++) {
    if (i === skipIndex) continue;
    const item = template.items[i];
    const eid = uuid();
    const completed = Math.random() < 0.85;

    events.push({
      id: eid,
      user_id: UID,
      kind: "calendar",
      title: item.title,
      note: "",
      type: item.type,
      time_ranges: [{
        start: date(y, m, day, item.hStart, 0),
        end: date(y, m, day, item.hEnd, item.mEnd),
      }],
      status: completed ? "completed" : "active",
      is_done: completed,
      tags: [],
      additional_types: null,
      type_weights: null,
      color_depth: item.effort / 5.0,
    });

    if (completed) {
      // Slightly vary emotions/behaviors
      let emos = [...item.emotions];
      let behs = [...item.behaviors];
      if (Math.random() < 0.15) emos.push(pick(["tired", "neutral", "stressed"]));
      if (Math.random() < 0.15) behs.push(pick(["distracted", "delayed"]));

      // Vary effort slightly
      let effort = item.effort + (Math.random() < 0.3 ? (Math.random() < 0.5 ? 1 : -1) : 0);
      effort = Math.max(1, Math.min(5, effort));

      // Vary summary slightly
      const summaryVariants = [item.summary, item.summary + " — felt good about it", item.summary];

      logs.push({
        id: `log-${eid}`,
        user_id: UID,
        event_id: eid,
        occurrence_date: date(y, m, day, 0, 0),
        completion_status: Math.random() < 0.9 ? "completed" : "partial",
        actual_duration_minutes: (item.hEnd - item.hStart) * 60 + item.mEnd,
        summary: pick(summaryVariants),
        note: "",
        effort: effort,
        emotions: emos,
        behaviors: behs,
        template_answers: {},
        timeline_items: [],
      });

      if (item.skill) {
        // Vary points slightly
        const pts = item.points * (0.8 + Math.random() * 0.4);
        skills.push({
          id: uuid(),
          user_id: UID,
          skill_name: item.skill,
          points: Math.round(pts * 100) / 100,
          date: date(y, m, day, item.hStart, 0),
          event_title: item.title,
          reasoning: item.summary,
        });
      }
    }
  }
}

// Add some todos
const todos = [
  "Buy groceries",
  "Reply to Alex's email",
  "Book flight to Tokyo",
  "Renew gym membership",
  "Update portfolio website",
  "Call dentist for followup",
  "Order new running shoes",
  "Backup photos to external drive",
].map((title, i) => ({
  id: uuid(),
  user_id: UID,
  kind: "todo",
  title,
  note: "",
  type: "",
  time_ranges: [],
  status: i < 4 ? "completed" : "active",
  is_done: i < 4,
  tags: [],
  additional_types: null,
  type_weights: null,
  color_depth: 1.0,
}));

events.push(...todos);

await post("event_types", []);  // already done above
await post("events", events);
await post("event_logs", logs);
await post("skill_insights", skills);

console.log(`\nTotal: ${events.length} events, ${logs.length} logs, ${skills.length} skill insights`);
console.log("Seed complete!");
