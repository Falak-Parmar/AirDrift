# AirDrift

**AirDrift** is the macOS client for the [Drift](https://github.com/Falak-Parmar/Drift) universal control system. It intercepts your Mac's mouse, keyboard, and scroll wheel inputs and forwards them over a local ADB tunnel to an Android device running **DroidDrift**, enabling seamless pointer-crossing similar to Apple's Universal Control.

---

## Features

- 🖱️ **Seamless cursor crossing** — move your mouse to the left screen edge to instantly cross into your Android device
- ⌨️ **Full keyboard forwarding** — type on your Mac keyboard, text appears on Android in real-time
- 🖱️ **Scroll wheel support** — scrolling is forwarded with configurable speed multiplier
- 🔒 **Edge locking with configurable border width** — lock/unlock zone is tunable
- ⌘ **Android system key shortcuts** — `Cmd+H` (Home), `Cmd+B` (Back), `Cmd+R` (Recents), `Cmd+N` (Notifications)
- `Esc` to unlock the cursor and return control to macOS
- 🍎 **Native macOS Settings window** — Stats-app-style preferences panel with sliders for scroll speed, border width, and re-entry cooldown
- 🌓 **System light/dark theme** — fully adaptive to your macOS appearance settings
- 🔍 **Spotlight & Launchpad support** — launch from Spotlight; window opens centered on your screen
- `Cmd+Q` to quit cleanly

---

## Architecture

```
macOS (AirDrift)
└── CGEventTap (global mouse/keyboard/scroll hook)
    └── WebSocket Client (ws://127.0.0.1:8080)
        └── ADB Forward (adb forward tcp:8080 tcp:8080)
            └── DroidDrift (Android)
```

1. **AirDrift** hooks all system input events via a `CGEventTap`.
2. Events are serialized as JSON and sent over a WebSocket to `localhost:8080`.
3. ADB forwards that port over USB/wireless to the phone.
4. **DroidDrift**'s WebSocket server receives events and feeds them to the privileged ADB daemon or accessibility service for injection.

---

## Requirements

- macOS 13+
- Swift 6.3+
- Android device running **DroidDrift**
- `adb` installed (`brew install android-platform-tools`)
- Accessibility permission granted in **System Settings → Privacy & Security → Accessibility**

---

## Building & Running

```bash
# Clone including submodules
git clone --recurse-submodules https://github.com/Falak-Parmar/Drift
cd Drift/AirDrift

# Build and install to /Applications (includes app icon)
./package_app.sh
```

Or run directly without packaging:

```bash
swift run
```

---

## Packaging

The included `package_app.sh` script:
1. Compiles the release binary via `swift build -c release`
2. Generates `AppIcon.icns` from the project's transparent PNG (using `make_icns.sh`)
3. Assembles the full `.app` bundle at `AirDrift.app/`
4. Copies it to `/Applications/`

After the first launch, grant **Accessibility** permission when prompted. The app will appear in your menu bar as a laptop/phone icon.

---

## Settings

Open **Settings** from the menu bar popover (⚙️ icon) or search **AirDrift** in Spotlight.

| Setting | Description | Range |
|---|---|---|
| Scroll Speed | Multiplier applied to trackpad scroll deltas | 0.2× – 2.0× |
| Border Locking Width | Width of the trigger zone at the screen's left edge | 2 – 25 px |
| Screen Re-entry Cooldown | Minimum delay before cursor can re-enter Android space | 0.1 – 1.5 s |

---

## Developer

Made by [Falak Parmar](https://github.com/Falak-Parmar)  
Part of the [Drift](https://github.com/Falak-Parmar/Drift) project.
