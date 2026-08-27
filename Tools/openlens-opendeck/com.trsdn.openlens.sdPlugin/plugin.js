#!/usr/bin/env node
import process from "node:process";

import { send, watch, NotRunningError } from "../../openlens-mcp/src/client.js";

/**
 * An OpenDeck plugin for OpenLens.
 *
 * Two connections, in opposite directions. OpenDeck tells us which keys exist
 * and when one is pressed; OpenLens tells us what is true right now. The whole
 * plugin is the join between them: a press becomes a command, and a change
 * becomes a repaint of every key that shows it.
 *
 * That second half is the point. Scenes also change from the ⌥1…⌥9 hotkeys and
 * from the app window, and a key that only knew what it last sent would sit
 * there lying about it.
 *
 * OpenDeck runs this with the system `node` (v20+), so there is nothing to
 * install and nothing to build.
 */

const args = process.argv.slice(2);
const argument = (flag) => args[args.indexOf(flag) + 1];

const port = argument("-port");
const pluginUUID = argument("-pluginUUID");
const registerEvent = argument("-registerEvent");

/** Every key of ours currently on a device, by context. */
const keys = new Map();

/** The last state OpenLens sent, or null while it is not running. */
let camera = null;

let deck;

// MARK: - OpenDeck

function connectToDeck() {
    deck = new WebSocket(`ws://127.0.0.1:${port}`);

    deck.addEventListener("open", () => {
        deck.send(JSON.stringify({ event: registerEvent, uuid: pluginUUID }));
    });

    deck.addEventListener("message", ({ data }) => {
        let message;
        try {
            message = JSON.parse(data);
        } catch {
            return;
        }
        handle(message);
    });

    // OpenDeck kills the plugin when it unloads it, so a closed socket means we
    // are on our way out rather than that we should try again.
    deck.addEventListener("close", () => process.exit(0));
    deck.addEventListener("error", () => process.exit(1));
}

function toDeck(event, context, payload) {
    if (deck?.readyState !== WebSocket.OPEN) return;
    deck.send(JSON.stringify(payload ? { event, context, payload } : { event, context }));
}

function handle(message) {
    const { event, context, action, payload } = message;
    switch (event) {
        case "willAppear":
            keys.set(context, { action, settings: payload?.settings ?? {} });
            render(context);
            break;

        case "willDisappear":
            keys.delete(context);
            break;

        case "didReceiveSettings":
            if (keys.has(context)) keys.get(context).settings = payload?.settings ?? {};
            render(context);
            break;

        case "keyDown":
            press(context).catch((error) => {
                // A refusal is worth showing on the key itself: the person
                // pressing it is looking at the device, not at a log file.
                toDeck("showAlert", context);
                log(error instanceof NotRunningError ? "OpenLens is not running" : error.message);
            });
            break;

        case "propertyInspectorDidAppear":
        case "sendToPlugin":
            // Both mean the same thing to us: an inspector is open and wants
            // the list it cannot know by itself.
            toDeck("sendToPropertyInspector", context, {
                scenes: (camera?.scenes ?? []).map((scene) => ({
                    value: scene.id,
                    label: `${scene.index}. ${scene.name}`,
                })),
                lights: (camera?.lights ?? []).map((light) => ({
                    value: light.serialNumber,
                    label: light.name,
                })),
                running: camera !== null,
            });
            break;
    }
}

function log(message) {
    if (deck?.readyState === WebSocket.OPEN) {
        deck.send(JSON.stringify({ event: "logMessage", payload: { message: `OpenLens: ${message}` } }));
    }
}

// MARK: - Presses

async function press(context) {
    const key = keys.get(context);
    if (!key) return;
    const settings = key.settings;

    switch (key.action) {
        case "com.trsdn.openlens.scene":
            // Falling back to stepping means a freshly dropped key does
            // something sensible before anyone opens its settings.
            if (settings.sceneId) await send("scene.select", { id: settings.sceneId });
            else await send("scene.next");
            break;

        case "com.trsdn.openlens.pause":
            await send("pause.toggle");
            break;

        case "com.trsdn.openlens.light":
            await send("light.set", { serialNumber: serialFor(settings), on: !lightFor(settings)?.on });
            break;

        case "com.trsdn.openlens.brightness": {
            const light = lightFor(settings);
            const step = Number(settings.step ?? 0);
            const brightness = step
                ? clamp((light?.brightness ?? 0) + step, 0, 100)
                : clamp(Number(settings.brightness ?? 50), 0, 100);
            await send("light.set", { serialNumber: serialFor(settings), brightness });
            break;
        }

        case "com.trsdn.openlens.zoom":
            await send(
                { in: "zoom.in", out: "zoom.out", reset: "zoom.reset" }[settings.direction] ?? "zoom.reset"
            );
            break;
    }
}

/** The light a key is bound to, or the only one there is when it is bound to none. */
function lightFor(settings) {
    const lights = camera?.lights ?? [];
    if (!settings.serialNumber) return lights.length === 1 ? lights[0] : undefined;
    return lights.find((light) => light.serialNumber === settings.serialNumber);
}

/**
 * The serial number to send.
 *
 * A key left on "the only one found" carries an empty setting, and the app
 * rejects that rather than guessing — so resolve it here, where the light list
 * is known, and say something useful when it cannot be resolved.
 */
function serialFor(settings) {
    const serial = lightFor(settings)?.serialNumber;
    if (serial) return serial;
    throw new Error(
        settings.serialNumber
            ? `No key light with serial number ${settings.serialNumber}`
            : "There is more than one key light, so this key needs to say which one"
    );
}

const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

// MARK: - Painting

function render(context) {
    const key = keys.get(context);
    if (!key) return;

    // Rather than blank keys: the labels stay, so the layout still reads as
    // something that will work once the app is back.
    if (!camera) {
        toDeck("setState", context, { state: 0 });
        toDeck("setTitle", context, { title: "—" });
        return;
    }

    const settings = key.settings;
    switch (key.action) {
        case "com.trsdn.openlens.scene": {
            const scene =
                (camera.scenes ?? []).find((candidate) => candidate.id === settings.sceneId) ??
                (settings.sceneId ? undefined : camera.scene);
            toDeck("setState", context, { state: scene?.isSelected ? 1 : 0 });
            toDeck("setTitle", context, { title: scene?.name ?? "?" });
            break;
        }

        case "com.trsdn.openlens.pause":
            toDeck("setState", context, { state: camera.paused ? 1 : 0 });
            break;

        case "com.trsdn.openlens.light": {
            const light = lightFor(settings);
            toDeck("setState", context, { state: light?.on ? 1 : 0 });
            toDeck("setTitle", context, { title: light ? `${light.brightness}%` : "?" });
            break;
        }

        case "com.trsdn.openlens.brightness": {
            const light = lightFor(settings);
            const step = Number(settings.step ?? 0);
            // A stepping key shows where it would take you is meaningless, so
            // it shows where things are; a fixed key shows what it will set.
            const title = step
                ? `${light?.brightness ?? "?"}%`
                : `${clamp(Number(settings.brightness ?? 50), 0, 100)}%`;
            toDeck("setTitle", context, { title });
            break;
        }

        case "com.trsdn.openlens.zoom":
            toDeck("setTitle", context, { title: `${(camera.zoom ?? 1).toFixed(1)}×` });
            break;
    }
}

const renderAll = () => {
    for (const context of keys.keys()) render(context);
};

// MARK: - OpenLens

connectToDeck();

watch(
    (state) => {
        camera = state;
        renderAll();
    },
    {
        onError: (error) => log(error.message),
        onDisconnect: () => {
            camera = null;
            renderAll();
        },
    }
);
