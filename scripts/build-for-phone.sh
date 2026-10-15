#!/bin/sh
# Builds a development-signed The Hermes app for the phones in your provisioning
# profile and writes an over-the-air install page for it:
#
#   scripts/build-for-phone.sh <out-dir> <https-base-url>
#
# Serve <out-dir>/site at that URL over HTTPS with a trusted certificate, for
# example on your tailnet (HTTPS certificates enabled in the Tailscale admin):
#
#   (cd <out-dir>/site && python3 -m http.server 8765 --bind 127.0.0.1) &
#   tailscale serve 8765
#
# then open the URL in Safari on the phone and tap Install. Needs
# DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER in Config/Local.xcconfig.
set -eu
cd "$(dirname "$0")/.."
out=${1:?usage: $0 <out-dir> <https-base-url>}
base=${2:?usage: $0 <out-dir> <https-base-url>}
base=${base%/}
mkdir -p "$out"
out=$(cd "$out" && pwd)

commit=$(git rev-parse --short HEAD)
git diff --quiet HEAD -- || commit="$commit+changes"
team=$(sed -n 's/^DEVELOPMENT_TEAM = //p' Config/Local.xcconfig)

rm -rf "$out/Flotilla.xcarchive" "$out/site"
xcodebuild archive -project Flotilla.xcodeproj -scheme Flotilla -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Flotilla.xcarchive" \
  -allowProvisioningUpdates FLOTILLA_COMMIT="$commit" -quiet

cat > "$out/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>debugging</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>automatic</string>
<key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Flotilla.xcarchive" -exportOptionsPlist "$out/export.plist" \
  -exportPath "$out/site" -allowProvisioningUpdates -quiet
rm -f "$out/site/DistributionSummary.plist" "$out/site/ExportOptions.plist" "$out/site/Packaging.log"

info="$out/Flotilla.xcarchive/Products/Applications/Flotilla.app/Info.plist"
bundle=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$info")
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$info")
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$info")

cat > "$out/site/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$base/Flotilla.ipa</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>$bundle</string><key>bundle-version</key><string>$version</string><key>kind</key><string>software</string><key>title</key><string>The Hermes</string></dict>
</dict></array></dict></plist>
PLIST
cat > "$out/site/index.html" <<HTML
<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Install The Hermes</title>
<body style="font:17px -apple-system;padding:40px 20px;text-align:center">
<h2>The Hermes $version ($build)</h2><p style="color:#888">$commit</p>
<p><a style="display:inline-block;padding:14px 28px;background:#0a84ff;color:#fff;border-radius:12px;text-decoration:none" href="itms-services://?action=download-manifest&amp;url=$base/manifest.plist">Install</a></p></body>
HTML
echo "The Hermes $version ($build) $commit -> $out/site"
