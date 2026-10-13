#!/bin/sh
# Proves the Debug-only test hooks are not in a Release build (H-230): builds
# TheHermes for the simulator in Release and looks for their launch-argument
# names in every file of the app. Exits 1 if any is there.
#
#   scripts/check-debug-hooks.sh
set -eu
cd "$(dirname "$0")/.."
out=build/check-debug-hooks
mkdir -p build
xcodebuild -project TheHermes.xcodeproj -scheme TheHermes -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$out" \
    CODE_SIGNING_ALLOWED=NO build >"$out.log" 2>&1 || { echo "Release build failed; see $out.log" >&2; exit 1; }
app=$(find "$out/Build/Products/Release-iphonesimulator" -name 'TheHermes.app' -type d | head -1)
[ -n "$app" ] || { echo "No TheHermes.app in $out" >&2; exit 1; }
status=0
# Every file in the bundle: a Debug build keeps its code in TheHermes.debug.dylib.
for hook in installStub installOfferStub releaseStub ownerAuthStub homeFixture pairLink attachFixture; do
    if find "$app" -type f -exec strings -a {} + 2>/dev/null | grep -q "$hook"; then
        echo "FOUND in Release: $hook" >&2
        status=1
    else
        echo "absent in Release: $hook"
    fi
done
exit $status
