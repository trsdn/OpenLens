#!/usr/bin/env bash
#
# Copies the socket client into the plugin folder.
#
# The plugin has to be a self-contained folder, because OpenDeck copies nothing
# and — on the version tested here — does not follow a symlink out of its
# plugins directory. Rather than keep a second, drifting copy of the client in
# the repository, it is copied in on demand and left untracked.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="$here/../openlens-mcp/src/client.js"
target_dir="$here/com.trsdn.openlens.sdPlugin/vendor"

mkdir -p "$target_dir"
cp "$source_file" "$target_dir/client.js"
