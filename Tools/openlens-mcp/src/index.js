#!/usr/bin/env node
import process from "node:process";

import { send, watch, NotRunningError, defaultSocketPath } from "./client.js";
import { TOOLS } from "./tools.js";

/**
 * An MCP server for OpenLens, speaking JSON-RPC 2.0 over stdio.
 *
 * Written against the protocol directly rather than against the official SDK,
 * which buys two things worth more here than the convenience: `npx` needs
 * nothing fetched and no build step, and there is no dependency to keep current
 * on a tool whose whole job is to forward a dozen commands to a socket.
 */

const NAME = "openlens";
const VERSION = "0.1.0";
/// Used when the client asks for something we do not recognise. Clients are
/// expected to accept a server naming an older version than they asked for.
const FALLBACK_PROTOCOL_VERSION = "2025-06-18";

// MARK: - Direct use
//
// `node src/index.js call zoom.set '{"value":2}'` talks to the same socket
// without an MCP client in the way, which is the quickest way to tell whether a
// problem is in OpenLens or in the wiring above it.

if (process.argv[2] === "call") {
  const command = process.argv[3];
  const params = process.argv[4] ? JSON.parse(process.argv[4]) : {};
  try {
    console.log(JSON.stringify(await send(command, params), null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
} else if (process.argv[2] === "watch") {
  // One compact JSON object per line, so a shell or a Stream Deck plugin can
  // read it without a parser of its own.
  watch(
    (state) => console.log(JSON.stringify(state)),
    { onError: (error) => console.error(error.message) }
  );
} else {
  serve();
}

// MARK: - Transport

function serve() {
  let buffer = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line) handleLine(line);
    }
  });
  process.stdin.on("end", () => process.exit(0));
}

function write(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function respond(id, result) {
  write({ jsonrpc: "2.0", id, result });
}

function fail(id, code, message) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handleLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return fail(null, -32700, "Parse error");
  }
  try {
    await dispatch(message);
  } catch (error) {
    // A notification has no id and must never be answered, not even to
    // complain, or the client sees a reply it has nothing to match.
    if (message.id !== undefined && message.id !== null) {
      fail(message.id, -32603, error.message);
    }
  }
}

// MARK: - Methods

async function dispatch(message) {
  const { id, method, params } = message;
  const isNotification = id === undefined || id === null;

  switch (method) {
    case "initialize":
      return respond(id, {
        // Echoed back when it looks like a version we can speak, because the
        // client picked it and refusing a newer date it already supports would
        // fail the handshake for no reason.
        protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(params?.protocolVersion ?? "")
          ? params.protocolVersion
          : FALLBACK_PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: NAME, version: VERSION },
      });

    case "notifications/initialized":
    case "notifications/cancelled":
      return;

    case "ping":
      return respond(id, {});

    case "tools/list":
      return respond(id, {
        tools: TOOLS.map(({ name, description, inputSchema }) => ({
          name,
          description,
          inputSchema,
        })),
      });

    case "tools/call":
      return respond(id, await callTool(params?.name, params?.arguments ?? {}));

    default:
      if (isNotification) return;
      return fail(id, -32601, `Unknown method \`${method}\``);
  }
}

async function callTool(name, args) {
  const tool = TOOLS.find((candidate) => candidate.name === name);
  if (!tool) {
    return errorResult(`Unknown tool \`${name}\``);
  }
  try {
    const result = await tool.run(args);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  } catch (error) {
    // A refusal from OpenLens is a tool error rather than a protocol error, so
    // the model gets to read it and correct itself instead of the whole call
    // failing.
    return errorResult(
      error instanceof NotRunningError
        ? `${error.message} (socket: ${defaultSocketPath()})`
        : error.message
    );
  }
}

function errorResult(text) {
  return { isError: true, content: [{ type: "text", text }] };
}

// MARK: - Direct use


