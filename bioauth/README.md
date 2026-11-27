# bioauth — generic biometric PAM authentication

`bioauth` is a small, **device-agnostic** biometric authentication stack for Linux
PAM services. It is intentionally not tied to a particular fingerprint sensor,
kernel driver, SoC or vendor TA.

```
pam_bioauth.so          PAM client: TTY UI or fullscreen GTK4 helper (bioauth-ui)
        │  Unix socket + SO_PEERCRED (session/seq scoped requests)
        ▼
bioauthd (root)         state machine / lockout / password verify / cancel
        │  backend interface
        ├── backend_fprintd   fprintd-verify (queue wrapper); any libfprint device
        └── backend_mock      tests / development (BIOAUTH_MOCK_DELAY for races)
```

The GUI presentation is a single **fullscreen, undecorated, dark "secure screen"
with a centered card** — the same interaction style as Windows UAC / pkexec
prompts. One window, no multi-step dialogs, fingerprint armed immediately.
It is **presentation only, not a security boundary**: a real trusted "secure
desktop" needs compositor/greeter cooperation — see
[Security boundary and audit conclusions](#security-boundary-and-audit-conclusions-2026-11-13).

> Documentation baseline: 2026-11-21. Behaviour below and the audit/verification
> conclusions were measured **2026-11-13** on this device (Ubuntu 24.04 / GNOME 46
> / Wayland) and have not changed since; chronological project history lives in
> `../docs/HISTORY.md`.

## Current behaviour

Fingerprint (default, no initial choice):

- window opens with "正在准备认证…"; once the backend has armed the sensor it
  changes to "请把手指放在指纹传感器上…".  The daemon sends
  `{"event":"fingerprint_armed"}` when fprintd reports `finger-needed`; an older
  driver/daemon gets a conservative 2 s fallback.  Touches during the arming
  window are lost by the sensor, so the UI explicitly asks the user to wait
  instead of showing a blind spinner.  The helper emits the
  `{"event":"ready"}` handshake once the window is actually mapped (the PAM
  module kills a helper that never becomes ready and falls back — this is what
  turns the old silent "no popup" failure into a logged, recoverable event).
- mismatch → persistent red `指纹不匹配（n/N）。` for ~1.2 s, then auto-retry.
- scan timeout (no finger placed) → `未检测到手指，请重试。` and retry; it is
  **not** counted as a mismatch and never advances the lockout counter.
- N mismatches (`max_failures`) → fingerprint disabled → password only; a
  password success resets the counter and re-enables fingerprint.
- device/backend error → the daemon silently retries once after the TA
  watchdog has reloaded the loader; only a persistent failure shows
  `指纹不可用`, then password is offered and the retry button stays.  Clicking
  `使用指纹` clears the stale red error before arming the new attempt.
- sudo prompts show the command line being authorized (`命令：…`) so a
  high-risk command can be judged before authenticating.  It is parsed from the
  PAM process argv for `sudo`/`sudo-i` only, truncated to two lines, and never
  written to the logs.  Command arguments can themselves contain secrets.
- `使用密码` immediately cancels an in-flight scan (req-scoped daemon cancel, so
  the cancel cannot hit the next attempt) and switches to the password form.
- password wrong → red `密码错误` stays visible, form stays usable;
  `password_tries` attempts per authentication (0 = unlimited).
- password success → green `验证通过` ~1 s, counter reset, window closes.
- user `取消`/close = PAM_IGNORE so the normal password stack still runs
  (sudo rescue); real failures (wrong password after retries, auth timeout)
  are PAM_AUTH_ERR.
- `auth_timeout` (0 = off) bounds the whole authentication; fingerprint retries
  and password prompts share the same deadline.

TTY mode (sudo in a terminal): same state machine; while the scan is armed the
terminal is non-canonical and **P switches to password, Q cancels** (R15). In the
password prompt, **Ctrl-]** or **F12** switches back to fingerprint; pressing
**Enter on an empty password** does the same, which also works on an on-screen
keyboard (soft keyboards cannot send Ctrl-]/F12).  **Ctrl-C** cancels and falls
back to the normal password stack, matching the GUI's cancel path.  These
gestures cannot be produced as ordinary password characters, so normal
passwords are unaffected.

## Configuration

`/etc/bioauth/config.json` (restart `bioauthd` after editing):

| key | default | meaning |
|---|---|---|
| `max_failures` | 3 | fingerprint mismatches before fingerprint is locked; **0 = never lock** |
| `password_tries` | 3 | password attempts per PAM authentication; **0 = unlimited** |
| `auth_timeout` | 120 | seconds without a successful step before auto-reject; **0 = disabled** |
| `fingerprint_timeout` | 8 | per-attempt scan timeout; a no-touch scan is not counted as a failure |
| `socket` | /run/bioauth.sock | daemon socket |
| `state_file` | /var/lib/bioauth/state.json | root-owned lockout state (0600) |

PAM reads the limits from the daemon `status` response, so they change without
editing `/etc/pam.d/*`. Never override them with `Environment=` in the systemd
unit (`bioauth-doctor` checks this).

## Install (root) and verify

```bash
make                      # build/ -> /lib/<multiarch>/security/pam_bioauth.so
make check                # daemon unit tests (no root)
make check-tty            # end-to-end PAM flow over a pty (no root, no GUI)
make check-gui            # end-to-end GUI flow on the live Wayland session (no root)
```

```bash
sudo scripts/install-bioauth.sh                # install all components, keep sudo untouched
sudo scripts/install-bioauth.sh --enable-sudo  # + insert pam_bioauth into /etc/pam.d/sudo
sudo scripts/install-bioauth.sh --rollback     # restore the sudo PAM backup
```

The script installs **module + daemon + helper + doctor from one build** (mixed
installs are the known "no popup" cause: the module requires the helper's ready
handshake and the daemon's req-scoped cancel), restarts `bioauthd`, and then runs
`bioauth-doctor` as the desktop user. The doctor checks:

- installed files match the build tree (sha256) and carry the same protocol token
- the installed helper really emits `{"event":"ready","proto":2}` on the live
  session (spawned with a mock parent, then killed)
- the installed daemon has req-scoped cancel and timeout-is-not-failure
- `/etc/pam.d/sudo` has no `debug` argument; systemd unit has no limit overrides
- daemon status responds and whether the fingerprint is currently locked out

Run it any time with `bioauth-doctor` (or `make doctor`). Exit code 1 = do not
enable for sudo yet.

## Testing without root / without touching the system

`tests/` contains a private test stack: its own `bioauthd --backend mock-*` on a
private socket plus a private PAM config directory loaded through
`pam_start_confdir(3)` (Linux-PAM >= 1.5), with a stand-in `pam_permit` rescue
module mirroring sudo's `common-auth`. No `/etc/pam.d` or system files are
touched, and the real fingerprint device is never used.

- `tests/e2e_tty.py` — pty-driven: keyboard switch/cancel, lockout, timeout.
- `tests/e2e_gui.py` — drives the real fullscreen helper through AT-SPI
  (clicks/typing like a user), asserts daemon state, and saves full-screen
  screenshots under `tests/screenshots/`.
- `tests/test_daemon.py` — state machine, req-scoped cancel, timeout non-counting.

AT-SPI automation needs `gsettings set org.gnome.desktop.interface
toolkit-accessibility true` (the test enables it).

## Troubleshooting "no popup"

1. Run `bioauth-doctor`. It tells you whether installed module/daemon/helper are
   from the same build and whether the installed helper actually becomes ready.
2. Enable debug logs (only for tests, **never** on the real sudo line):
   `BIOAUTH_PAM_DEBUG=1` in the PAM environment writes to
   `/run/bioauth/pam.log` (0600, O_NOFOLLOW; falls back to `/tmp/bioauth-pam.log`
   if the runtime dir is missing). Helper startup logs go to `BIOAUTH_UI_LOG`.
   Password values are never written (helper lines are logged by event name only).
3. If the helper is killed with "did not become ready", check the helper log for
   GTK/Wayland errors and that the PAM process runs as a user with a live
   `$XDG_RUNTIME_DIR` and a Wayland/X11 display.
4. PAM_TTY / helper-start decision table (the module already logs each step):

   | observed | meaning | next check |
   |---|---|---|
   | no `enter user=…` line at all | module not loaded / old `.so` / wrong service file | installed module hash (`bioauth-doctor`), `pamtester` uses another service |
   | `ui_kind=1`, `tty_open /dev/pts/N` | terminal caller selected the TTY UI **by design** — no GTK window expected | add `prefer=gui` to the PAM line if the overlay is wanted in a terminal |
   | `ui_kind=2`, `helper started`, no `helper<- {"event":"ready"}` | helper failed before map / old helper | `BIOAUTH_UI_LOG`; `$WAYLAND_DISPLAY` / `$XDG_RUNTIME_DIR`; GDM before login has no `/run/user/$uid` — out of scope |
   | `helper not ready within N ms` then `ui closed` | build skew (old helper) or slow map | install one build; `bioauth-doctor` |
   | `daemon connect failed` / `daemon status failed` | daemon down / permissions | `systemctl status bioauthd`, `ls -l /run/bioauth.sock` |
   | `ui_kind=0` | neither TTY nor GUI available | combine the tty errno and helper failure reason above |

## Enabling for sudo (after the test service passes)

Keep `pkexec` untouched as the rescue path and keep a root shell open while
testing. `/etc/pam.d/sudo` line:

```pam
auth     [success=done default=die ignore=ignore]  pam_bioauth.so
@include common-auth
```

- `success=done`: fingerprint/password success ends authentication.
- `default=die`: a *real* failure (wrong password after retries, auth timeout)
  does not silently re-prompt via `common-auth`.
- `ignore=ignore`: `PAM_IGNORE` (no TTY/daemon/helper, user cancel, helper
  crash) falls through to the password stack — the rescue path.

### Enabling for pkexec / polkit (optional, after sudo is stable)

pkexec and every polkit authorization prompt on the desktop run PAM through
gnome-shell's polkit agent (`polkit-agent-helper-1` -> `/etc/pam.d/polkit-1`).
Installing `pam.d/polkit-1` makes bioauth run **first** there:

- the module runs its own fullscreen secure-screen UI, so normally only the
  bioauth overlay is shown (no GNOME password dialog);
- if the user cancels / no GUI is available / the daemon is down, the module
  returns `PAM_IGNORE` and the stack falls through to `common-auth`: the
  GNOME password dialog appears exactly as before - the rescue path;
- `prefer=gui` is required: `polkit-agent-helper-1` has no usable terminal.

```bash
sudo scripts/install-bioauth.sh --enable-pkexec   # backs up + installs /etc/pam.d/polkit-1
sudo scripts/install-bioauth.sh --rollback        # restores sudo + polkit PAM
```

Scope note: PAM cannot tell *which* polkit action is being authorized (the
helper gets no action id), so this applies to **all polkit prompts** (pkexec,
package installation, time settings, ...), not only pkexec. All of them keep
the common-auth password fallback. GDM is still untouched (stock
`gdm-fingerprint` + `pam_fprintd`).

## Security boundary and audit conclusions (2026-11-13)

The former standalone audit / UAC-comparison / verification reports
(`2026-11-13`) were folded into this section and removed; their measured
conclusions are below.

### Presentation, not a security boundary

`bioauth-ui` is a normal Wayland client. It can look like UAC / pkexec and gives
clear, single-window feedback, but it **cannot** provide a trusted input channel.

What it does guarantee (measured with the helper driver + AT-SPI on the live
GNOME 46 Wayland session, 1280×800@2x → 2560×1600 physical):

- one fullscreen, near-black, undecorated window covering the whole output
  (including the GNOME top bar); card 460 logical px = 916 physical px, centered
  within ±0.5 px; every previously-bright desktop/panel pixel covered;
- explicit persistent states (fingerprint / password / locked / unavailable /
  success) and no second toplevel;
- interaction semantics: switch fingerprint↔password, cancel, and "success
  dwell ~1 s then guaranteed exit" (1.15–1.19 s measured; EOF exits in
  0.06–0.12 s); duplicate submit prevented (entry/buttons insensitive until the
  next prompt; `attempt` ids echoed); `ready` emitted exactly once after the
  window maps, with `proto:2`.

What it **cannot** guarantee — do not advertise otherwise:

- **no input isolation**: no compositor-level grab; GNOME Shell shortcuts
  (Alt+Tab, Super, Overview, notifications, lock screen) still work, and other
  same-user processes can raise windows on top, steal focus, or spoof an
  identical "password" window; there is no secure attention sequence;
- **same-user processes can read the keyboard**: if the user is in the `input`
  group (true on this device during the 2026-11-13 audit — check with
  `getent group input`), any same-user process can read `/dev/input/event*`;
  a password typed into *any* GTK window is observable — this is a system
  permission issue, not something this UI can fix (hardening: remove the user
  from `input` if evdev access is not needed);
- keyboard input path is user-controlled (GTK → helper → PAM → daemon), and the
  helper can be debugged/replaced by the same user; the trust anchor remains
  PAM + the root daemon;
- the screen can be captured/recorded, fullscreen is the compositor's decision,
  and only the current output is covered on multi-monitor setups (single
  1280×800 output on this device);
- approaching UAC requires **compositor/greeter cooperation**: a GNOME Shell
  extension using `Main.pushModal(SYSTEM_MODAL)`-style shell chrome, or a
  GDM-level separate session for authentication. Plain Wayland clients cannot
  reach that level.

### Independent audit findings that shaped the design

The audit confirmed these as requirements and they are covered by
`bioauth-doctor` / the install script:

- **Deployment consistency is the #1 "no popup" cause.** The module requires the
  helper's `ready` handshake and the daemon's req-scoped cancel. Install
  module+daemon+helper+doctor from **one** build; the doctor compares sha256 and
  protocol tokens and tests the live `ready` event.
- **No secrets in logs.** Debug logs record event/op names only, open
  `/run/bioauth/pam.log` with mode 0600 / `O_NOFOLLOW`, and never contain
  password values. Never put `debug` on a real `/etc/pam.d/sudo` line; use
  `BIOAUTH_PAM_DEBUG=1` for testing.
- **Fallback must never fail closed.** User cancel / closed window / helper
  death / unavailable daemon → `PAM_IGNORE` → `@include common-auth`; only
  exhausted or genuinely failed attempts return `PAM_AUTH_ERR` (so
  `default=die` cannot lock the user out of the terminal).
- **A no-touch scan timeout is not a mismatch**: it must not advance the
  lockout counter (`未检测到手指`, not `指纹不匹配`).
- **Lockout state is root-owned, 0600 and fsync'd**; a corrupt state file must
  not silently reset to "unlocked".
- **TTY vs GUI is explicit**: the module defaults to the TTY UI when the caller
  has a terminal; a terminal `sudo` therefore shows the P/Q TTY prompt by
  design. The overlay in a terminal requires adding `prefer=gui` (the install
  script does **not** add it to `/etc/pam.d/sudo`).
- **GDM is out of scope**: before login there is no `/run/user/$uid` and the
  helper cannot start; GDM keeps the stock `gdm-fingerprint` + `pam_fprintd`.

### Independent verification: PASS

The frozen single-build tree passed an independent verification (2026-11-13):

- `make check` 8/8 unit tests; `e2e_tty.py` 4/4; `e2e_gui.py` 10/10 twice in a
  row (no flakiness, no leftover helper/daemon processes);
- 14/14 independent security/behaviour spot checks: passwords absent from all
  logs (`testpass`/`wrongpass`/base64 forms), log mode 0600, cancel →
  `rc=25` PAM_IGNORE → password rescue succeeds, no-touch timeout leaves
  `fail_count=0` / `locked=false`;
- `bioauth-doctor` on a fresh install prefix: 0 failures / 0 warnings.
  On the *then-installed old artifacts* it reported the expected 7 build-skew
  failures — exactly the gap a single-build install closes. **Do not enable
  sudo until the doctor on the real system reports 0 failures.**

### Residual risks (documented, not blockers)

1. TTY raw mode can be left enabled if the PAM process is SIGKILLed/crashes
   while a scan is armed (normal paths restore it).
2. A legacy/no-`req` cancel can still abort whichever fingerprint scan is
   active (local DoS); the module always sends `req`, so the normal path is
   scoped.
3. The daemon socket is 0666, thread-per-connection, and the fingerprint op is
   allowed for the owning local user: a local DoS / sensor-contention surface
   (no authentication bypass).
4. Multi-monitor overlay behaviour is not covered (single output on this
   device).
5. `prefer=gui` is not installed on the default `sudo` line (terminal `sudo`
   uses the TTY UI; the overlay is verified through the private-conf GUI suite).
6. pkexec/polkit is opt-in and always keeps the password fallback; GDM is not
   modified.

### Verdict — safe to enable for sudo?

**Yes, conditionally.** Install one consistent build, require
`bioauth-doctor` to report 0 failures on the real system, then enable sudo with
the automatic PAM backup, do one supervised `sudo -k; sudo true` (TTY prompt,
`P` password, `Q`/cancel → password fallback), and keep
`/root/bioauth-sudo-backup-*` + `--rollback` (or pkexec) until the first real
sudo session is confirmed. Do not touch pkexec/GDM before that.

## Security notes

- Lockout state is root-owned (`/var/lib/bioauth/state.json`, 0600, fsync'd).
- Socket is 0666 but every connection is checked with `SO_PEERCRED`: only root
  or the target user may operate on that user. Requests carry a per-auth
  `session` + `seq` / fingerprint `req` id; cancel is scoped to one request.
- Password verification in the MVP uses shadow(5) from the root daemon; it is
  isolated so it can be replaced by a nested PAM helper later.
- The GUI is a fullscreen user-session window, not a trusted secure desktop:
  same-user processes can still read input devices or draw windows. See
  [Security boundary and audit conclusions](#security-boundary-and-audit-conclusions-2026-11-13).
- Debug logging must stay off in production PAM configs; it is enabled via the
  environment (`BIOAUTH_PAM_DEBUG`) and writes only event names, never secrets.
- No device-specific code: no `/dev/goodix_fp`, no TA/QSEE/`gfenu`, no
  `/lib/firmware` assumptions. If fprintd has no device, the module falls back
  to password.

## Files

```
README.md / INSTALL.md       component + install/rollback/security-boundary docs
daemon/bioauthd.py          root daemon (state machine + backends + cancel)
pam/pam_bioauth.c           PAM client (TTY + GUI, session/seq scoped requests)
gui/bioauth-ui              fullscreen GTK4 secure-screen helper (fd3 JSON protocol)
gui/tests/helper_driver.py  standalone helper driver + screenshot/AT-SPI checks
scripts/fprintd-verify-queue serialized fprintd-verify wrapper
scripts/bioauth-doctor      installation / deploy-skew / live-ready diagnostics
scripts/install-bioauth.sh  root install + verify + rollback script
config/bioauth.json         default config
systemd/bioauthd.service    systemd unit
pam.d/bioauth-test          standalone PAM test service
tests/                      unit + TTY + GUI end-to-end tests (no root)
```
