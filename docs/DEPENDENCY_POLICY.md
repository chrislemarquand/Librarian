# Dependency Policy

## Current Mode: Local-Only SharedUI

- `SharedUI` must be referenced as a local path dependency: `.package(path: "../SharedUI")`.
- Do not reference `https://github.com/chrislemarquand/SharedUI.git` in normal development.
- Do not run remote/version bump workflow unless explicitly requested.

## Local Lockstep Workflow

1. Verify local dependency wiring:

```bash
./scripts/deps/verify_shared_ui_pin.sh
```

2. Sync local package resolution:

```bash
./scripts/deps/bump_sharedui.sh
```

3. Run a quick lockstep build check:

```bash
./scripts/deps/sync_sharedui_local.sh
```

## Release Mode (Only When Explicitly Requested)

- Switching back to a tagged remote `SharedUI` dependency is a release action.
- Do not perform that switch unless explicitly requested.
