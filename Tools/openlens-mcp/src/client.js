import net from "node:net";
import os from "node:os";
import path from "node:path";

/**
 * Talks to the OpenLens control socket.
 *
 * One connection per request. A unix socket connect costs microseconds, and
 * paying that buys the removal of every reconnect, backoff and stale-socket
 * path that a long-lived connection would need — OpenLens can quit and relaunch
 * between two tool calls and nothing here has to notice.
 */

export const APP_GROUP = "G69Z5BNY97.com.trsdn.openlens";

export function defaultSocketPath() {
  return (
    process.env.OPENLENS_SOCKET ??
    path.join(os.homedir(), "Library", "Group Containers", APP_GROUP, "control.sock")
  );
}

export class OpenLensError extends Error {}

/** Raised when the socket is not there, which almost always means the app is not running. */
export class NotRunningError extends OpenLensError {
  constructor(socketPath) {
    super(
      `OpenLens does not appear to be running: no control socket at ${socketPath}. ` +
        "Start OpenLens and try again."
    );
  }
}

export async function send(command, params = {}, { socketPath = defaultSocketPath(), timeoutMs = 5000 } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let buffer = "";
    let settled = false;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      error ? reject(error) : resolve(value);
    };

    const timer = setTimeout(
      () => finish(new OpenLensError(`OpenLens did not answer \`${command}\` within ${timeoutMs} ms`)),
      timeoutMs
    );

    socket.on("error", (error) => {
      const missing = error.code === "ENOENT" || error.code === "ECONNREFUSED";
      finish(missing ? new NotRunningError(socketPath) : error);
    });

    socket.on("connect", () => {
      // Undefined values would serialise as absent keys anyway, but stripping
      // them here keeps the app's "was this given?" checks honest for callers
      // that pass optional arguments straight through.
      const given = Object.fromEntries(
        Object.entries(params).filter(([, value]) => value !== undefined)
      );
      socket.write(JSON.stringify({ id: "1", command, params: given }) + "\n");
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;

      let response;
      try {
        response = JSON.parse(buffer.slice(0, newline));
      } catch (error) {
        return finish(new OpenLensError(`OpenLens sent something that is not JSON: ${error.message}`));
      }
      response.ok
        ? finish(null, response.result ?? {})
        : finish(new OpenLensError(response.error ?? "OpenLens refused the command"));
    });

    // The app closing the connection before answering is not a protocol error
    // worth a stack trace, but it must not hang either.
    socket.on("close", () => finish(new OpenLensError(`OpenLens closed the connection during \`${command}\``)));
  });
}

/**
 * Subscribes to state changes and calls `onState` for each one, starting with
 * the state at the moment of subscribing.
 *
 * This is the one place that keeps a connection open, because that is the whole
 * point: a Stream Deck key showing whether OpenLens is paused has to change
 * when someone presses the hotkey, not when something happens to ask next.
 *
 * Returns a function that stops watching.
 */
export function watch(onState, { socketPath = defaultSocketPath(), onError = () => {} } = {}) {
  let socket = null;
  let stopped = false;
  let retry = null;

  const connect = () => {
    if (stopped) return;
    socket = net.createConnection({ path: socketPath });
    let buffer = "";

    socket.on("connect", () => {
      socket.write(JSON.stringify({ id: "subscribe", command: "events.subscribe" }) + "\n");
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }
        // The reply to `events.subscribe` carries the current state, and every
        // event after it carries the new one; a watcher wants both and does not
        // care which was which.
        if (message.event === "state" && message.state) onState(message.state);
        else if (message.ok && message.result) onState(message.result);
        else if (message.ok === false) onError(new OpenLensError(message.error ?? "subscribe refused"));
      }
    });

    const reconnect = (error) => {
      if (stopped) return;
      socket?.destroy();
      socket = null;
      if (error && error.code !== "ENOENT" && error.code !== "ECONNREFUSED") onError(error);
      // OpenLens quitting is ordinary rather than exceptional — a watcher
      // should still be there when it comes back.
      retry = setTimeout(connect, 1000);
    };

    socket.on("error", reconnect);
    socket.on("close", () => reconnect(null));
  };

  connect();

  return () => {
    stopped = true;
    clearTimeout(retry);
    socket?.destroy();
  };
}
