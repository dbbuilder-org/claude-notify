// iTerm2 AppleScript integration — sends keystrokes to specific sessions
import { execFile } from "node:child_process";

/**
 * Send text to a specific iTerm2 session by its unique ID.
 * Uses AppleScript to find the session across all windows/tabs.
 */
export function sendToIterm(itermSessionId, text) {
  return new Promise((resolve, reject) => {
    // Sanitize text for AppleScript string literal
    const safeText = text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');

    const script = `
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if unique ID of s is "${itermSessionId}" then
                tell s to write text "${safeText}"
                return "sent"
              end if
            end repeat
          end repeat
        end repeat
        return "session_not_found"
      end tell
    `;

    execFile("osascript", ["-e", script], { timeout: 10000 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`osascript failed: ${err.message}`));
        return;
      }
      const result = stdout.trim();
      if (result === "session_not_found") {
        reject(new Error(`iTerm2 session not found: ${itermSessionId}`));
        return;
      }
      resolve(result);
    });
  });
}

/**
 * Bring iTerm2 to the front and activate the target session's tab.
 */
export function focusItermSession(itermSessionId) {
  return new Promise((resolve, reject) => {
    const script = `
      tell application "iTerm2"
        activate
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if unique ID of s is "${itermSessionId}" then
                select t
                return "focused"
              end if
            end repeat
          end repeat
        end repeat
        return "session_not_found"
      end tell
    `;

    execFile("osascript", ["-e", script], { timeout: 10000 }, (err, stdout) => {
      if (err) {
        reject(err);
        return;
      }
      resolve(stdout.trim());
    });
  });
}
