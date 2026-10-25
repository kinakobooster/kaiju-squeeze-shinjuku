#!/bin/sh
# Export the Web build to build/web and copy the hand-tracking script next to it.
set -e
cd "$(dirname "$0")"
mkdir -p build/web
godot --headless --path . --export-release "Web" build/web/index.html
cp web_shell/hand_tracking.js build/web/
echo "Done. Serve with:  python3 -m http.server 8060 -d build/web  ->  http://localhost:8060"
