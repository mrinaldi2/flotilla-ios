# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting set up

1. Install Flotilla on the Mac (the demo uses its daemon, `flotillad`) and Xcode 16 or later.
2. Start the demo world, which needs no bots of your own and spends no tokens:

   ```bash
   python3 demo/make_demo.py --serve
   ```

3. Open `Flotilla.xcodeproj`, edit the **Flotilla** scheme (Run → Arguments), enable the demo
   launch argument and replace `PASTE_DEMO_TOKEN` with the token the demo printed. Run it on a
   simulator. These arguments are read only in Debug builds.

No signing is needed for the simulator. For a device, put your team in `Config/Local.xcconfig`
(see the README).

## Before you open a pull request

- `python3 -m unittest discover tests` passes (the companion must keep working on Python 3.9).
- The app builds: `xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- UI tests pass: `scripts/ui-tests.sh` (starts its own demo world, runs the `UITests` scheme on the
  iPhone 18 Pro simulator; `SIMULATOR=…` for another, extra args go to xcodebuild).
- UI changes come with a before/after screenshot from the demo world, never from real bots.
- No personal data in commits: tokens, Tailscale addresses, team IDs, real bot logs or screenshots.

## Versions

The version lives in `Config/Version.xcconfig` and shows in Settings → About. Bump it with
`scripts/bump-version.sh`: with no argument for a new build of the same version (every build that
goes to a phone gets its own build number), or with `patch`, `minor` or `major` for a release.
`scripts/build-for-phone.sh` builds a development-signed install page for your own iPhone and
stamps the commit it was built from into About.

## Where things are

- `Flotilla/Core/DaemonClient.swift`: the WebSocket client for the daemon's
  [control-plane protocol](https://github.com/ahilles107/gravity/blob/main/docs/protocol.md).
- `Flotilla/Core/Lens.swift` and `companion/gravity_lens.py`: the activity, image and report side.
- `demo/make_demo.py`: add to the demo world when a feature needs data to show.

Style: follow the code around you. Swift uses SwiftUI and Observation. Keep the companion to the
standard library.
