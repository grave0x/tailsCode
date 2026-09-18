#!/usr/bin/env bash
# Build the Linux client in release and install what was just built, so the `tailscode` on PATH is
# the code that was just written rather than whatever was there last week.
#
#   scripts/install-linuxapp.sh            # build, install, restart if it was running
#   scripts/install-linuxapp.sh --no-restart
#   scripts/install-linuxapp.sh --verbose  # narrate every stage in detail (stderr)
set -euo pipefail

cd "$(dirname "$0")/.."
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

RESTART=yes
VERBOSE=no
for arg in "$@"; do
    case "$arg" in
        --no-restart) RESTART=no ;;
        --verbose | -v) VERBOSE=yes ;;
        *) echo "install-linuxapp.sh: unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Every stage narrates itself under --verbose. Narration goes to stderr so stdout keeps carrying
# only the two contract lines a caller reads: "installed <version>" and "restarted (pid N)".
say() { [ "$VERBOSE" = yes ] && printf '%s\n' "$*" >&2 || true; }

say "config: bin=$BIN_DIR apps=$APPS_DIR restart=$RESTART"

cd TailscodeLinux
# No `|| true` here: with pipefail a failed build must abort the install, or a stale binary from
# the last good build gets installed and "installed/restarted" lies about what is running.
say "building release binary (TailscodeLinux)…"
BUILD_START=$SECONDS
say "toolchain: $(swift --version 2>/dev/null | head -n 1)"
say "command: swift build -c release --manifest-cache none (in $PWD)"
say "expected binary: $PWD/.build/release/tailscode"
if [ "$VERBOSE" = yes ]; then
    # Stream the whole build unfiltered so a long release build narrates its own progress — every
    # compile line, the link, "Build complete!". It is routed to stderr so stdout keeps carrying
    # only the two contract lines a caller reads. No pipe here: the build's own exit status is what
    # set -e sees, so a failed build still aborts the install.
    swift build -c release --manifest-cache none 1>&2
else
    swift build -c release --manifest-cache none 2>&1 | grep -E "error:|Build complete"
fi
BUILT=$PWD/.build/release/tailscode
[ -x "$BUILT" ] || { echo "no binary at $BUILT" >&2; exit 1; }
say "build finished: $BUILT ($(stat -c %s "$BUILT") bytes, $((SECONDS-BUILD_START))s)"

# The app is single-instance on the session bus, so launching it while the old one is still alive
# remote-activates the process already running — the script then finds a tailscode, says
# "restarted", and leaves the person on the binary they just replaced. So the old process is waited
# out by pid before anything is installed.
OLD_PIDS=$(pgrep -f "$BIN_DIR/tailscode$" || true)
WAS_RUNNING=no
[ -n "$OLD_PIDS" ] && WAS_RUNNING=yes
if [ "$WAS_RUNNING" = yes ]; then say "old instance running: pid(s) $OLD_PIDS"; else say "no running instance to stop"; fi
for pid in $OLD_PIDS; do
    say "sending SIGTERM to pid $pid"
    kill "$pid" 2>/dev/null || true
done
for _ in $(seq 1 50); do
    still=""
    for pid in $OLD_PIDS; do kill -0 "$pid" 2>/dev/null && still="yes"; done
    [ -z "$still" ] && break
    sleep 0.2
done
STILL_RUNNING=""
for pid in $OLD_PIDS; do kill -0 "$pid" 2>/dev/null && STILL_RUNNING=yes; done
if [ -n "$STILL_RUNNING" ]; then
    say "old instance still alive after the 10s grace period; sending SIGKILL to $OLD_PIDS"
    for pid in $OLD_PIDS; do kill -9 "$pid" 2>/dev/null || true; done
else
    say "old instance exited: pid(s) $OLD_PIDS"
fi

say "installing into $BIN_DIR/tailscode"
mkdir -p "$BIN_DIR" "$APPS_DIR"
install -m 0755 "$BUILT" "$BIN_DIR/tailscode"
say "installed $BIN_DIR/tailscode ($(stat -c %s "$BIN_DIR/tailscode") bytes, mode $(stat -c %a "$BIN_DIR/tailscode"))"
[ "$(stat -c %s "$BIN_DIR/tailscode")" = "$(stat -c %s "$BUILT")" ] || { echo "installed binary size mismatch" >&2; exit 1; }

# The binary is installed away from the checkout that built it, so the running program has no way to
# walk back to its source. This is the only link, and the app believes it only after checking it
# against the binary actually running — hence the size and mtime, read after the install.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tailscode"
SRC=$(cd .. && pwd)
mkdir -p "$STATE_DIR"
BIN="$BIN_DIR/tailscode"
DIRTY=false
if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then DIRTY=true; fi
GIT_DESCRIBE=$(git -C "$SRC" describe --tags --always --dirty 2>/dev/null)
GIT_COMMIT=$(git -C "$SRC" rev-parse HEAD 2>/dev/null)
GIT_BRANCH=$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)
GIT_UPSTREAM=$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
MARKETING=$("$BIN" --version 2>/dev/null | awk '{print $NF}')
say "source: $GIT_DESCRIBE (${GIT_COMMIT:0:12}), branch ${GIT_BRANCH:-unknown}, upstream ${GIT_UPSTREAM:-none}, dirty=$DIRTY"
say "marketing version: ${MARKETING:-unknown}"
printf '{"schema":1,"component":"tailscode-linux","installedAt":"%s","installedBy":"scripts/install-linuxapp.sh","flavour":"release","binary":{"path":"%s","size":%s,"modifiedAt":"%s"},"source":{"path":"%s","describe":"%s","commit":"%s","branch":"%s","upstream":"%s","dirty":%s},"marketingVersion":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$BIN" \
    "$(stat -c %s "$BIN")" \
    "$(date -u -r "$BIN" +%Y-%m-%dT%H:%M:%SZ)" \
    "$SRC" \
    "$GIT_DESCRIBE" \
    "$GIT_COMMIT" \
    "$GIT_BRANCH" \
    "$GIT_UPSTREAM" \
    "$DIRTY" \
    "$MARKETING" \
    > "$STATE_DIR/install.json"
say "state written: $STATE_DIR/install.json"

# The desktop entry and icons are owned by the app itself (DesktopIntegration writes the
# GApplication-id-named files on every launch — the name GNotification and the Wayland shell
# both match against). The script only clears the misnamed entry earlier versions wrote.
if [ -e "$APPS_DIR/tailscode.desktop" ]; then
    rm -f "$APPS_DIR/tailscode.desktop"
    say "removed stale desktop entry $APPS_DIR/tailscode.desktop"
else
    say "no stale desktop entry to remove ($APPS_DIR/tailscode.desktop)"
fi
update-desktop-database "$APPS_DIR" 2>/dev/null || true
say "desktop database refreshed: $APPS_DIR"

echo "installed $("$BIN_DIR/tailscode" --version 2>/dev/null || echo "$BIN_DIR/tailscode")"

# A restart has to look like a launch. The desktop's own portal only grants a key from the whole
# session to an app it can name, and it names one by the systemd scope its .desktop entry started
# it in — an app resurrected with a bare `nohup` inherits the caller's cgroup instead, is refused an
# app id, and quietly loses its global chord until the next launcher click.
if [ "$RESTART" = yes ] && [ "$WAS_RUNNING" = yes ]; then
    say "restarting (the app was running before install)"
    # The display must be the person's, not the caller's: run from an agent or a cron-less shell
    # there is no DISPLAY here, and an app restarted without one starts headless — alive, polling,
    # but with no window. The process being replaced is the authoritative witness of where its
    # window lived, so its own environment is adopted when this one has nothing to offer.
    DISPLAY_ENV=""
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        say "caller has no DISPLAY/WAYLAND_DISPLAY; adopting the replaced instance's"
        for pid in $OLD_PIDS; do
            DISPLAY_ENV=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null |
                grep -E '^(DISPLAY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR)=' |
                sed 's/^/--setenv=/' | tr '\n' ' ' || true)
            [ -n "$DISPLAY_ENV" ] && break
        done
        if [ -n "$DISPLAY_ENV" ]; then say "adopted display env: $DISPLAY_ENV"; else say "could not read the old instance's environment; restarting without display env"; fi
    else
        say "inheriting caller's display: DISPLAY=${DISPLAY:-unset} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"
    fi
    if command -v systemd-run >/dev/null 2>&1; then
        say "restarting via systemd-run --user (scope app-io.github.guitaripod.Tailscode-$$)"
        systemd-run --user --scope --quiet \
            -u "app-io.github.guitaripod.Tailscode-$$" \
            $DISPLAY_ENV \
            "$BIN_DIR/tailscode" >/tmp/tailscode-linux-run.log 2>&1 &
    else
        say "systemd-run unavailable; restarting via nohup"
        nohup "$BIN_DIR/tailscode" >/tmp/tailscode-linux-run.log 2>&1 &
    fi
    say "run log: /tmp/tailscode-linux-run.log"
    say "waiting for the new instance to come up…"
    sleep 2
    NEW_PIDS=$(pgrep -f "$BIN_DIR/tailscode$" || true)
    say "new instance: pid(s) $NEW_PIDS"
    for pid in $NEW_PIDS; do
        case " $OLD_PIDS " in *" $pid "*) ;; *) echo "restarted (pid $pid)"; exit 0 ;; esac
    done
    echo "NOT restarted — the old process is still what is running" >&2
    exit 1
fi
