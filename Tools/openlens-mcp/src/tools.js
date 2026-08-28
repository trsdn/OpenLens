import { send } from "./client.js";

/**
 * The tools the model sees.
 *
 * Deliberately not one tool per control command. The socket exposes about
 * thirty; handing all of them over makes the choice harder rather than the
 * agent more capable, so related commands are folded together and the ones that
 * only make sense with a window in front of you are left out.
 *
 * Descriptions carry the units and the conventions — normalized coordinates,
 * one-based scene numbers, kelvin rather than mired — because that is the only
 * documentation the model gets.
 */

const object = (properties, required = []) => ({
  type: "object",
  properties,
  required,
  additionalProperties: false,
});

const sceneSelector = {
  index: {
    type: "integer",
    description: "One-based position in the scene list, matching the ⌥1…⌥9 shortcuts.",
  },
  name: { type: "string", description: "Scene name, matched case-insensitively." },
  id: { type: "string", description: "Scene UUID, as returned by openlens_list_scenes." },
};

const adjustmentFields = Object.fromEntries(
  [
    ["exposure", "Stops of exposure. Negative darkens, positive brightens."],
    ["blackPoint", "Where the darkest pixel lands. Positive deepens the shadows."],
    ["whitePoint", "Where the brightest pixel lands. Positive brightens the highlights."],
    ["midtones", "Gamma. Positive opens the midtones without moving either end."],
    ["contrast", "Negative flattens, positive steepens around mid grey."],
    ["saturation", "-1 is monochrome, +1 is twice the colour."],
    ["temperature", "White balance. Negative cools towards blue, positive warms towards amber."],
    ["tint", "The other white balance axis. Negative towards green, positive towards magenta."],
    ["shadowWarmth", "White balance for the shadows alone, on the warm/cool axis."],
    ["highlightWarmth", "White balance for the highlights alone, on the warm/cool axis."],
  ].map(([key, description]) => [
    key,
    { type: "number", minimum: -1, maximum: 1, description: `${description} 0 is neutral.` },
  ])
);

export const TOOLS = [
  {
    name: "openlens_get_state",
    description:
      "Everything OpenLens currently knows: the selected scene, all scenes, the live zoom and " +
      "crop, whether a conferencing app is streaming, whether the picture is paused, the " +
      "available cameras and the known key lights. Call this first when unsure.",
    inputSchema: object({}),
    run: () => send("state.get"),
  },
  {
    name: "openlens_list_scenes",
    description:
      "The saved scenes. A scene is a camera, a zoom and crop, mirroring, an overlay and " +
      "optionally a set of key light states.",
    inputSchema: object({}),
    run: () => send("scene.list"),
  },
  {
    name: "openlens_select_scene",
    description:
      "Switches to a saved scene, which changes the picture the conferencing app sees " +
      "immediately. Identify it by index, name or id, or step through the list with " +
      "`direction`, which wraps at both ends.",
    inputSchema: object({
      ...sceneSelector,
      direction: {
        type: "string",
        enum: ["next", "previous"],
        description: "Step relative to the current scene instead of naming one.",
      },
    }),
    run: (args) => {
      if (args.direction === "next") return send("scene.next");
      if (args.direction === "previous") return send("scene.previous");
      return send("scene.select", args);
    },
  },
  {
    name: "openlens_manage_scenes",
    description:
      "Creates, copies, renames or deletes scenes. `add` starts from the first available " +
      "camera; `duplicate` snapshots the current look, which is the usual way to make a " +
      "variant. `remove` deletes the selected scene and cannot be undone.",
    inputSchema: object(
      {
        action: { type: "string", enum: ["add", "duplicate", "rename", "remove"] },
        name: {
          type: "string",
          description: "The new name. Required for `rename`, optional for `add` and `duplicate`.",
        },
      },
      ["action"]
    ),
    run: ({ action, name }) => send(`scene.${action}`, { name }),
  },
  {
    name: "openlens_set_zoom",
    description:
      "Sets the zoom on the selected scene, centred on the current crop. 1 is the whole frame. " +
      "The answer reports `losslessZoomLimit` and `isSoft`: past that limit the picture is " +
      "upscaled and visibly softer, so prefer staying under it.",
    inputSchema: object(
      { value: { type: "number", exclusiveMinimum: 0, description: "Zoom factor, e.g. 1.5." } },
      ["value"]
    ),
    run: (args) => send("zoom.set", args),
  },
  {
    name: "openlens_pan",
    description:
      "Moves the crop across the source frame without changing the zoom. Offsets are in " +
      "normalized units of the source picture, so 0.1 is a tenth of its width. Positive dx " +
      "moves the crop right, positive dy moves it down. Panning is clamped to the frame, so " +
      "an overlarge value simply stops at the edge.",
    inputSchema: object({
      dx: { type: "number", description: "Horizontal offset, normalized. Default 0." },
      dy: { type: "number", description: "Vertical offset, normalized. Default 0." },
    }),
    run: (args) => send("pan.by", args),
  },
  {
    name: "openlens_reset_zoom",
    description: "Returns the selected scene to the full, uncropped frame.",
    inputSchema: object({}),
    run: () => send("zoom.reset"),
  },
  {
    name: "openlens_set_pause",
    description:
      "Freezes the picture the conferencing app sees on its last frame and hands the physical " +
      "camera back, so its light goes out. Any key lights the scene owns go dark with it. The " +
      "virtual camera keeps running, so the call never sees the device disappear. Omit " +
      "`paused` to toggle.",
    inputSchema: object({
      paused: { type: "boolean", description: "Omit to toggle the current state." },
    }),
    run: ({ paused }) =>
      paused === undefined ? send("pause.toggle") : send("pause.set", { paused }),
  },
  {
    name: "openlens_list_cameras",
    description:
      "The cameras that can be used as a source. OpenLens's own virtual camera is never among " +
      "them, because that would feed its output back into its input.",
    inputSchema: object({}),
    run: () => send("device.list"),
  },
  {
    name: "openlens_set_camera",
    description:
      "Points the selected scene at a different physical camera. Identify it by name or id " +
      "from openlens_list_cameras.",
    inputSchema: object({
      name: { type: "string", description: "Camera name, matched case-insensitively." },
      id: { type: "string", description: "Camera unique id." },
    }),
    run: (args) => send("device.set", args),
  },
  {
    name: "openlens_set_camera_options",
    description:
      "Mirroring, capture quality and the local preview. `losslessZoom` captures up to 4K so " +
      "zooming stays sharp; `matchOutput` captures 1080p, which is smoother on cameras limited " +
      "by USB bandwidth. Turning the preview off saves a render pass per frame.",
    inputSchema: object({
      mirrored: { type: "boolean", description: "Whether the picture is flipped horizontally." },
      quality: { type: "string", enum: ["losslessZoom", "matchOutput"] },
      previewEnabled: {
        type: "boolean",
        description: "The preview in the app window. Does not affect what the call sees.",
      },
    }),
    run: async ({ mirrored, quality, previewEnabled }) => {
      if (mirrored === undefined && quality === undefined && previewEnabled === undefined) {
        throw new Error("Give at least one of `mirrored`, `quality` or `previewEnabled`");
      }
      let state;
      if (mirrored !== undefined) state = await send("mirror.set", { mirrored });
      if (quality !== undefined) state = await send("quality.set", { quality });
      if (previewEnabled !== undefined) state = await send("preview.set", { enabled: previewEnabled });
      return state;
    },
  },
  {
    name: "openlens_set_adjustments",
    description:
      "Colour correction on the selected scene. Every value runs from -1 to 1 and is neutral " +
      "at 0. Only the fields given are changed, so nudging one leaves the rest alone. Effects " +
      "are subtle by design: start around ±0.2 rather than ±1.",
    inputSchema: object(adjustmentFields),
    run: (args) => send("adjustments.set", args),
  },
  {
    name: "openlens_reset_adjustments",
    description: "Returns every colour adjustment on the selected scene to neutral.",
    inputSchema: object({}),
    run: () => send("adjustments.reset"),
  },
  {
    name: "openlens_set_overlay",
    description:
      "Turns the selected scene's overlay image on or off and sets its opacity. The image " +
      "itself has to be picked in the app, because choosing a file is what grants OpenLens " +
      "permission to read it.",
    inputSchema: object({
      enabled: { type: "boolean" },
      opacity: { type: "number", minimum: 0, maximum: 1 },
    }),
    run: (args) => send("overlay.set", args),
  },
  {
    name: "openlens_list_lights",
    description:
      "The Elgato Key Lights found on the network, with their current state and whether the " +
      "selected scene drives them. Lights marked `inScene` follow scene changes and go dark on " +
      "pause; the others are left alone.",
    inputSchema: object({}),
    run: () => send("light.list"),
  },
  {
    name: "openlens_set_light",
    description:
      "Sets a key light's power, brightness and colour temperature in one go, which avoids the " +
      "visible double step of changing them separately. Colour temperature is in kelvin " +
      "(roughly 2900 warm to 7000 cool). Target one light by serial number or name, or pass " +
      "`all: true` to hit every one in the room.",
    inputSchema: object({
      serialNumber: { type: "string" },
      name: { type: "string", description: "The name set in the Elgato app." },
      all: { type: "boolean", description: "Apply to every known light." },
      on: { type: "boolean" },
      brightness: { type: "integer", minimum: 0, maximum: 100, description: "Percent." },
      kelvin: { type: "integer", minimum: 2900, maximum: 7000 },
    }),
    run: (args) => send("light.set", args),
  },
  {
    name: "openlens_set_scene_lighting",
    description:
      "Decides whether the selected scene drives the lights. `capture` records what the lamps " +
      "are doing now as part of the scene, so switching to it later restores the light along " +
      "with the framing. `clear` makes the scene leave the room untouched. `include` and " +
      "`exclude` add or remove a single lamp.",
    inputSchema: object(
      {
        action: { type: "string", enum: ["capture", "clear", "include", "exclude"] },
        serialNumber: { type: "string", description: "Required for `include` and `exclude`." },
        name: { type: "string", description: "Light name, as an alternative to the serial number." },
      },
      ["action"]
    ),
    run: ({ action, serialNumber, name }) => {
      if (action === "capture") return send("light.captureIntoScene");
      if (action === "clear") return send("light.clearFromScene");
      return send("light.setInScene", {
        inScene: action === "include",
        serialNumber,
        name,
      });
    },
  },
];
