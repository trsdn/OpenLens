# openlens-mcp

An MCP server and a small command-line client for OpenLens.

OpenLens listens on a unix socket inside its app group container. This package
is the thing in front of it: it exposes the camera as MCP tools so an AI agent
can drive it, and it doubles as a plain CLI for scripts and Stream Deck
plugins.

Nothing here is installed or fetched at run time — no dependencies, no build
step. Node 18 or newer is enough.

## Using it from an MCP client

```json
{
  "mcpServers": {
    "openlens": {
      "command": "node",
      "args": ["/path/to/OpenLens/Tools/openlens-mcp/src/index.js"]
    }
  }
}
```

OpenLens has to be running. If it is not, every tool answers with a readable
message saying so rather than failing the call.

## Using it from a shell

```bash
node src/index.js call state.get
node src/index.js call scene.select '{"index": 2}'
node src/index.js call zoom.set '{"value": 2.5}'
node src/index.js call commands.list      # every command the app accepts
```

`call` speaks the app's own command names, which are a little finer-grained
than the MCP tools. `commands.list` is the authoritative list.

## Watching for changes

```bash
node src/index.js watch
```

Prints one JSON object per line: the state now, and the state again every time
it changes — including changes made with the ⌥1…⌥9 hotkeys or in the app
window. This is what a Stream Deck key needs to stay in step with the app
rather than showing whatever was true when it was last pressed.

The watcher reconnects on its own, so OpenLens quitting and coming back does
not end the stream.

In a plugin, use the client directly:

```js
import { watch, send } from "./src/client.js";

const stop = watch((state) => {
  // state.paused, state.scene, state.scenes, state.lights, state.zoom …
});

await send("scene.next");
```

## The socket

```
~/Library/Group Containers/G69Z5BNY97.com.trsdn.openlens/control.sock
```

Access control is the file's permissions: it is reachable by the user running
OpenLens and nobody else. There is no port, no token and nothing listening on
the network.

Override the path with `OPENLENS_SOCKET`, which is mostly useful for tests.

## Tests

```bash
npm test
```

Runs the MCP server and the watcher against a stand-in for OpenLens. Offline,
and does not need the app.
