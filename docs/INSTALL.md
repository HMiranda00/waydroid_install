# Blip on Linux via Waydroid (ZorinOS 18 Priority)

This project installs Blip (Android version) on Ubuntu/Debian-based Linux, with focus on ZorinOS 18.
It uses Waydroid with GAPPS, provides a native launcher icon, keeps step-by-step logs, and supports clean removal.

## What this provides

- Waydroid installation and GAPPS init.
- Play Store flow to install Blip.
- Native launcher at `~/.local/share/applications/blip-waydroid.desktop`.
- Resume support with checkpoints in `state/install-state.json`.
- Two uninstall modes:
  - `scripts/uninstall.sh --user-only`
  - `scripts/uninstall.sh --full-purge`

## Prerequisites

- Ubuntu/Debian derivative (ZorinOS 18 preferred).
- `sudo` access.
- Graphical session available.
- Internet access.

## Install

```bash
chmod +x scripts/install.sh scripts/create-launcher.sh scripts/uninstall.sh
scripts/install.sh
```

If interrupted:

```bash
scripts/install.sh --resume
```

## During Play Store step

The installer opens Play Store in Waydroid. Install Blip and return to terminal.
The script tries to auto-detect package/activity and stores them in `state/install-state.json`.

## Outputs

- Step log: `docs/STEP_LOG.md`
- State: `state/install-state.json`
- Native launcher: `~/.local/share/applications/blip-waydroid.desktop`
- Runtime logs: `~/.local/state/blip-waydroid/`

## Launching Blip

Use the menu entry `Blip (Waydroid)` or run:

```bash
~/.local/bin/blip-waydroid-launch
```

This starts Waydroid session (if needed) and opens Blip directly.

## Uninstall

Remove user-level artifacts only:

```bash
scripts/uninstall.sh --user-only
```

Remove user artifacts plus Waydroid system installation:

```bash
scripts/uninstall.sh --full-purge
```

Each uninstall writes a report into `docs/STEP_LOG.md`.
