// In-memory store for sessions and one-time action tokens

const sessions = new Map();
const actions = new Map();

const ACTION_TTL_MS = 30 * 60 * 1000; // 30 minutes

// --- Sessions ---

export function registerSession({ sessionId, itermSession, cwd }) {
  sessions.set(sessionId, {
    itermSession,
    cwd,
    registeredAt: Date.now(),
  });
}

export function getSession(sessionId) {
  return sessions.get(sessionId) || null;
}

export function removeSession(sessionId) {
  sessions.delete(sessionId);
}

// --- Actions ---

export function registerAction({ uuid, sessionId, notificationType, message, project }) {
  actions.set(uuid, {
    sessionId,
    notificationType,
    message,
    project: project || "",
    createdAt: Date.now(),
    used: false,
  });
}

export function getAction(uuid) {
  const action = actions.get(uuid);
  if (!action) return null;
  if (action.used) return null;
  if (Date.now() - action.createdAt > ACTION_TTL_MS) {
    actions.delete(uuid);
    return null;
  }
  return action;
}

export function consumeAction(uuid) {
  const action = getAction(uuid);
  if (!action) return null;
  action.used = true;
  return action;
}

// --- Cleanup ---

export function cleanup() {
  const now = Date.now();
  for (const [uuid, action] of actions) {
    if (action.used || now - action.createdAt > ACTION_TTL_MS) {
      actions.delete(uuid);
    }
  }
  // Remove sessions older than 24 hours
  for (const [id, session] of sessions) {
    if (now - session.registeredAt > 24 * 60 * 60 * 1000) {
      sessions.delete(id);
    }
  }
}

// Run cleanup every 5 minutes
setInterval(cleanup, 5 * 60 * 1000).unref();
