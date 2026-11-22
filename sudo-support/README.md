# Glance Face-for-sudo PAM Module

Opt-in OpenPAM authentication module (`pam_glance.so`) that lets `sudo` verify your identity via Glance's on-device ArcFace + Heavy Liveness pipeline, falling back automatically to Touch ID (`pam_tid.so`) and your Mac password (`pam_opendirectory.so`).

## How It Works

1. When you run `sudo`, OpenPAM loads `/usr/local/lib/pam/pam_glance.so` from `/etc/pam.d/sudo_local`.
2. `pam_glance.so` refuses remote/SSH sessions (`PAM_RHOST` set) and `root` (`uid == 0`) invocations.
3. It resolves the invoking user's home directory and connects to `~/Library/Application Support/glance-sudo/glance-sudo.sock` (inside a `0700` user-owned directory) with a 30-second send/receive timeout.
4. Before sending any challenge, `pam_glance.so` verifies the listening peer via `getpeereid` (must match the invoking non-root `uid`), `LOCAL_PEERPID` + `proc_pidpath` (must equal `/Applications/Glance.app/Contents/MacOS/glance`), and `lstat` (must be a regular root-owned file with no group/world write bits).
5. `pam_glance.so` generates a fresh 256-bit random nonce via `arc4random_buf` and sends `AUTH <64-hex>\n`.
6. Glance (`SudoAuthServer`) verifies via `getpeereid` that the connecting client is running as `root` (`uid == 0`), invokes `SudoFaceAuthenticator` with **Heavy Liveness forced on**, and replies `OK <64-hex>\n` only when the enrolled owner's face and live confirmation pass within 28 seconds.
7. On any failure, timeout, disabled toggle, locked session, or closed app, `pam_glance.so` returns `PAM_AUTHINFO_UNAVAIL` or `PAM_AUTH_ERR`, and `sudo` falls directly through to Touch ID and password.

## Security Caveat (2D Camera Limitation)

Glance uses a standard 2D RGB webcam, not a hardware depth/infrared sensor like Face ID or the Touch ID Secure Enclave. Even with **Heavy Liveness** always enforced for `sudo`, a 2D camera cannot reliably defeat a high-resolution video replay of your face. Leave Face-for-sudo disabled unless you accept this threat model.

## Install

Requires Xcode Command Line Tools (`clang`) and a root-owned copy of Glance in `/Applications/Glance.app`.

```bash
sudo chown -R root:wheel /Applications/Glance.app
sudo bash sudo-support/install.sh
```

Then open **Glance → Settings → Sudo** and enable **Face authentication for sudo**.

## Uninstall

```bash
sudo bash sudo-support/uninstall.sh
```

`uninstall.sh` removes `/usr/local/lib/pam/pam_glance.so` and strips `pam_glance.so` lines from `/etc/pam.d/sudo_local` while preserving all existing lines (such as `pam_tid.so`). `/etc/pam.d/sudo` is never modified.
