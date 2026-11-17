# Security

Brim runs on your Mac and keeps your data there: no accounts, no tracking, no analytics. It talks only to LRCLIB
(lyrics), Apple's public catalog (covers), Spotify (if you connect it) and GitHub (updates).

## Reporting a problem

Please don't open a public issue for a security problem. Use **Report a vulnerability** on this repository's
Security tab (GitHub's private reporting), with what you found, how to reproduce it, and the Brim version
(Settings → About). Or email trikeshswamy.dev@gmail.com. You'll get an answer within 7 days.

## How Brim protects you

- Spotify sign-in uses OAuth with PKCE and a random state, on 127.0.0.1 only, only while you sign in. No client
  secret exists in Brim. Tokens live in your Keychain.
- Updates are signed (EdDSA, Sparkle) and checked against the key built into Brim before they install.
- The app is signed with hardened runtime and asks only for what a feature needs, when you turn that feature on.

## Known limit

Brim is signed with its own certificate, not an Apple Developer ID, so macOS can't hold its bundled frameworks to
Apple's team check (`disable-library-validation`). That means malware already running on your Mac could load its own
code into a copy of Brim and use the permissions you gave Brim. It needs your Mac to be compromised first; nothing
from the internet can do it. This goes away when Brim is signed with a Developer ID.
