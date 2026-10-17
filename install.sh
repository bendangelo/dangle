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
# Another dangle earlier on PATH (mise, an old copy) would still be the one that runs.
found=$(command -v dangle 2>/dev/null || true)
if [ -n "$found" ] && [ "$found" != "$bin/dangle" ]; then
  echo "warning: \`dangle\` runs $found ($("$found" --version 2>/dev/null || echo "unknown version")), not $bin/dangle"
  case $found in
    *mise*) echo "  mise installed that one: mise use -g github:bendangelo/dangle@latest, or mise uninstall it" ;;
    *) echo "  remove it, or put $bin ahead of it on your PATH" ;;
  esac
fi
