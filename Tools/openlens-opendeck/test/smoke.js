#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

/**
 * Runs the plugin between a stand-in for OpenDeck and a stand-in for OpenLens.
 *
 * Everything interesting about this plugin is the join between those two, and
 * none of it is visible from reading the file: that a key press comes out of
 * the other side as the right command, and — the part that actually earns its
 * keep — that a change nobody asked for repaints the key.
 *
 * No dependencies, no network beyond loopback, and OpenLens does not have to be
 * installed. Run with `npm test`.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const pluginPath = path.join(here, "..", "com.trsdn.openlens.sdPlugin", "plugin.js");
const PLUGIN_UUID = "com.trsdn.openlens.sdPlugin";

// MARK: - A stand-in for OpenLens

const socketPath = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), "openlens-deck-")),
    "control.sock"
);

/** Every command the fake app was asked to run, in order. */
const commands = [];
let subscriber = null;
let cameraState = {
    paused: false,
    zoom: 1,
    scene: { id: "a", index: 1, name: "Wide", isSelected: true },
    scenes: [
        { id: "a", index: 1, name: "Wide", isSelected: true },
        { id: "b", index: 2, name: "Close", isSelected: false },
    ],
    lights: [{ serialNumber: "KL1", name: "Desk", on: false, brightness: 20, kelvin: 4000 }],
};

const camera = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        let newline;
        while ((newline = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, newline);
            buffer = buffer.slice(newline + 1);
            if (!line.trim()) continue;

            const request = JSON.parse(line);
            if (request.command === "events.subscribe") {
                subscriber = socket;
                socket.write(JSON.stringify({ id: request.id, ok: true, result: cameraState }) + "\n");
                continue;
            }
            commands.push(request);
            socket.write(JSON.stringify({ id: request.id, ok: true, result: {} }) + "\n");
        }
    });
});

/** Pushes a new state, the way the real app does when anything changes. */
function pushState(patch) {
    cameraState = { ...cameraState, ...patch };
    subscriber?.write(JSON.stringify({ event: "state", state: cameraState }) + "\n");
}

// MARK: - A stand-in for OpenDeck
//
// Just enough of RFC 6455 to carry small text frames in both directions, which
// is all the Stream Deck protocol ever needs. Writing it out is what lets this
// test exist at all without a dependency.

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** Messages the plugin sent us, in order. */
const fromPlugin = [];
const waiters = [];
let pluginSocket = null;

function deliver(message) {
    fromPlugin.push(message);
    for (const [index, waiter] of waiters.entries()) {
        if (waiter.matches(message)) {
            waiters.splice(index, 1);
            waiter.resolve(message);
            return;
        }
    }
}

/** Resolves with the next message matching `matches`, whenever it arrives. */
function nextMessage(matches, description) {
    const found = fromPlugin.find(matches);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
        const waiter = { matches, resolve };
        waiters.push(waiter);
        setTimeout(() => {
            const index = waiters.indexOf(waiter);
            if (index < 0) return;
            waiters.splice(index, 1);
            reject(new Error(`timed out waiting for ${description}`));
        }, 4000);
    });
}

const deck = http.createServer();

deck.on("upgrade", (request, socket) => {
    const accept = crypto
        .createHash("sha1")
        .update(request.headers["sec-websocket-key"] + GUID)
        .digest("base64");
    socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    pluginSocket = socket;

    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        let frame;
        while ((frame = readFrame(buffer))) {
            buffer = buffer.subarray(frame.length);
            if (frame.payload !== null) deliver(JSON.parse(frame.payload));
        }
    });
});

/** Reads one client frame, or null when there is not a whole one yet. */
function readFrame(buffer) {
    if (buffer.length < 2) return null;
    const opcode = buffer[0] & 0x0f;
    const masked = (buffer[1] & 0x80) !== 0;
    let length = buffer[1] & 0x7f;
    let offset = 2;

    if (length === 126) {
        if (buffer.length < 4) return null;
        length = buffer.readUInt16BE(2);
        offset = 4;
    } else if (length === 127) {
        if (buffer.length < 10) return null;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
    }

    const mask = masked ? buffer.subarray(offset, offset + 4) : null;
    if (masked) offset += 4;
    if (buffer.length < offset + length) return null;

    const payload = Buffer.from(buffer.subarray(offset, offset + length));
    if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];

    // Text frames carry the protocol; a close or a ping is not something this
    // test has an opinion about.
    return { length: offset + length, payload: opcode === 0x1 ? payload.toString("utf8") : null };
}

function toPlugin(message) {
    const payload = Buffer.from(JSON.stringify(message), "utf8");
    let header;
    if (payload.length < 126) {
        header = Buffer.from([0x81, payload.length]);
    } else {
        header = Buffer.alloc(4);
        header[0] = 0x81;
        header[1] = 126;
        header.writeUInt16BE(payload.length, 2);
    }
    pluginSocket.write(Buffer.concat([header, payload]));
}

// MARK: - Checks

const checks = [];
const check = (name, body) => checks.push([name, body]);

const keyContext = (name) => `DEVICE.Profile.Keypad.${name}.0`;

/** Long enough for a round trip through both fakes. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 400));

check("the plugin registers itself with the uuid it was given", async () => {
    const message = await nextMessage((m) => m.event === "registerPlugin", "registerPlugin");
    assert.equal(message.uuid, PLUGIN_UUID);
});

check("a key that appears is painted from the state, not left blank", async () => {
    toPlugin({
        event: "willAppear",
        action: "com.trsdn.openlens.pause",
        context: keyContext("pause"),
        payload: { settings: {}, state: 0 },
    });
    const message = await nextMessage(
        (m) => m.event === "setState" && m.context === keyContext("pause"),
        "the pause key to be painted"
    );
    assert.equal(message.payload.state, 0);
});

check("a change nobody asked for repaints the key", async () => {
    // The whole reason the plugin holds a subscription: this is what happens
    // when someone presses ⌥P instead of the deck key.
    pushState({ paused: true });
    const message = await nextMessage(
        (m) => m.event === "setState" && m.context === keyContext("pause") && m.payload.state === 1,
        "the pause key to follow the app"
    );
    assert.equal(message.payload.state, 1);
});

check("pressing a key reaches OpenLens as the right command", async () => {
    toPlugin({
        event: "keyDown",
        action: "com.trsdn.openlens.pause",
        context: keyContext("pause"),
        payload: { settings: {}, state: 1 },
    });
    await settle();
    assert.equal(commands.at(-1).command, "pause.toggle");
});

check("a scene key shows its own name and whether it is live", async () => {
    toPlugin({
        event: "willAppear",
        action: "com.trsdn.openlens.scene",
        context: keyContext("scene"),
        payload: { settings: { sceneId: "b" }, state: 0 },
    });
    const title = await nextMessage(
        (m) => m.event === "setTitle" && m.context === keyContext("scene"),
        "the scene key's title"
    );
    assert.equal(title.payload.title, "Close");

    const state = await nextMessage(
        (m) => m.event === "setState" && m.context === keyContext("scene"),
        "the scene key's state"
    );
    // Scene "b" is not the selected one, so the key must not claim to be live.
    assert.equal(state.payload.state, 0);
});

check("a scene key bound to nothing steps through the scenes", async () => {
    toPlugin({
        event: "willAppear",
        action: "com.trsdn.openlens.scene",
        context: keyContext("unbound"),
        payload: { settings: {}, state: 0 },
    });
    toPlugin({
        event: "keyDown",
        action: "com.trsdn.openlens.scene",
        context: keyContext("unbound"),
        payload: { settings: {}, state: 0 },
    });
    await settle();
    assert.equal(commands.at(-1).command, "scene.next");
});

check("the property inspector is handed the lists it cannot know", async () => {
    toPlugin({
        event: "sendToPlugin",
        action: "com.trsdn.openlens.scene",
        context: keyContext("scene"),
        payload: { request: "options" },
    });
    const message = await nextMessage(
        (m) => m.event === "sendToPropertyInspector",
        "the options for the inspector"
    );
    assert.deepEqual(
        message.payload.scenes.map((entry) => entry.label),
        ["1. Wide", "2. Close"]
    );
    assert.deepEqual(message.payload.lights, [{ value: "KL1", label: "Desk" }]);
    assert.equal(message.payload.running, true);
});

check("a light key toggles the light it is bound to", async () => {
    toPlugin({
        event: "willAppear",
        action: "com.trsdn.openlens.light",
        context: keyContext("light"),
        payload: { settings: { serialNumber: "KL1" }, state: 0 },
    });
    toPlugin({
        event: "keyDown",
        action: "com.trsdn.openlens.light",
        context: keyContext("light"),
        payload: { settings: { serialNumber: "KL1" }, state: 0 },
    });
    await settle();
    // The light is off in the state, so the press must ask for on rather than
    // blindly toggling whatever the key last thought.
    assert.deepEqual(commands.at(-1).params, { serialNumber: "KL1", on: true });
});

check("a brightness key steps from where the light actually is", async () => {
    const settings = { serialNumber: "KL1", step: 10 };
    toPlugin({
        event: "willAppear",
        action: "com.trsdn.openlens.brightness",
        context: keyContext("brightness"),
        payload: { settings, state: 0 },
    });
    toPlugin({
        event: "keyDown",
        action: "com.trsdn.openlens.brightness",
        context: keyContext("brightness"),
        payload: { settings, state: 0 },
    });
    await settle();
    assert.deepEqual(commands.at(-1).params, { serialNumber: "KL1", brightness: 30 });
});

check("a light key bound to nothing resolves the one light there is", async () => {
    toPlugin({
        event: "willAppear",
        action: "com.trsdn.openlens.light",
        context: keyContext("onlylight"),
        payload: { settings: { serialNumber: "" }, state: 0 },
    });
    toPlugin({
        event: "keyDown",
        action: "com.trsdn.openlens.light",
        context: keyContext("onlylight"),
        payload: { settings: { serialNumber: "" }, state: 0 },
    });
    await settle();
    // An empty setting must not reach the app, which refuses to guess.
    assert.deepEqual(commands.at(-1).params, { serialNumber: "KL1", on: true });
});

check("keys say so when OpenLens goes away, rather than lying", async () => {
    // Dropping the connection first: `close` waits for open connections, and
    // the plugin's subscription is one.
    subscriber?.destroy();
    await new Promise((resolve) => camera.close(resolve));
    const message = await nextMessage(
        (m) => m.event === "setTitle" && m.payload.title === "—",
        "a key to admit the app is gone"
    );
    assert.equal(message.payload.title, "—");
});

// MARK: - Run

await new Promise((resolve) => camera.listen(socketPath, resolve));
await new Promise((resolve) => deck.listen(0, "127.0.0.1", resolve));

const plugin = spawn(
    process.execPath,
    [
        pluginPath,
        "-port", String(deck.address().port),
        "-pluginUUID", PLUGIN_UUID,
        "-registerEvent", "registerPlugin",
        "-info", JSON.stringify({ application: { platform: "mac" } }),
    ],
    { env: { ...process.env, OPENLENS_SOCKET: socketPath }, stdio: ["ignore", "inherit", "inherit"] }
);

let failures = 0;
for (const [name, body] of checks) {
    try {
        await body();
        console.log(`  ok  ${name}`);
    } catch (error) {
        failures += 1;
        console.log(`  FAIL  ${name}`);
        console.log(`        ${error.message}`);
    }
}

plugin.kill();
deck.close();

console.log(`\n${checks.length - failures}/${checks.length} checks passed`);
process.exit(failures === 0 ? 0 : 1);
