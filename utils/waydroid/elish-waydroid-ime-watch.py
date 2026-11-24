#!/usr/bin/env python3
"""follow elish tablet-mode switch -> Waydroid show_ime_with_hard_keyboard

tablet mode ON  (pure touch, no keyboard) -> 1 (soft keyboard allowed)
tablet mode OFF (laptop, pogo keyboard)    -> 0 (suppress soft keyboard)

空闲时只做一次 evdev ioctl（微秒级）；仅在状态变化时调用 waydroid shell。
"""
import fcntl, glob, os, subprocess, sys, time

NODE_NAME = "elish-tablet-mode"
SETTING = "show_ime_with_hard_keyboard"
NET_UP = "/run/waydroid-lxc/network_up"
ENV = dict(os.environ)
ENV.setdefault("XDG_RUNTIME_DIR", "/run/user/1000")
ENV.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus")
ENV.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def find_node():
    for p in glob.glob("/dev/input/event*"):
        try:
            fd = os.open(p, os.O_RDONLY)
            raw = fcntl.ioctl(fd, (2 << 30) | (256 << 16) | (0x45 << 8) | 0x06, b"\0" * 256)
            os.close(fd)
            if NODE_NAME in raw.decode(errors="ignore"):
                return p
        except OSError:
            continue
    return None


def sw_state(node):
    try:
        fd = os.open(node, os.O_RDONLY)
        buf = bytearray(8)
        fcntl.ioctl(fd, (2 << 30) | (8 << 16) | (0x45 << 8) | 0x1B, buf, True)
        os.close(fd)
        return (int.from_bytes(buf, "little") >> 1) & 1
    except OSError:
        return None


def apply(value):
    r = subprocess.run(["waydroid", "shell", "--", "settings", "put", "secure", SETTING, str(value)],
                       capture_output=True, text=True, env=ENV)
    if r.returncode != 0:
        return False
    log(f"set {SETTING}={value}")
    return True


def main():
    last = None
    pending = None
    last_try = 0.0
    while True:
        node = find_node()
        st = sw_state(node) if node else None
        if st is not None and st != last:
            last = st
            pending = st
        if pending is not None and os.path.exists(NET_UP):
            now = time.time()
            if now - last_try >= 3:
                last_try = now
                if apply(pending):
                    pending = None
        time.sleep(2)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
