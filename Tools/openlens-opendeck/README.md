# openlens-opendeck

An [OpenDeck](https://github.com/nekename/OpenDeck) plugin for OpenLens.

Keys switch scenes, pause the camera, toggle key lights and zoom — and they show
what OpenLens is actually doing. A scene key lights up while its scene is live,
the pause key follows ⌥P, and a light key shows the brightness someone just set
in the app window. That is the part a plugin cannot fake: it holds a
subscription to OpenLens and repaints on every change, rather than remembering
what it last sent.

No dependencies and no build step. OpenDeck runs plugins with the system Node
(20 or newer), and everything here is plain JavaScript.

## Install

```bash
./install.sh
```

This symlinks the plugin into `~/Library/Application Support/opendeck/plugins/`,
which OpenDeck supports. Restart OpenDeck afterwards. The repository has to stay
where it is, because the link points into it — and because the plugin shares the
socket client with [`openlens-mcp`](../openlens-mcp) next door rather than
keeping a copy of it.

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
back without touching OpenDeck.

## Tests

```bash
npm test
```

Runs the plugin between a stand-in for OpenDeck and a stand-in for OpenLens,
including the case that matters most — a change made somewhere else repainting
a key. Offline, and neither OpenDeck nor OpenLens has to be installed.

## An Elgato build

Elgato's own software speaks the same protocol, so the plugin logic carries over
unchanged. What it would still need is Elgato's stricter manifest (`SDKVersion`,
`Software.MinimumVersion` and `Description` are required there, and ignored by
OpenDeck), PNG icons alongside the SVGs, and packaging with Elgato's
`DistributionTool`. Not done here — see issue #6.
