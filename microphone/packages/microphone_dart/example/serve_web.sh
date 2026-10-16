#!/usr/bin/env bash
# Builds the web capture example to JS and serves it on http://localhost:8080.
# Open that URL in a browser and click Record (browsers require a user gesture,
# and a secure context -- localhost counts -- before granting microphone access).
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
dart compile js "$dir/web_main.dart" -o "$dir/web/main.dart.js"
echo "Serving http://localhost:8080 -- open it and click Record (Ctrl-C to stop)."
cd "$dir/web"
# Loopback only: the microphone needs a secure context, which a LAN address
# is not, so there is nothing to gain from exposing the page further.
exec python3 -m http.server 8080 --bind 127.0.0.1
