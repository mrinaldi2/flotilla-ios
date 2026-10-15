#!/bin/sh
# Runs the XCUITest suite (UITests) against a fresh demo world, no live daemon:
#
#   scripts/ui-tests.sh [xcodebuild args…]
#
# for example `scripts/ui-tests.sh -only-testing:UITests/SmokeTests`. It starts
# demo/make_demo.py with a linked peer in its own folder and ports, erases the
# simulator, runs the tests there, and stops the demo. Answers and unlinks only
# touch that demo.
#
#   SIMULATOR       name of an existing simulator that is yours alone (default
#                   Gravity-iOSQA); it is addressed by UDID and ERASED before each run
#   SCREENSHOT_DIR  where the tests also write their screenshots as PNG
#   DEMO_DAEMON     the daemon binary the demo runs (default ~/.flotilla/bin/flotillad,
#                   else ~/.thehermes/bin/hermesd from before the rename, when present;
#                   else make_demo.py looks for one)
#   DEMO_OUT        the demo's folder, wiped on each run (default build/ui-tests-demo)
#   LONG_CHAT       1: give iOS Dev's demo transcript LONG_CHAT_TURNS (default 120) earlier
#                   turns (demo/long_chat.py) for the long-chat tests (QA010LongChatTests, H228Tests)
#   DEMO_PORT, DEMO_LENS_PORT, DEMO_PEER_PORT, DEMO_CONTROL_PORT
#                   the demo's ports (default 41300, 41301, 41302, 41303); on the
#                   control port tests ask the demo for the state they need
#
# On a shared computer it touches only what it started: the demo's processes,
# by the pids make_demo.py records, and the one simulator, which it boots for
# the run and shuts down afterwards.
#
# Result bundles (screenshots, contrast figures): build/ui-tests.xcresult, plus
# build/ui-tests-fresh.xcresult (notifications not yet asked for) and
# build/ui-tests-dark.xcresult (dark mode).
set -eu
cd "$(dirname "$0")/.."
simulator=${SIMULATOR:-Gravity-iOSQA}
out=${DEMO_OUT:-$PWD/build/ui-tests-demo}
port=${DEMO_PORT:-41300}
lens_port=${DEMO_LENS_PORT:-41301}
peer_port=${DEMO_PEER_PORT:-41302}
control_port=${DEMO_CONTROL_PORT:-41303}
log="$out.log"
daemon_bin=${DEMO_DAEMON:-}
for candidate in "$HOME/.flotilla/bin/flotillad" "$HOME/.thehermes/bin/hermesd"; do
    if [ -z "$daemon_bin" ] && [ -x "$candidate" ]; then daemon_bin=$candidate; fi
done
project=$(dirname "$(ls -d *.xcodeproj/project.pbxproj | head -1)")

device=$(xcrun simctl list devices available | grep -F "    $simulator (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$device" ]; then
    echo "No simulator named $simulator. Create one that is yours alone, for example:" >&2
    echo "  xcrun simctl create '$simulator' com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro" >&2
    exit 1
fi

# NO_DEMO=1: tests that bring their own daemon (e.g. a scratch copy via SCRATCH_PORT,
# SCRATCH_TOKEN, SCRATCH_READONLY_TOKEN, SCRATCH_CONTROL_PORT) run without starting the demo world.
no_demo=${NO_DEMO:-}
for p in $( [ -z "$no_demo" ] && echo "$port $lens_port $peer_port $control_port" ); do
    if nc -z 127.0.0.1 "$p" 2>/dev/null; then
        echo "Port $p is in use (another demo?); set DEMO_PORT, DEMO_LENS_PORT, DEMO_PEER_PORT or DEMO_CONTROL_PORT" >&2
        exit 1
    fi
done
mkdir -p "$(dirname "$out")"
demo=
# The demo, then each process it recorded starting (daemons, Lens): only those.
stop_demo() {
    [ -n "$demo" ] && kill "$demo" 2>/dev/null || true
    [ -n "$demo" ] && wait "$demo" 2>/dev/null || true
    if [ -f "$out/pids" ]; then
        while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$out/pids"
        rm -f "$out/pids"
    fi
}
# The simulator is booted only for the run: shut down whatever happens.
finish() {
    stop_demo
    xcrun simctl shutdown "$device" 2>/dev/null || true
}
trap finish EXIT INT TERM
# The demo first, on a quiet machine; a second try when its daemon trips while starting.
for attempt in $( [ -z "$no_demo" ] && echo "1 2" ); do
    python3 -u demo/make_demo.py --serve --out "$out" --port "$port" --lens-port "$lens_port" \
        --peer-port "$peer_port" --control-port "$control_port" \
        ${daemon_bin:+--gravityd "$daemon_bin"} >"$log" 2>&1 &
    demo=$!
    tries=0
    until grep -q '^Serving' "$log"; do
        tries=$((tries + 1))
        if [ $tries -gt 180 ] || ! kill -0 "$demo" 2>/dev/null; then break; fi
        sleep 1
    done
    grep -q '^Serving' "$log" && break
    stop_demo
    if [ $attempt = 2 ]; then
        echo "The demo world did not start; see $log" >&2
        exit 1
    fi
done
[ -z "$no_demo" ] && sleep 3 # the demo's permission prompts reach the daemon just after it serves

fresh_simulator() {
    xcrun simctl shutdown "$device" 2>/dev/null || true
    xcrun simctl erase "$device"
    xcrun simctl boot "$device"
    # Less background load on a shared Mac: Siri and its suggestions off.
    xcrun simctl spawn "$device" defaults write com.apple.assistant.support "Assistant Enabled" -bool false 2>/dev/null || true
    xcrun simctl spawn "$device" defaults write com.apple.suggestions SuggestionsAppLibraryEnabled -bool false 2>/dev/null || true
}

# Ids the routing tests open: the designer's question and iOS Dev.
ids=" "
[ -z "$no_demo" ] && ids=$(python3 - "$out" "$port" <<'EOF'
import os, sys
sys.path.insert(0, "demo")
from make_demo import Socket
out, port = sys.argv[1], int(sys.argv[2])
ws = Socket(port)
ws.request("hello", protocol_version=2, token=open(os.path.join(out, "gravity", "secrets", "client.token")).read().strip(),
           client="ui-tests")
decision = next(d for d in ws.request("list_decisions")["decisions"] if d["title"].startswith("Which accent colour"))
bot = next(b for b in ws.request("list_bots")["bots"] if b["name"] == "iOS Dev" and not b.get("peer"))
print(decision["id"], bot["id"])
EOF
)

# The demo's Aurora Notes project, for tests that name it by id (QA-013's offer stub).
project_id=
[ -z "$no_demo" ] && project_id=$(python3 - "$out" "$port" <<'EOF'
import os, sys
sys.path.insert(0, "demo")
from make_demo import Socket
out, port = sys.argv[1], int(sys.argv[2])
ws = Socket(port)
ws.request("hello", protocol_version=2, token=open(os.path.join(out, "gravity", "secrets", "client.token")).read().strip(),
           client="ui-tests")
print(next(p["id"] for p in ws.request("list_projects")["projects"] if p["name"] == "Aurora Notes"))
EOF
)

# A long chat for the long-chat tests: earlier turns in iOS Dev's demo transcript.
if [ -n "${LONG_CHAT:-}" ] && [ -z "$no_demo" ]; then
    python3 demo/long_chat.py "$out" "Starting on the conflict banner" "${LONG_CHAT_TURNS:-120}"
fi

# A freshly erased simulator ignores the tests' own appearance switch, hence the dark pass.
dark="-only-testing:UITests/H003Tests/testPermissionCardContrastDark -only-testing:UITests/H003Tests/testDecisionDetailContrastDark"
run_tests() { # <result bundle> <xcodebuild args…>
    bundle=$1; shift
    rm -rf "$bundle"
    TEST_RUNNER_GRAV_TOKEN=$(cat "$out/gravity/secrets/client.token" 2>/dev/null) \
    TEST_RUNNER_SCRATCH_PORT=${SCRATCH_PORT:-} TEST_RUNNER_SCRATCH_TOKEN=${SCRATCH_TOKEN:-} \
    TEST_RUNNER_SCRATCH_READONLY_TOKEN=${SCRATCH_READONLY_TOKEN:-} TEST_RUNNER_SCRATCH_CONTROL_PORT=${SCRATCH_CONTROL_PORT:-} TEST_RUNNER_SCRATCH_PROXY_PORT=${SCRATCH_PROXY_PORT:-} \
    TEST_RUNNER_GRAV_PORT=$port TEST_RUNNER_LENS_PORT=$lens_port \
    TEST_RUNNER_DEMO_DECISION_ID=${ids% *} TEST_RUNNER_DEMO_BOT_ID=${ids#* } \
    TEST_RUNNER_DEMO_CONTROL_PORT=$control_port TEST_RUNNER_LONG_CHAT=${LONG_CHAT:-} TEST_RUNNER_DEMO_OUT="$out" TEST_RUNNER_DEMO_PROJECT_ID=$project_id TEST_RUNNER_DEMO_SKIPPED="$(cat "$out/skipped" 2>/dev/null | tr '\n' ' ')" TEST_RUNNER_FIXTURES=$PWD/contract/fixtures TEST_RUNNER_SCREENSHOT_DIR=${SCREENSHOT_DIR:-} \
    xcodebuild -project "$project" -scheme UITests -destination "id=$device" \
        -derivedDataPath build/ui-tests -resultBundlePath "$bundle" test "$@"
}
# Apps on the simulator that this suite did not install: something else used it
# mid-run, and the results can't be trusted.
foreign_apps() {
    ours=$(for plist in build/ui-tests/Build/Products/Debug-iphonesimulator/*.app/Info.plist; do
        plutil -extract CFBundleIdentifier raw "$plist"; done 2>/dev/null)
    xcrun simctl listapps "$device" | plutil -convert json -o - - | python3 -c '
import json, sys
ours = set(sys.argv[1].split())
apps = json.load(sys.stdin)
print(" ".join(k for k, v in apps.items() if v.get("ApplicationType") == "User" and k not in ours))' "$ours"
}
check_simulator() {
    others=$(foreign_apps)
    if [ -n "$others" ]; then
        echo "STOPPED: something else installed onto $simulator ($device) during the run: $others" >&2
        exit 2
    fi
}
# Passes: notifications never asked for (on a just-erased simulator), then everything
# else in light, then the *Dark tests with the simulator in dark.
fresh="UITests/NotificationSettingsTests/testNotSetUpThenOff"
status=0
if [ $# -eq 0 ] || echo "$*" | grep -q NotificationSettings; then
    fresh_simulator
    xcrun simctl ui "$device" appearance light
    run_tests build/ui-tests-fresh.xcresult -only-testing:$fresh || status=1
    check_simulator
fi
fresh_simulator
xcrun simctl ui "$device" appearance light
run_tests build/ui-tests.xcresult -skip-testing:$fresh \
    -skip-testing:UITests/H003Tests/testPermissionCardContrastDark \
    -skip-testing:UITests/H003Tests/testDecisionDetailContrastDark "$@" || status=1
check_simulator
if [ $# -eq 0 ] || echo "$*" | grep -q Dark; then
    xcrun simctl ui "$device" appearance dark
    # shellcheck disable=SC2086
    run_tests build/ui-tests-dark.xcresult $dark || status=1
    xcrun simctl ui "$device" appearance light
    check_simulator
fi
exit $status
