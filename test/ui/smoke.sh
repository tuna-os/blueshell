#!/usr/bin/env bash
# GhosttyPtyxis headless UI smoke test.
#
# Verifies the built binary against a throwaway config in a virtual
# display: it must start, initialize GTK (which instantiates the
# blueprint templates, catching gresource/template-child mismatches at
# runtime), stay alive for a few seconds, and exit cleanly on SIGTERM.
#
# Usage: test/ui/smoke.sh [path-to-ghostty-binary]
# Requires: xvfb-run, dbus-run-session (apt: xvfb dbus dbus-x11)
set -u

BIN="${1:-zig-out/bin/ghostty}"
HOLD_SECS="${SMOKE_HOLD_SECS:-8}"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not found or not executable: $BIN"

# Isolated config so the smoke test never touches real user state and
# exercises the config-file load path the preferences UI writes to.
export XDG_CONFIG_HOME="$(mktemp -d)"
export XDG_DATA_HOME="$XDG_CONFIG_HOME/data"
export XDG_STATE_HOME="$XDG_CONFIG_HOME/state"
export XDG_CACHE_HOME="$XDG_CONFIG_HOME/cache"
trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT
mkdir -p "$XDG_CONFIG_HOME/ghostty"
cat > "$XDG_CONFIG_HOME/ghostty/config.ghostty" <<EOF
# written by test/ui/smoke.sh — mirrors keys the preferences UI writes
background-opacity = 0.9
cursor-style = block_hollow
bell-features = audio,no-attention,title
scroll-to-bottom = no-keystroke,output
keybind = ctrl+t=new_tab
window-save-state = never
EOF

# 1. Config must validate with the shipped parser.
"$BIN" +validate-config --config-file="$XDG_CONFIG_HOME/ghostty/config.ghostty" \
  || fail "+validate-config rejected the smoke config"

# 2. +version must work without a display.
"$BIN" +version >/dev/null || fail "+version failed"

# 3. Launch under Xvfb + private D-Bus; the app must still be running
#    after HOLD_SECS (no startup crash) and shut down on SIGTERM.
log="$(mktemp)"
xvfb-run -a dbus-run-session -- "$BIN" --gtk-single-instance=false >"$log" 2>&1 &
runner=$!

sleep "$HOLD_SECS"
if ! kill -0 "$runner" 2>/dev/null; then
    wait "$runner"; code=$?
    echo "--- app log ---"; cat "$log"
    fail "app exited within ${HOLD_SECS}s (exit $code) — startup crash"
fi

kill "$runner" 2>/dev/null
# xvfb-run forwards TERM; give the app a moment to unwind.
for _ in $(seq 1 10); do
    kill -0 "$runner" 2>/dev/null || break
    sleep 1
done
kill -9 "$runner" 2>/dev/null || true
rm -f "$log"

echo "SMOKE PASS: started, survived ${HOLD_SECS}s, terminated cleanly"
