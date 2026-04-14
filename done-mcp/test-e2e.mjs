// End-to-end test: spawn the MCP server and call tools via JSON-RPC
import { spawn } from "child_process";
import { readFileSync } from "fs";

// Load .env
const envLines = readFileSync(new URL("./.env", import.meta.url), "utf8").split("\n");
for (const line of envLines) {
  const [k, ...v] = line.split("=");
  if (k && v.length) process.env[k.trim()] = v.join("=").trim();
}

const child = spawn("/opt/homebrew/bin/node", ["dist/index.js"], {
  cwd: new URL(".", import.meta.url).pathname,
  env: { ...process.env },
  stdio: ["pipe", "pipe", "pipe"],
});

let buffer = "";
let msgId = 0;
const pending = new Map();

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString();
  // Parse newline-delimited JSON
  const lines = buffer.split("\n");
  buffer = lines.pop(); // keep incomplete line
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const msg = JSON.parse(line);
      const resolve = pending.get(msg.id);
      if (resolve) {
        pending.delete(msg.id);
        resolve(msg);
      }
    } catch {}
  }
});

child.stderr.on("data", (d) => process.stderr.write(d));

function send(method, params = {}) {
  return new Promise((resolve) => {
    const id = ++msgId;
    pending.set(id, resolve);
    const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    child.stdin.write(msg + "\n");
  });
}

async function main() {
  // Initialize
  const init = await send("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "test", version: "0.1" },
  });
  console.log("=== INIT ===");
  console.log(JSON.stringify(init.result.serverInfo));

  await send("notifications/initialized", {});

  // List tools
  const tools = await send("tools/list", {});
  console.log("\n=== TOOLS ===");
  for (const t of tools.result.tools) {
    console.log(`  - ${t.name}: ${t.description.slice(0, 60)}...`);
  }

  // Test get_user_context
  console.log("\n=== get_user_context ===");
  const ctx = await send("tools/call", { name: "get_user_context", arguments: {} });
  const ctxData = JSON.parse(ctx.result.content[0].text);
  console.log("Event types:", ctxData.event_types.map((t) => t.title));
  console.log("Top skills:", ctxData.top_skills);
  console.log("Recent emotions:", ctxData.recent_emotion_frequency);

  // Test query_events
  console.log("\n=== query_events (type=Exercise) ===");
  const evts = await send("tools/call", {
    name: "query_events",
    arguments: { types: ["Exercise"] },
  });
  const evtData = JSON.parse(evts.result.content[0].text);
  console.log(`Found ${evtData.count} events:`);
  for (const e of evtData.events) {
    console.log(`  - ${e.title} [${e.status}]`);
  }

  // Test query_logs
  console.log("\n=== query_logs (emotions=focused) ===");
  const logs = await send("tools/call", {
    name: "query_logs",
    arguments: { emotions: ["focused"] },
  });
  const logData = JSON.parse(logs.result.content[0].text);
  console.log(`Found ${logData.count} logs:`);
  for (const l of logData.logs) {
    console.log(`  - effort:${l.effort} emotions:${l.emotions} "${l.summary}"`);
  }

  // Test get_skills
  console.log("\n=== get_skills ===");
  const skills = await send("tools/call", {
    name: "get_skills",
    arguments: {},
  });
  const skillData = JSON.parse(skills.result.content[0].text);
  console.log("Aggregated:", skillData.aggregated);

  // Test save_insight (AI write)
  console.log("\n=== save_insight ===");
  const insight = await send("tools/call", {
    name: "save_insight",
    arguments: {
      insight_type: "observation",
      content: "User maintains a balanced routine of exercise, study, and development work.",
    },
  });
  console.log(JSON.parse(insight.result.content[0].text));

  console.log("\n=== ALL TESTS PASSED ===");
  child.kill();
  process.exit(0);
}

main().catch((e) => {
  console.error("FATAL:", e);
  child.kill();
  process.exit(1);
});
