# Security

Flotilla for iPhone gives a phone control of a team of coding agents running on your Mac, so security
reports matter.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** (Security → Report a vulnerability) rather
than a public issue. Include what you found, how to reproduce it and what an attacker could do.

## Design notes

- The app and Gravity Lens are meant to be reachable only over loopback and a Tailscale tailnet,
  never the public internet.
- Every Lens request needs a Gravity device token with the `read` grant, verified by handshaking with
  the daemon. Revoking the device in Gravity revokes Lens access too. Verified tokens are cached for
  60 seconds.
- Lens is read-only. It serves bot logs, the artifacts folder, and only those image files that a
  bot's log or a report refers to. Report names are matched against the folder listing, so paths
  cannot escape it.
- The file browser is off by default. When enabled it needs the `control` grant, serves only the
  configured roots, resolves every path (symlinks included) before checking it, and refuses secret
  locations (`.ssh`, `.gnupg`, `.aws`, Keychains, `*.token`, `*.pem`, `*.key`, …) even inside a root.
- Screen control uses macOS Screen Sharing directly; Flotilla adds no server for it. The Mac
  password is stored in the Keychain with `WhenUnlockedThisDeviceOnly` and sent only to the Mac,
  inside Apple's Diffie-Hellman sign-in.
- The app stores the token in the Keychain with `AfterFirstUnlockThisDeviceOnly`.
- Vulnerabilities in Gravity itself belong to its authors: see
  [ahilles107/gravity](https://github.com/ahilles107/gravity/blob/main/SECURITY.md).
