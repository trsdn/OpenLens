#!/usr/bin/env bash
#
# Links the plugin into OpenDeck.
#
# A symlink rather than a copy, which OpenDeck supports and which means the
# plugin you edit is the plugin that runs — and that it shares the socket
# client with the MCP server next door instead of carrying a stale copy of it.

set -euo pipefail

plugin="com.trsdn.openlens.sdPlugin"
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$plugin"
plugins_dir="$HOME/Library/Application Support/opendeck/plugins"
target="$plugins_dir/$plugin"

if ! command -v node >/dev/null; then
    echo "OpenDeck runs plugins with the system node, and there isn't one on PATH." >&2
    echo "Install Node 20 or newer, then run this again." >&2
    exit 1
fi

version="$(node --version)"
if [[ "${version#v}" < "20" ]]; then
    echo "OpenDeck needs Node 20 or newer to run a plugin; this is $version." >&2
    exit 1
fi

if [[ ! -d "$plugins_dir" ]]; then
    echo "No OpenDeck plugins directory at:" >&2
    echo "  $plugins_dir" >&2
    echo "Start OpenDeck once so that it creates one, then run this again." >&2
    exit 1
fi

# Only ever removing our own link, never somebody's real folder.
if [[ -L "$target" ]]; then
    rm "$target"
elif [[ -e "$target" ]]; then
    echo "Something that is not a symlink is already at:" >&2
    echo "  $target" >&2
    echo "Move it aside first." >&2
    exit 1
fi

ln -s "$source_dir" "$target"

echo "Linked $plugin into OpenDeck:"
echo "  $target -> $source_dir"
echo
echo "Restart OpenDeck to pick it up. The repository has to stay where it is,"
echo "because the link points into it."
