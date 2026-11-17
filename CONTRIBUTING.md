# Contributing to Brim

Thanks for helping. Brim is made by one person in their own time, so small and focused helps most.

## What's welcome

- **Bug fixes.** Open an issue first (or find one), say what you'll change, then send a pull request.
- **Ideas** go on the [feedback board](https://brim-notch.userjot.com), where everyone can vote. Brim stays small on
  purpose: one thing at a time at the top of the screen. Many good ideas will be a polite no.
- **Security problems** never go in a public issue: see [SECURITY.md](SECURITY.md).

## Before you send a pull request

1. Build and test: `scripts/check.sh` must end with "All checks passed".
2. Keep it to one change, and describe what you saw before and after.
3. Brim talks to the internet only for the features listed in the README. A change that adds anything else won't be
   merged.
4. No code copied from GPL projects: Brim is MIT.

## How the code is laid out

- `Packages/BrimKit/Sources/BrimCore`: pure logic, no UI. Most tests live here.
- `Packages/BrimKit/Sources/BrimSystem`: everything that talks to macOS.
- `Packages/BrimKit/Sources/BrimFeatures`: SwiftUI views and stores. Never imports `BrimSystem`.
- `Brim/`: the app itself, which wires the three together.

By sending a pull request you agree that your change is shared under the [MIT License](LICENSE).
