# AirDrift

AirDrift is the macOS transmitter client for the mouse and keyboard sharing ecosystem. It monitors mouse positioning via a low-level global `CGEventTap` and locks/swallows inputs when pushing past the configured display edge, streaming coordinates and hardware events to the Android target.

## Setup & Running

### 1. Build Client
Build the Swift package executable:
```bash
swift build
```

### 2. Grant Accessibility Permissions
Before running, you must grant **Accessibility** permissions to your terminal app (Terminal or iTerm) in *System Settings > Privacy & Security > Accessibility*.

### 3. Run Client
Run the client, targeting the port-forwarded Android WebSocket server:
```bash
swift run AirDrift localhost
```

## Features
- Low-latency global event interception using CoreGraphics `CGEventTap`.
- Left-edge collision detection targeting side-by-side phone placements.
- Cooldown protection (500ms) on unlocking to prevent infinite event loop locking.
- Emergency unlock escape hatch (`Escape` key).
