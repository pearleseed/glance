<h1 align="center">
  <br>
  <a href="https://github.com/pearleseed/glance"><img src="glance/Assets.xcassets/appicon.imageset/appicon.png" alt="Glance" width="150"></a>
  <br>
  Glance
  <br>
</h1>

<h3 align="center">Face unlock, App Lock, and Face-for-sudo for your Mac</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg" alt="Swift">
</p>

Glance brings the Face ID-like experience of your iPhone to your Mac — unlock your Mac with a glance, lock individual apps behind face verification, and optionally authenticate `sudo` in Terminal. Everything runs 100% on-device using Apple's Vision and Core ML frameworks, so your face data and Mac password never leave your machine. The UI lives seamlessly in your MacBook's notch (or a floating Dynamic Island pill on notchless Macs and external monitors).

https://github.com/user-attachments/assets/77438826-80a9-4ab2-9fc3-42407a2d0adb

---

> [!WARNING]
> ## Read before using
> ## Glance is not as secure as Apple's Face ID or Touch ID
>
> MacBooks don't come equipped with the hardware depth/infrared sensors that make iPhone Face ID trustworthy and secure. An iPhone builds a 3D map of your face; a Mac webcam sees a flat 2D image. That means:
>
> - Glance defeats, with reasonable confidence, a printed photo and a photo on a phone screen (Heavy liveness detection must be turned on)
> - Glance does not reliably defeat a high-resolution video replay of you
> - macOS has no public API that lets a third-party app authorize a lock-screen login, so lock-screen Face Unlock works by typing your encrypted password into the lock screen
> - App Lock is a **privacy convenience** that holds while Glance is running, not an OS-enforced security boundary
>
> Glance is a convenience feature, not a security upgrade. Only use it — and especially opt-in features like **Unlock session at login** or **Face-for-sudo** — if you accept this tradeoff.

---

## Installation

**Requirements:**
- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac

<a href="https://github.com/pearleseed/glance/releases/latest" target="_self"><img width="200" src="https://github.com/user-attachments/assets/cdb8af97-1ee2-4669-b7cb-dcfb56c9dd61" alt="Download for Mac" /></a>

Open the `.dmg` file, drag Glance to `/Applications`, and launch it (or [build from source](#building-from-source) for the latest features on this branch).

---

## Permissions

| Permission | Why |
|---|---|
| **Camera** | To recognize your face on-device. Frames are processed in memory and never written to disk. |
| **Accessibility** | To type your password into the lock screen and listen for the optional **On space** trigger. (Not required for App Lock or `sudo`.) |
| **Touch ID / Device Password** | Protects the 256-bit Keychain key that encrypts your face data and password, guards App Lock settings changes, and serves as fallback authentication. |

---

## How It Works

1. **Continuous circular enrollment:** Launch Glance and follow the guided onboarding in the notch. Glance calibrates your camera's neutral angle on a straight-on look, then lets you smoothly rotate your head in any direction to capture nine poses with live ring feedback and trackpad haptics. Each pose becomes a 512-dimensional ArcFace *embedding*, and the image is discarded immediately.
2. **Encrypted credentials:** Enter your Mac password once. It is encrypted with AES-GCM under a Keychain-protected key gated by Touch ID or your device password.
3. **Fast wake & unlock:** When your Mac locks, wakes from sleep, returns from a screensaver, or receives a Space press at the lock screen, Glance pre-warms the camera and expands the notch/pill animation.
4. **Verified unlock:** Once an enabled identity matches at native resolution **and** identity-bound liveness confirms a real person, Glance safely clears stray text and injects your password.

---

## Features

### Lock Screen Face Unlock & Performance

| Feature | Description |
|---|---|
| **Flexible unlock triggers** | Trigger on **wake**, on **lock**, on pressing **Space** at the lock screen, or automatically when returning to a **screensaver-locked** screen (even under Secure Event Input). Hover the notch to retry, or enable one automatic retry on failure. |
| **Fast wake-to-unlock pipeline** | Overlaps camera warm-up with the overlay arm delay (zero delay in headless mode), polls lock-state settle instead of sleeping unconditionally, skips unnecessary capture-quality work during unlock, and batches Unicode keystrokes for near-instant unlocking. |
| **Adaptive seated & full-res recognition** | Automatically recognizes naturally seated users and wide-angle webcams (e.g., Studio Display, iMac, Logitech BRIO) by locating the face quickly and matching from a native-resolution crop (up to 512 px). Enable **Strict close range** in Recognition settings to ignore distant faces in busy spaces. |
| **Night Boost *(opt-in)*** | Designed for dark rooms: softly illuminates the top 38% of your display (keeping the password field unobstructed and restoring original brightness immediately when done or on quit) and boosts low-light frames for recognition without contaminating glare detection. |
| **Global toggle shortcut** | Enable or disable Face Unlock from anywhere with a customizable hotkey (default `⌃⌥⌘F`, no extra permissions needed) with subtle audio confirmation (*Tink* on, *Pop* off) and conflict warnings. |

### Display, Camera & Session Controls

| Feature | Description |
|---|---|
| **Display-context gating (*Active when*)** | Independently toggle Face Unlock for **Built-in only**, **Built-in + external**, and **External only** (clamshell) setups across all triggers. |
| **Clamshell & hot-plug camera support** | Filters out suspended built-in cameras when your MacBook lid is closed, automatically switches to usable external/Continuity cameras, and reacts to camera plug/unplug events without restarting Glance. Configure separate camera overrides for built-in vs. external displays. |
| **Multiple identities & pose-aware quality** | Enroll several people or multiple appearances (glasses, beard, different lighting), toggle any identity on/off without deleting, and see fair pose-aware capture quality grades. |
| **Session & Keychain management** | Configurable **Auto lock session** idle timeout (defaults to 30 days, or *Never*), locked-state **Reset stored data** recovery, no double password prompts on non-Touch ID Macs, and an optional **Unlock session at login** toggle *(off by default)* for Touch ID-free Macs. |
| **Menu bar & keyboard ergonomics** | Hide or show the menu bar icon (relaunch from Spotlight/Finder to bring Settings back) and open Settings anytime via the app menu (`⌘,`). |

### Notch & Dynamic Island UI

| Feature | Description |
|---|---|
| **Notch & pill styles** | Choose **Original** (full expansion), **Minimal** (compact flank view with dedicated 120 px Lanczos-downscaled assets for crisp Retina rendering), or turn animations off completely (**Headless** mode). Automatically adapts to a floating pill on notchless Macs and external displays. |
| **Dynamic animation colors** | Recolor animations at runtime in linear light (zero extra video bloat): **Blue** (classic), **Green** (`#34C759`), or **Blue → Green** (blue while scanning, green on unlock confirmation). |
| **Physical notch size tuning** | Fine-tune notch **Width** and **Height** (`-20 pt` to `+20 pt`) to align pixel-perfectly with your Mac's camera housing. |
| **Trackpad haptics** | Subtle haptic feedback when hovering the notch and completing enrollment sectors. |

### App Lock *(Opt-in)*

Guard individual macOS applications behind face recognition (found in **Settings → Apps**, off by default):

- **Per-window privacy curtains:** Covers only the locked app's windows at their exact z-order — no Screen Recording permission needed, and other apps in front remain unobstructed. Automatically hides challenged apps if Mission Control opens.
- **Zero extra model RAM:** Shares Glance's existing on-device ArcFace + liveness pipeline and provides **Touch ID / Mac password fallback** directly from the curtain.
- **Flexible monotonic relock policies:** Set a default policy and per-app overrides — **Every time**, **After 1 / 5 / 15 / 60 minutes**, or **1 / 5 / 15 minutes after leaving** — tracked via monotonic system uptime so clock changes cannot bypass locks. Every unlocked app session revokes immediately on screen lock, sleep, or screensaver.
- **Built-in safeguards:** Modifying App Lock settings or the app list requires Touch ID / Mac password. Critical system & recovery apps (Glance, Finder, System Settings, Terminal, Activity Monitor) are protected from locking, while third-party terminals and IDEs display a caution notice. Includes a searchable installed-apps picker plus a custom `.app` chooser.

### Face Authentication for `sudo` *(Opt-in)*

Authenticate local `sudo` commands in Terminal with your face — cascading seamlessly **Face (Heavy Liveness) → Touch ID → Mac password** (found in **Settings → Sudo**, off by default):

- **Zero password injection:** Uses a native universal (`arm64` + `x86_64`) OpenPAM module (`sudo-support/pam_glance.so`) installed strictly in `/etc/pam.d/sudo_local` (survives macOS updates; `/etc/pam.d/sudo` is never touched).
- **Hardened local-only verification:** Refuses remote/SSH/headless sessions (`PAM_RHOST` and macOS audit session flags via `getaudit_addr`) and `root` invocations; verifies peer UID (`getpeereid`), executable path (`LOCAL_PEERPID` + `proc_pidpath` == `/Applications/Glance.app/Contents/MacOS/glance`), root-owned non-writable binary (`lstat`), root-only socket clients (`uid == 0`), a `0700` socket directory, and a fresh **256-bit random nonce** (`arc4random_buf`) on every request.
- **Heavy Liveness enforced:** Always runs Heavy liveness regardless of your lock-screen liveness setting. If Glance is closed, locked, disabled, or fails to match, `sudo` immediately falls through to Touch ID and password.

See [sudo-support/README.md](sudo-support/README.md) for installation and uninstall steps:

```bash
sudo chown -R root:wheel /Applications/Glance.app
sudo bash sudo-support/install.sh
```

---

## Privacy and Security

Glance is designed to keep biometric data and credentials strictly on-device.

### Face data
Glance never stores camera images. During enrollment, each captured face is converted into a **512-dimensional ArcFace embedding** using Core ML and the frame is discarded. Embeddings are stored locally and encrypted with **AES-GCM**. Glance explicitly refuses to authorize unlocks if the ArcFace model fails to load (weak Vision feature-print fallback is never accepted for unlock).

### Credentials & Keychain
Your Mac password is never written to disk in plaintext. It is encrypted with AES-GCM under a **256-bit AES session key** stored in the **macOS Data Protection Keychain** protected by `.userPresence` (Touch ID or device password). The session key lives only in memory while a session is active. The encrypted ciphertext blob uses `AfterFirstUnlockThisDeviceOnly` so lock-screen Face Unlock remains reliable even on Macs that lock their data protection keybag on screen lock. *(If you explicitly opt in to **Unlock session at login**, an ungated device-only copy of the session key is stored in Glance's Keychain access group so macOS login becomes the single authentication gate.)*

### Hardened unlock pipeline
Glance unlocks only when **all** of the following hold simultaneously:

1. Onboarding and the security notice have been completed, and no enrollment flow is active.
2. A valid Glance session is unlocked, Face Unlock is enabled globally, and the current display context is enabled.
3. The Mac is authoritatively confirmed to be at the lock screen (`CGSessionCopyCurrentDictionary`).
4. ArcFace (never a weak fallback) matches an enabled, non-stale identity above the configured threshold.
5. **Identity-bound liveness** accepts that same matched identity (confirmations reset on face loss or identity swap, while spoof deny cues stay latched across the scan).
6. Accessibility permission is granted.

During injection, Glance decodes UTF-8 password bytes directly into a mutable `[UInt16]` buffer wiped with `memset_s` (avoiding immutable heap `String` copies), posts batched grapheme-safe Unicode events through an isolated `.privateState` `CGEventSource` with cleared modifier flags (immune to Caps Lock or held wake keys), and re-verifies the lock screen before every step.

### How it tells a face from a photo
Five independent cues over a rolling ~2 s window, in two roles:

- **Deny cues** detect spoofs and override everything — **face-contour-masked screen glare** (ignoring background lights/windows beside the jaw and temples) and **multi-candidate device bezel detection** (checking all detected rectangles so background monitors cannot mask a phone held over the face).
- **Confirm cues** confirm a real 3D face — flat-vs-3D landmark geometry, **2D roll-invariant** eye-aspect-ratio blink dynamics, and **eye-aligned** nose parallax across head turns. Any single confirm cue is enough, and their absence alone never denies a live person sitting still.

**Light** mode runs deny cues only; **Heavy** mode requires both deny and confirm cues (and is always enforced for `sudo`).

### Face Lab
Face Lab is a hidden debug console for testing recognition scores and live liveness cues (lazily loaded so it uses zero extra RAM when closed).

**To open it:** **Settings → About**, then click the app icon 5 times. A **Face Lab** tab appears in the tab bar for the current launch.

---

## Building from Source

### Prerequisites
- macOS 14 Sonoma or later (runtime)
- Xcode 16+ / 26+ (build toolchain)
- Xcode Command Line Tools (`clang`, only needed if building the optional `sudo` PAM module)

### Build & Run
1. Clone the repository:
   ```bash
   git clone https://github.com/pearleseed/glance.git
   cd glance
   ```
2. Open in Xcode:
   ```bash
   open glance.xcodeproj
   ```
3. Select your Development Team under **Signing & Capabilities** (required for Data Protection Keychain entitlements on signed builds; unsigned local builds degrade safely for development) and press `Cmd + R`.

Or build from the command line:
```bash
xcodebuild -project glance.xcodeproj -scheme glance -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

### Offline Self-Tests
Glance includes standalone, camera-free Swift self-test harnesses under `tools/` covering liveness, security contracts, glare contour masking, notch UI tinting, circular enrollment pose calibration, Night Boost, App Lock state machine, and the `sudo` PAM protocol:

- `tools/liveness_selftest.swift`
- `tools/security_selftest.swift`
- `tools/glare_mask_selftest.swift`
- `tools/notch_ui_selftest.swift`
- `tools/enrollment_pose_selftest.swift`
- `tools/night_boost_selftest.swift`
- `tools/applock_selftest.swift`
- `tools/sudo_protocol_selftest.swift`

Each file includes its exact `swiftc` compile-and-run command in its header comment.

---

## Acknowledgements

- **[The Boring Notch](https://github.com/TheBoredTeam/boring.notch)** — for the notch window physics.
- **[InsightFace](https://github.com/deepinsight/insightface)** — the ArcFace model powering on-device recognition.
- **[Alcove](https://tryalcove.com)** — big design inspiration.

## License

[MIT](LICENSE) © 2026 [pearleseed](https://github.com/pearleseed) (originally created by Jonathan Zhou)
