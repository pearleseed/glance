# Glance Face-for-sudo PAM Module

Opt-in OpenPAM authentication module (`pam_glance.so`) that lets `sudo` verify your identity via Glance's on-device ArcFace + Heavy Liveness pipeline, falling back automatically to Touch ID (`pam_tid.so`) and your Mac password (`pam_opendirectory.so`).

## How It Works

1. When you run `sudo`, OpenPAM loads `/usr/local/lib/pam/pam_glance.so` from `/etc/pam.d/sudo_local`.
2. `pam_glance.so` refuses remote/SSH/headless sessions (checking `PAM_RHOST` and failing closed via `getaudit_addr` if `AU_SESSION_FLAG_IS_REMOTE` is set or `AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS` is missing) and `root` (`uid == 0`) invocations.
3. It resolves the invoking user's home directory and connects to `~/Library/Application Support/glance-sudo/glance-sudo.sock` (inside a `0700` user-owned directory) with a 30-second send/receive timeout.
4. Before sending any challenge, `pam_glance.so` verifies the listening peer via `getpeereid` (must match the invoking non-root `uid`), `LOCAL_PEERPID` + `proc_pidpath` (must equal `/Applications/Glance.app/Contents/MacOS/glance`), and `lstat` (must be a regular root-owned file with no group/world write bits).
5. `pam_glance.so` generates a fresh 256-bit random nonce via `arc4random_buf` and sends `AUTH <64-hex>\n`.
6. Glance (`SudoAuthServer`) verifies via `getpeereid` that the connecting client is running as `root` (`uid == 0`), invokes `SudoFaceAuthenticator` with **Heavy Liveness forced on**, and replies `OK <64-hex>\n` only when the enrolled owner's face and live confirmation pass within 28 seconds.
7. On any failure, timeout, disabled toggle, locked session, or closed app, `pam_glance.so` returns `PAM_AUTHINFO_UNAVAIL` or `PAM_AUTH_ERR`, and `sudo` falls directly through to Touch ID and password.

## Security Caveat (2D Camera Limitation)

Glance uses a standard 2D RGB webcam, not a hardware depth/infrared sensor like Face ID or the Touch ID Secure Enclave. Even with **Heavy Liveness** always enforced for `sudo`, a 2D camera cannot reliably defeat a high-resolution video replay of your face. Leave Face-for-sudo disabled unless you accept this threat model.

## Install

### 1-Click In-App Setup (Recommended — No Source Code or Xcode CLT Needed)

`Glance.app` bundles a pre-compiled universal `pam_glance.so` (`Contents/Helpers/pam_glance.so`) and a self-contained setup helper (`Contents/Resources/glance-sudo-setup.sh`) that uses only standard macOS system tools:

1. Open **Glance → Settings → Sudo** and click **Set Up** (or **Repair** / **Update** if already partially configured).
2. Enter your macOS administrator password once when prompted. Glance automatically:
   - Installs or renames the app to `/Applications/Glance.app` if launched from another folder, `.dmg`, or wrong casing (and relaunches directly back to **Settings → Sudo**).
   - Installs `/usr/local/lib/pam/pam_glance.so` (`root:wheel`, `0755`).
   - Inserts `pam_glance.so` before `pam_tid.so` in `/etc/pam.d/sudo_local` while preserving existing rules.
   - Applies `root:wheel` ownership and safe non-group/world-writable permissions on `/Applications/Glance.app`.
3. If macOS denies replacing an existing `/Applications/Glance.app`, use the **Open App Management Settings** button shown in **Settings → Sudo** (or copy the command under **Manual Terminal commands**).

### Manual Source-Build CLI (Requires Xcode Command Line Tools / `clang`)

If you are building from a local checkout and want to compile `pam_glance.c` directly:

```bash
sudo chown -R root:wheel /Applications/Glance.app
sudo bash sudo-support/install.sh
```

Then open **Glance → Settings → Sudo** and enable **Face authentication for sudo**.

## Uninstall

### 1-Click In-App Uninstall (Recommended)

Open **Glance → Settings → Sudo** and click **Uninstall**. This removes `/usr/local/lib/pam/pam_glance.so`, strips `pam_glance.so` lines from `/etc/pam.d/sudo_local` (preserving `pam_tid.so` and all other rules), disables the in-app toggle, and restores your normal user ownership on `/Applications/Glance.app`.

### Manual CLI Uninstall

From an installed `Glance.app` (no source repository required):

```bash
sudo /bin/bash /Applications/Glance.app/Contents/Resources/glance-sudo-setup.sh uninstall --restore-owner "$(id -u):$(id -g)"
```

Or from the source repository:

```bash
sudo bash sudo-support/uninstall.sh
```

`/etc/pam.d/sudo` is never modified by either install or uninstall method.
