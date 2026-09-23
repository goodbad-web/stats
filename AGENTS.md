# MyStats Agent Guide

This repository is a macOS Swift / SwiftUI app. Keep changes small, safe, and buildable.

## Working rules

- Read `TASK.md`, `BUG.md`, and `SKILLS.md` before editing when they exist.
- Prefer the existing architecture, naming, and data flow.
- Do not touch unrelated files, generated artifacts, or `scratch/` unless the task needs them.
- Avoid speculative refactors. Fix the root cause with the smallest coherent change.
- Use `apply_patch` for file edits.
- Never use destructive git commands unless explicitly requested.

## Investigation

- Check callers, callees, state ownership, and UI update paths before changing behavior.
- Confirm impact on view identity, state lifetime, and rebuild propagation when editing SwiftUI.
- If the issue is unclear, narrow the cause first instead of guessing.

## Build and verify

- Main local build:
  `xcodebuild -project Stats.xcodeproj -scheme Stats build`
- Distribution workflow:
  `make build`
- If the change is UI-related, verify the affected screen and accessibility behavior.
- If the change is bug-related, confirm the original failure path is fixed and no nearby behavior regressed.

## Repo notes

- App target: `Stats`
- Project file: `Stats.xcodeproj`
- Main app code: `Stats/`
- Shared utilities: `Kit/`
- SMC support: `SMC/`
- Widgets: `Widgets/`
- Tests: `Tests/`

## Output style

- Reply in Japanese, concise.
- State summary first, then plan, then code changes, then verification.
- Mention risks only when there are real caveats.

