#!/bin/bash
# Paper Reader - macOS launcher. Double-click in Finder, or run from Terminal.
cd "$(dirname "$0")" || exit 1

# Finder-launched scripts start with a bare PATH; add the usual install dirs.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

PY=$(command -v python3 || echo /usr/bin/python3)
"$PY" server.py "$@"

echo
echo "Server stopped."
read -n 1 -s -r -p "Press any key to close..."
echo
