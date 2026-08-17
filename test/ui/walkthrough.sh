#!/usr/bin/env bash
# Automated screenshot walkthrough of GhosttyPtyxis.
#
# Captures the main window and every page of the preferences window
# under Xvfb into PNG files, for visual review and CI artifacts
# (like the walkthroughs in other tuna-os projects).
#
# Usage: test/ui/walkthrough.sh [binary] [output-dir]
# Requires: xvfb-run/Xvfb, dbus-run-session, imagemagick (import)
set -u

BIN="${1:-zig-out/bin/ghostty}"
OUT="${2:-test/ui/screenshots}"
DISPLAY_NUM="${WALKTHROUGH_DISPLAY:-:97}"
SETTLE_SECS="${WALKTHROUGH_SETTLE_SECS:-6}"
GEOMETRY=1440x900x24

fail() { echo "WALKTHROUGH FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "binary not found: $BIN"
command -v import >/dev/null || fail "imagemagick 'import' missing"
command -v Xvfb >/dev/null || fail "Xvfb missing"

mkdir -p "$OUT"

# Isolated config: seed values that should be visible in the shots
# (opacity slider at 0.9, hollow-block cursor, a custom keybinding).
export XDG_CONFIG_HOME="$(mktemp -d)"
export XDG_DATA_HOME="$XDG_CONFIG_HOME/data"
export XDG_STATE_HOME="$XDG_CONFIG_HOME/state"
export XDG_CACHE_HOME="$XDG_CONFIG_HOME/cache"
mkdir -p "$XDG_CONFIG_HOME/ghostty"
cat > "$XDG_CONFIG_HOME/ghostty/config.ghostty" <<EOF
background-opacity = 0.9
cursor-style = block_hollow
keybind = ctrl+t=new_tab
EOF

Xvfb "$DISPLAY_NUM" -screen 0 "$GEOMETRY" -nolisten tcp &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null; rm -rf "$XDG_CONFIG_HOME"' EXIT
sleep 1
export DISPLAY="$DISPLAY_NUM"

shoot() { # name window-title-pattern [env for the app run]
    local name="$1" title="$2"; shift 2
    dbus-run-session -- env "$@" "$BIN" --gtk-single-instance=false &
    local app=$!
    sleep "$SETTLE_SECS"
    kill -0 "$app" 2>/dev/null || fail "$name: app crashed before capture"
    # Bring the window we're documenting fully on-screen and on top;
    # without this the preferences window can sit behind the terminal
    # or hang off the bottom of the virtual screen.
    if command -v xdotool >/dev/null && [ -n "$title" ]; then
        local wid
        wid=$(xdotool search --name "$title" | head -1 || true)
        if [ -n "$wid" ]; then
            xdotool windowmove "$wid" 40 40 windowraise "$wid" 2>/dev/null || true
            sleep 1
        fi
    fi
    import -display "$DISPLAY_NUM" -window root "$OUT/$name.png" \
        || fail "$name: capture failed"
    kill "$app" 2>/dev/null
    for _ in $(seq 1 10); do kill -0 "$app" 2>/dev/null || break; sleep 1; done
    kill -9 "$app" 2>/dev/null || true
    echo "captured $OUT/$name.png"
}

shoot 01-main-window "" GHOSTTY_PTYXIS_WALKTHROUGH=1
shoot 02-prefs-appearance Preferences GHOSTTY_PTYXIS_TEST_PREFS=appearance
shoot 03-prefs-behavior Preferences GHOSTTY_PTYXIS_TEST_PREFS=behavior
shoot 04-prefs-shortcuts Preferences GHOSTTY_PTYXIS_TEST_PREFS=shortcuts
shoot 05-prefs-profiles Preferences GHOSTTY_PTYXIS_TEST_PREFS=profiles

# Sanity: every capture must be non-trivial (a blank/failed capture is
# tiny). 10KB threshold is far below any real 1440x900 window shot.
for f in "$OUT"/*.png; do
    size=$(stat -c%s "$f")
    [ "$size" -ge 10240 ] || fail "$f is only ${size}B — likely blank"
done

echo "WALKTHROUGH PASS: $(ls "$OUT" | wc -l) screenshots in $OUT"
