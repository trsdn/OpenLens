# openlens-streamdeck

A plugin for [OpenDeck](https://github.com/nekename/OpenDeck) and the Elgato
Stream Deck, so hardware keys can drive OpenLens.

Keys switch scenes, pause the camera, toggle key lights and zoom — and they show
what OpenLens is actually doing. A scene key lights up while its scene is live,
the pause key follows ⌥P, and a light key shows the brightness someone just set
in the app window. That is the part a plugin cannot fake: it holds a
subscription to OpenLens and repaints on every change, rather than remembering
what it last sent.

One folder serves both apps. They speak the same protocol, and the manifest is
written to the stricter of the two rulebooks, so there is nothing to choose
between and nothing to keep in step.

No dependencies and no build step: OpenDeck runs plugins with the system Node,
Stream Deck with one it bundles, and everything here is plain JavaScript.

## Install

```bash
./install.sh
```

This copies the plugin into whichever apps are installed:

- `~/Library/Application Support/opendeck/plugins/`
- `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`

Restart the app afterwards, and re-run this after any change — both read the
copy, not the repository.

A copy rather than a symlink because OpenDeck does not follow one out of its
plugins directory, and fails at it silently: no error, no plugin process, and
nothing in the log to say why. The install also copies the socket client from
[`openlens-mcp`](../openlens-mcp) into `vendor/`, so the plugin folder is
self-contained without a second copy of that file living in the repository. That
copy is untracked; `./sync.sh` refreshes it, and `npm test` does so on its own.

To hand the plugin to somebody else, Elgato's CLI packages it:

```bash
npm install -g @elgato/cli
streamdeck pack com.trsdn.openlens.sdPlugin
```

## Actions

| Action | What a press does | What the key shows |
| --- | --- | --- |
| **Select scene** | Switches to the chosen scene, or steps to the next one if none is chosen | The scene's name, lit while it is live |
| **Pause** | Freezes the picture the conferencing app sees | Lit while paused |
| **Toggle key light** | Turns a light on or off | The light's brightness, lit while on |
| **Set brightness** | Sets a fixed brightness, or steps up or down | The brightness |
| **Zoom** | Zooms in, out, or back to the full frame | The current zoom |

Scene and light keys pick from a list the plugin fills in live, so you choose a
scene by its name rather than by an id. A key bound to nothing still does
something sensible: the scene key cycles, and a light key drives the only light
if there is only one.

## When OpenLens is not running

Keys show `—` and a press flashes the alert marker rather than failing quietly.
The plugin reconnects on its own, so starting OpenLens later brings the keys
back without touching the deck app.

## Why the plugin brings its own WebSocket

Both apps talk to a plugin over a WebSocket, and Node has had a global one since
22.4. Relying on it would have been the obvious thing and the wrong one: Stream
Deck runs plugins with a Node it bundles, offers `"20"` or — only from Stream
Deck 7.1 — `"24"`, and gives nobody a way to pass it a flag. On Node 20 the
global does not exist, so `new WebSocket(...)` throws before the plugin has done
anything at all.

`deck-socket.js` is the way out. It is the part of RFC 6455 a loopback
connection needs and no more, which is little enough to test properly, and it
lets the manifest ask for Node 20 and support every Stream Deck back to 6.4
rather than only the newest ones. The same code runs on both apps, so there is
one path instead of a fallback nobody exercises.

The same runtime forces a `package.json` inside the plugin folder: Node only
guesses at module syntax from 22.7, so without `"type": "module"` an older one
refuses to load `plugin.js` at all.

## Tests

```bash
npm test
```

Three suites, all offline, with neither deck app nor OpenLens installed:

- **manifest** — that every file the manifest names exists, and that it still
  obeys the rules Elgato enforces and OpenDeck does not care about. Elgato's
  published schema at `schemas.elgato.com/streamdeck/plugins/manifest.json` is
  the real authority, and the manifest validates against it, but a check that
  needs the network is a check that gets skipped.
- **deck-socket** — the WebSocket client against a stand-in server: fragmented
  messages, frames split across packets, payloads past both length boundaries,
  a handshake that should be refused.
- **smoke** — the plugin itself, between a stand-in for a deck and a stand-in
  for OpenLens, including the case that matters most: a change made somewhere
  else repainting a key.

The last one runs a *copy* of the plugin folder, and runs it with
`--no-experimental-websocket --no-experimental-detect-module`, so it sees what
Stream Deck's older Node would: no global WebSocket, no module detection, and no
`package.json` above it to borrow settings from. All three are easy to depend on
by accident here, and each would only fail on somebody else's machine.

## What has not been tested

The Elgato app is not installed on the machine this was written on. The manifest
validates against Elgato's schema and the plugin runs under a runtime made to
behave like theirs, but nothing here has met a real Stream Deck. OpenDeck has:
it loads this plugin and drives OpenLens.
