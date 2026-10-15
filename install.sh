#!/bin/sh
# Installs dangle into ~/.local/bin (or $DANGLE_BIN).
#   curl -fsSL https://raw.githubusercontent.com/bendangelo/dangle/main/install.sh | sh
set -eu
bin=${DANGLE_BIN:-$HOME/.local/bin}
ref=${DANGLE_REF:-main}
mkdir -p "$bin"
curl -fsSL "https://raw.githubusercontent.com/bendangelo/dangle/$ref/bin/dangle" -o "$bin/dangle.tmp"
chmod +x "$bin/dangle.tmp"
mv "$bin/dangle.tmp" "$bin/dangle"
echo "installed $("$bin/dangle" --version) to $bin/dangle"
case ":$PATH:" in *":$bin:"*) ;; *) echo "add $bin to your PATH" ;; esac
