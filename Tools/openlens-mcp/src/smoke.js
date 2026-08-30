#!/usr/bin/env node
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { watch } from "./client.js";

/**
 * Runs the MCP server against a stand-in for OpenLens.
 *
 * The point is the seam on both sides: that the JSON-RPC handshake is one a
 * real client will accept, and that a tool call comes out of the other end as
 * the newline-delimited command the app expects. Neither is visible from
 * reading the two files, and both are exactly what breaks silently.
 *
 * Run with `npm test`. No dependencies, no network.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const socketPath = path.join(
  fs.mkdtempSync(path.join(os.tmpdir(), "openlens-mcp-")),
  "control.sock"
);

// MARK: - A stand-in for OpenLens

/** Every command the fake app was asked to run, in order. */
const received = [];

const app = net.createServer((socket) => {
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;

      const request = JSON.parse(line);
      received.push(request);
      socket.write(JSON.stringify(answer(request)) + "\n");

      // A subscriber is meant to see the state again whenever it changes; the
      // real app pushes on a hotkey press, and the fake one pushes straight
      // away so the test does not have to wait for anything real.
      if (request.command === "events.subscribe") {
        setTimeout(() => {
          socket.write(JSON.stringify({ event: "state", state: { paused: true } }) + "\n");
        }, 10);
      }
    }
  });
});

function answer({ id, command, params }) {
  if (command === "zoom.set" && params.value > 4) {
    return { id, ok: false, error: "`value` must be a positive number" };
  }
  if (command === "state.get") {
    return { id, ok: true, result: { paused: false, framing: { zoom: 1 } } };
  }
  if (command === "events.subscribe") {
    return { id, ok: true, result: { paused: false } };
  }
  return { id, ok: true, result: { command, params } };
}

// MARK: - Driving the server

function startServer() {
  const child = spawn(process.execPath, [path.join(here, "index.js")], {
    env: { ...process.env, OPENLENS_SOCKET: socketPath },
    stdio: ["pipe", "pipe", "inherit"],
  });

  let buffer = "";
  const waiters = new Map();

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      waiters.get(message.id)?.(message);
      waiters.delete(message.id);
    }
  });

  let nextID = 1;
  return {
    child,
    request(method, params) {
      const id = nextID++;
      const settled = new Promise((resolve, reject) => {
        waiters.set(id, resolve);
        setTimeout(() => reject(new Error(`No answer to \`${method}\``)), 5000).unref();
      });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
      return settled;
    },
    notify(method) {
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
    },
  };
}

// MARK: - The checks

const checks = [];
const check = (name, body) => checks.push([name, body]);

check("the handshake answers with the version the client asked for", async (server) => {
  const { result } = await server.request("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "smoke", version: "0" },
  });
  assert.equal(result.protocolVersion, "2025-06-18");
  assert.equal(result.serverInfo.name, "openlens");
  assert.ok(result.capabilities.tools, "must advertise tools, or no client will list any");
});

check("every tool has a name, a description and an object schema", async (server) => {
  const { result } = await server.request("tools/list");
  assert.ok(result.tools.length > 10, "expected the full tool surface");
  for (const tool of result.tools) {
    assert.match(tool.name, /^openlens_[a-z_]+$/, `bad tool name: ${tool.name}`);
    assert.ok(tool.description?.length > 40, `${tool.name} needs a real description`);
    assert.equal(tool.inputSchema.type, "object", `${tool.name} needs an object schema`);
  }
  const names = result.tools.map((tool) => tool.name);
  assert.equal(new Set(names).size, names.length, "tool names must be unique");
});

check("a tool call reaches the app as the right command", async (server) => {
  const { result } = await server.request("tools/call", {
    name: "openlens_select_scene",
    arguments: { index: 2 },
  });
  assert.ok(!result.isError, "the call should have succeeded");

  const last = received.at(-1);
  assert.equal(last.command, "scene.select");
  assert.deepEqual(last.params, { index: 2 });
});

check("omitted optional arguments are not sent as nulls", async (server) => {
  await server.request("tools/call", {
    name: "openlens_set_light",
    arguments: { name: "Key", brightness: 40 },
  });
  // The app treats an absent key as "leave this alone". Forwarding `undefined`
  // as an explicit null would read as a value and turn the lamp off.
  assert.deepEqual(received.at(-1).params, { name: "Key", brightness: 40 });
});

check("toggling is what an omitted `paused` means", async (server) => {
  await server.request("tools/call", { name: "openlens_set_pause", arguments: {} });
  assert.equal(received.at(-1).command, "pause.toggle");

  await server.request("tools/call", {
    name: "openlens_set_pause",
    arguments: { paused: true },
  });
  assert.equal(received.at(-1).command, "pause.set");
});

check("a refusal from the app is a tool error, not a protocol error", async (server) => {
  const { result, error } = await server.request("tools/call", {
    name: "openlens_set_zoom",
    arguments: { value: 99 },
  });
  assert.equal(error, undefined, "the JSON-RPC call itself must succeed");
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /positive number/);
});

check("an unknown tool is reported rather than thrown", async (server) => {
  const { result } = await server.request("tools/call", {
    name: "openlens_make_coffee",
    arguments: {},
  });
  assert.equal(result.isError, true);
});

check("a notification is never answered", async (server) => {
  server.notify("notifications/initialized");
  // If the server wrongly replied, that reply would arrive before this one and
  // the id would not match, so the request below would hang.
  const { result } = await server.request("ping");
  assert.deepEqual(result, {});
});

check("watching delivers the state now and again when it changes", async () => {
  const seen = [];
  const stop = watch((state) => seen.push(state), { socketPath });
  // Long enough for the connection, the reply, and the pushed event.
  await new Promise((resolve) => setTimeout(resolve, 300));
  stop();

  // The reply to `events.subscribe` first, so a deck can paint itself before
  // anything changes, then the change.
  assert.deepEqual(seen[0], { paused: false });
  assert.deepEqual(seen[1], { paused: true });
});

check("watching an unavailable socket retries once per second", async () => {
  const missingSocketPath = path.join(path.dirname(socketPath), "missing.sock");
  const createConnection = net.createConnection;
  let attempts = 0;
  net.createConnection = (...args) => {
    attempts += 1;
    return createConnection(...args);
  };

  try {
    const stop = watch(() => {}, { socketPath: missingSocketPath });
    await new Promise((resolve) => setTimeout(resolve, 2_200));
    stop();
  } finally {
    net.createConnection = createConnection;
  }

  assert.ok(attempts <= 3, `expected no more than one attempt per second, got ${attempts}`);
});

check("the app not running is a readable message, not a stack trace", async (server) => {
  await new Promise((resolve) => app.close(resolve));
  const { result } = await server.request("tools/call", {
    name: "openlens_get_state",
    arguments: {},
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /does not appear to be running/);
});

// MARK: - Run

const server = await new Promise((resolve) => {
  app.listen(socketPath, () => resolve(startServer()));
});

let failures = 0;
for (const [name, body] of checks) {
  try {
    await body(server);
    console.log(`  ok  ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL  ${name}\n      ${error.message}`);
  }
}

server.child.kill();
fs.rmSync(path.dirname(socketPath), { recursive: true, force: true });

console.log(`\n${checks.length - failures}/${checks.length} checks passed`);
process.exit(failures === 0 ? 0 : 1);
