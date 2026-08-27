/**
 * The half of a property inspector that is the same for every action:
 * the handshake, the settings round-trip, and asking the plugin for the lists
 * it is the only one that knows.
 *
 * A page includes this, then calls `OpenLensPI.ready(...)` and gets handed
 * everything it needs.
 */

const OpenLensPI = (() => {
    let socket;
    let context;
    let settings = {};
    let options = { scenes: [], lights: [], running: false };
    let onReady = () => {};

    // Called by OpenDeck (and by Elgato's software) once the page is loaded.
    window.connectElgatoStreamDeckSocket = (port, uuid, registerEvent, _info, actionInfo) => {
        context = uuid;
        settings = JSON.parse(actionInfo).payload.settings ?? {};
        socket = new WebSocket(`ws://127.0.0.1:${port}`);

        socket.addEventListener("open", () => {
            socket.send(JSON.stringify({ event: registerEvent, uuid }));
            // The plugin holds the live scene and light lists; nothing on this
            // page could work them out.
            socket.send(
                JSON.stringify({ event: "sendToPlugin", context, payload: { request: "options" } })
            );
            onReady({ settings, options });
        });

        socket.addEventListener("message", ({ data }) => {
            const message = JSON.parse(data);
            if (message.event === "sendToPropertyInspector") {
                options = message.payload;
                onReady({ settings, options });
            }
            if (message.event === "didReceiveSettings") {
                settings = message.payload.settings ?? {};
                onReady({ settings, options });
            }
        });
    };

    function save(patch) {
        settings = { ...settings, ...patch };
        socket.send(JSON.stringify({ event: "setSettings", context, payload: settings }));
    }

    return {
        ready(callback) {
            onReady = callback;
        },
        save,
    };
})();

/** Fills a `<select>`, keeping whatever is already chosen selected. */
function fillSelect(select, entries, selected, placeholder) {
    select.innerHTML = "";
    if (placeholder) {
        const option = document.createElement("option");
        option.value = "";
        option.textContent = placeholder;
        select.append(option);
    }
    for (const entry of entries) {
        const option = document.createElement("option");
        option.value = entry.value;
        option.textContent = entry.label;
        select.append(option);
    }
    select.value = selected ?? "";
}
