#!/usr/bin/env node
// claude-notify-server — local REST server for remote control of Claude Code sessions
// Zero external dependencies. Requires Node 22+.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { registerSession, getSession, removeSession, registerAction, getAction, consumeAction, setDecision, getDecision } from "./store.mjs";
import { sendToIterm } from "./iterm.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.CLAUDE_NOTIFY_PORT || "9876", 10);

let controlPageTemplate = "";

async function loadTemplate() {
  controlPageTemplate = await readFile(join(__dirname, "pages", "control.html"), "utf-8");
}

// --- Helpers ---

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end(JSON.stringify(data));
}

function html(res, status, body) {
  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8" });
  res.end(body);
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf-8");
}

function parseUrl(req) {
  return new URL(req.url, `http://localhost:${PORT}`);
}

const EVENT_ICONS = {
  permission_prompt: "\uD83D\uDD12",
  idle_prompt: "\u231B",
  elicitation_dialog: "\u2753",
  stop: "\u2705",
};

const EVENT_TITLES = {
  permission_prompt: "Permission Required",
  idle_prompt: "Claude Code is Idle",
  elicitation_dialog: "Claude Code has a Question",
  stop: "Task Complete",
};

// --- Routes ---

async function handleRequest(req, res) {
  const url = parseUrl(req);
  const path = url.pathname;
  const method = req.method;

  // CORS preflight
  if (method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    });
    res.end();
    return;
  }

  // POST /session — register a Claude Code session
  if (method === "POST" && path === "/session") {
    const body = JSON.parse(await readBody(req));
    registerSession({
      sessionId: body.session_id,
      itermSession: body.iterm_session,
      cwd: body.cwd,
    });
    json(res, 200, { ok: true });
    return;
  }

  // DELETE /session/:id — remove a session
  if (method === "DELETE" && path.startsWith("/session/")) {
    const sessionId = path.slice("/session/".length);
    removeSession(sessionId);
    json(res, 200, { ok: true });
    return;
  }

  // POST /register-action — create a one-time action token
  if (method === "POST" && path === "/register-action") {
    const body = JSON.parse(await readBody(req));
    registerAction({
      uuid: body.uuid,
      sessionId: body.session_id,
      notificationType: body.notification_type,
      message: body.message,
      project: body.project,
      tool: body.tool,
    });
    json(res, 200, { ok: true });
    return;
  }

  // GET /approve/:uuid — approve the action
  if (method === "GET" && path.startsWith("/approve/")) {
    const uuid = path.slice("/approve/".length);
    // Set decision for PermissionRequest hook polling
    setDecision(uuid, "allow");
    // Also try iTerm2 keystroke as fallback (for Notification-based flow)
    await handleAction(res, uuid, "y");
    return;
  }

  // GET /deny/:uuid — deny the action
  if (method === "GET" && path.startsWith("/deny/")) {
    const uuid = path.slice("/deny/".length);
    setDecision(uuid, "deny");
    await handleAction(res, uuid, "n");
    return;
  }

  // GET /decision/:uuid — poll for decision (used by permission-gate.sh)
  if (method === "GET" && path.startsWith("/decision/")) {
    const uuid = path.slice("/decision/".length);
    const decision = getDecision(uuid);
    if (decision) {
      json(res, 200, { ok: true, decision });
    } else {
      json(res, 200, { ok: true, decision: null });
    }
    return;
  }

  // GET /control/:uuid — serve control page
  if (method === "GET" && path.startsWith("/control/")) {
    const uuid = path.slice("/control/".length);
    const action = getAction(uuid);
    if (!action) {
      html(res, 410, renderExpiredPage());
      return;
    }

    const session = getSession(action.sessionId);
    const project = action.project || (session ? basename(session.cwd) : "");
    const eventType = action.notificationType || "stop";

    const page = controlPageTemplate
      .replace("{{UUID}}", uuid)
      .replace("{{CREATED_AT}}", String(action.createdAt))
      .replace("{{ICON}}", EVENT_ICONS[eventType] || "\uD83D\uDD14")
      .replace("{{TITLE}}", EVENT_TITLES[eventType] || "Claude Code")
      .replace("{{PROJECT}}", escapeHtml(project))
      .replace("{{EVENT_TYPE}}", escapeHtml(eventType.replace(/_/g, " ")))
      .replace("{{MESSAGE}}", escapeHtml(action.message || ""));

    html(res, 200, page);
    return;
  }

  // POST /control/:uuid — send custom text
  if (method === "POST" && path.startsWith("/control/")) {
    const uuid = path.slice("/control/".length);
    const text = (await readBody(req)).trim();
    if (!text) {
      json(res, 400, { ok: false, error: "Empty input" });
      return;
    }
    await handleAction(res, uuid, text);
    return;
  }

  // GET /health
  if (method === "GET" && path === "/health") {
    json(res, 200, { ok: true, uptime: process.uptime() });
    return;
  }

  // 404
  json(res, 404, { ok: false, error: "Not found" });
}

async function handleAction(res, uuid, text) {
  const action = getAction(uuid);
  if (!action) {
    // Check if there's already a decision set (approve/deny was called)
    const decision = getDecision(uuid);
    if (decision) {
      json(res, 200, { ok: true, decision, note: "Decision recorded (hook will pick it up)" });
      return;
    }
    json(res, 410, { ok: false, error: "Token expired or already used" });
    return;
  }

  // Mark as consumed
  consumeAction(uuid);

  // Try iTerm2 keystroke as a best-effort fallback
  const session = getSession(action.sessionId);
  let itermSent = false;
  if (session && session.itermSession) {
    try {
      await sendToIterm(session.itermSession, text);
      itermSent = true;
    } catch (err) {
      // iTerm2 failed — that's OK if PermissionRequest hook is polling
      console.log(`[claude-notify-server] iTerm2 fallback failed: ${err.message}`);
    }
  }

  json(res, 200, { ok: true, sent: text, itermSent });
}

function basename(p) {
  if (!p) return "";
  return p.split("/").pop() || "";
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderExpiredPage() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Expired</title>
  <style>
    body { font-family: -apple-system, sans-serif; background: #0d1117; color: #8b949e;
           display: flex; justify-content: center; align-items: center; height: 100vh; }
    .msg { text-align: center; }
    .msg .icon { font-size: 48px; margin-bottom: 16px; }
    .msg h1 { color: #e6edf3; font-size: 20px; margin-bottom: 8px; }
  </style>
</head>
<body>
  <div class="msg">
    <div class="icon">\u23F0</div>
    <h1>Link Expired</h1>
    <p>This action link has expired or was already used.</p>
  </div>
</body>
</html>`;
}

// --- Start ---

await loadTemplate();

const server = createServer(async (req, res) => {
  try {
    await handleRequest(req, res);
  } catch (err) {
    console.error(`[claude-notify-server] Error: ${err.message}`);
    json(res, 500, { ok: false, error: "Internal server error" });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[claude-notify-server] Listening on http://127.0.0.1:${PORT}`);
});

// Graceful shutdown
process.on("SIGTERM", () => { server.close(); process.exit(0); });
process.on("SIGINT", () => { server.close(); process.exit(0); });
