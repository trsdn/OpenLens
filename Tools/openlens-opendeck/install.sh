#!/usr/bin/env bash
#
# Installs the plugin into OpenDeck.
#
# A copy rather than a symlink: OpenDeck does not follow one out of its plugins
# directory, so a linked plugin is silently never loaded — no error, no process,
# nothing in the log. Re-run this after changing the plugin.

set -euo pipefail

plugin="com.trsdn.openlens.sdPlugin"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

"$here/sync.sh"

rm -rf "$target"
cp -R "$here/$plugin" "$target"

echo "Installed $plugin into OpenDeck:"
echo "  $target"
echo
echo "Restart OpenDeck to pick it up, and run this again after any change —"
echo "OpenDeck reads the copy, not the repository."
