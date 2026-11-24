#!/usr/bin/env python3
"""elish-keyboard-detect: pogo 键盘插拔/输入检测

信号（实测 + 厂商驱动 elish-r-oss: drivers/input/misc/xiaomi_keyboard/）:
- GPIO83 (`xiaomi-keyboard,in-irq-gpio`) 在拔插瞬间产生 ~1ms 低脉冲；IRQ 上升沿翻转状态；
- USB 常驻、电平不变、霍尔不动，因此没有绝对电平信号；
- 补充：监听 pogo 键盘自身的 evdev 键盘事件，任何按键输入都校准为“已连接”（本机无触摸板）。

状态:
- 冷启动(uptime<180s)默认“未连接”(0)，避免关机拔键盘再开机时判错；
- 运行中重启服务沿用 /var/lib/elish-keyboard-present；
- 拔插脉冲翻转；键盘/触摸板输入强制校准为 1；
- 手动校准: --set 0|1 / --status。

输出: /run/elish-keyboard-present (1=键盘在, 0=拔出)
只把 GPIO83 当输入读取，不触碰键盘供电(gpio127)/复位(gpio141)。
"""
import fcntl
import glob
import os
import selectors
import subprocess
import sys
import time

LINE = 83
RUN = "/run/elish-keyboard-present"
CONFIG = "/etc/default/elish-keyboard-detect"
PERSIST = "/var/lib/elish-keyboard-present"
TLMM_LABEL = "f100000.pinctrl"
DEBOUNCE_S = 0.3
STARTUP_IGNORE_S = 10.0  # 开机瞬间 USB 重枚举会打脉冲，忽略这段时间
RESCAN_S = 5.0
RESUME_SUPPRESS_S = 8.0   # 唤醒后 USB 重枚举会打脉冲，忽略这段时间免误翻平板模式
KB_NAME_HINTS = ("Xiaomi Pad Keyboard",)  # 本机键盘无触摸板；Mouse/Pad 是幻影接口，不参与校准


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def write_state(v):
    for path in (PERSIST, RUN):
        try:
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                f.write("1" if v else "0")
            os.replace(tmp, path)
        except OSError as e:
            log(f"write {path}: {e}")


def load_state():
    try:
        return open(PERSIST).read().strip() != "0"
    except OSError:
        return True


def suspend_count():
    """每次 suspend/resume 递增；用来识别“刚唤醒”并抑制重枚举脉冲。"""
    try:
        return int(open("/sys/power/suspend_stats/success").read().strip())
    except (OSError, ValueError):
        return -1


def boot_uptime():
    try:
        return float(open("/proc/uptime").read().split()[0])
    except (OSError, ValueError):
        return 0.0


def cold_boot_state():
    """冷启动默认状态：attached（默认，键盘通常接着）|detached。"""
    want = "attached"
    try:
        for line in open(CONFIG):
            line = line.split("#", 1)[0].strip()
            if line.upper().startswith("COLD_BOOT_STATE="):
                want = line.split("=", 1)[1].strip().strip('"').lower()
    except OSError:
        pass
    return want != "detached"


def initial_state():
    """冷启动按 COLD_BOOT_STATE（默认 attached）；运行中重启沿用持久化状态。"""
    if boot_uptime() < 180:
        return cold_boot_state()
    return load_state()


def tlmm_base():
    for chip in glob.glob("/sys/class/gpio/gpiochip*"):
        try:
            if TLMM_LABEL not in open(os.path.join(chip, "label")).read().strip():
                continue
            if int(open(os.path.join(chip, "ngpio")).read()) <= LINE:
                continue
            return int(open(os.path.join(chip, "base")).read())
        except (OSError, ValueError):
            continue
    return None


def unexport():
    base = tlmm_base()
    if base is None:
        return
    g = base + LINE
    if os.path.isdir(f"/sys/class/gpio/gpio{g}"):
        try:
            with open("/sys/class/gpio/unexport", "w") as f:
                f.write(str(g))
        except OSError:
            pass


def find_chip():
    try:
        out = subprocess.run(["gpiodetect"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if TLMM_LABEL in line:
            return line.split()[0]
    return None


def evdev_name(fd):
    try:
        raw = fcntl.ioctl(fd, (2 << 30) | (256 << 16) | (0x45 << 8) | 0x06, b"\0" * 256)
        return raw.split(b"\0")[0].decode(errors="ignore")
    except OSError:
        return ""


def keyboard_nodes():
    nodes = []
    for p in glob.glob("/dev/input/event*"):
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        name = evdev_name(fd)
        os.close(fd)
        if any(h in name for h in KB_NAME_HINTS):
            nodes.append(p)
    return nodes


def main():
    if "--status" in sys.argv:
        print("1" if load_state() else "0")
        return 0
    if "--set" in sys.argv:
        v = sys.argv[sys.argv.index("--set") + 1] != "0"
        write_state(v)
        log(f"keyboard_present set to {int(v)}")
        return 0

    state = initial_state()
    write_state(state)
    unexport()
    chip = find_chip()
    if not chip:
        log("TLMM gpiochip not found; retry in 5s")
        time.sleep(5)
        return 1

    proc = subprocess.Popen(
        ["stdbuf", "-oL", "-eL", "gpiomon", "-B", "pull-up", chip, str(LINE)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ, ("gpio", None))

    # 键盘/触摸板 evdev 节点：任何输入事件 -> 校准为已连接
    kb_fds = {}

    def refresh_kb():
        for p in keyboard_nodes():
            if p in kb_fds:
                continue
            try:
                fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            kb_fds[p] = fd
            sel.register(fd, selectors.EVENT_READ, ("kbd", p))
            log(f"watching input node {p} ({evdev_name(fd)})")

    refresh_kb()
    last_scan = time.time()
    started = time.time()
    last_pulse = 0.0
    last_resume = 0.0
    suspend_seen = suspend_count()
    prev_wall = time.time()
    prev_mono = time.monotonic()

    def check_resume():
        """用 wall/monotonic 时钟差识别休眠：挂起时 monotonic 停走、wall 继续，
        两者差值突然变大即刚从休眠回来。比 suspend_stats（唤醒后半段才更新）可靠。"""
        nonlocal prev_wall, prev_mono, last_resume
        now_wall = time.time()
        now_mono = time.monotonic()
        gap = (now_wall - prev_wall) - (now_mono - prev_mono)
        prev_wall, prev_mono = now_wall, now_mono
        if gap > 2.0:
            last_resume = now_wall
            drop_kb()
            refresh_kb()
            log(f"resume detected (clock gap {gap:.1f}s); ignore pulses {RESUME_SUPPRESS_S:.0f}s")
            return True
        return False

    def drop_kb():
        for p in list(kb_fds):
            fd = kb_fds.pop(p)
            try:
                sel.unregister(fd)
            except (KeyError, ValueError):
                pass
            try:
                os.close(fd)
            except OSError:
                pass
    log(f"watching {chip} line {LINE}, initial keyboard_present={int(state)} "
        f"({'cold boot' if boot_uptime() < 180 else 'persist'})")

    while True:
        for key, _ in sel.select(timeout=1.0):
            kind, _node = key.data
            if kind == "gpio":
                line = proc.stdout.readline()
                if not line:
                    log("gpiomon exited")
                    return proc.poll() or 0
                if "FALLING EDGE" not in line or f"offset: {LINE}" not in line:
                    continue
                if check_resume():
                    continue
                now = time.time()
                sc = suspend_count()
                if sc != suspend_seen:
                    # 唤醒后的第一个脉冲会在循环末尾的检测之前到达：先认 rescan，
                    # 并把这个脉冲当重枚举噪声忽略。
                    suspend_seen = sc
                    last_resume = now
                    drop_kb()
                    refresh_kb()
                    log(f"resume detected on pulse (suspend #{sc}); ignore pulses {RESUME_SUPPRESS_S:.0f}s")
                    continue
                if now - last_resume < RESUME_SUPPRESS_S:
                    log(f"pulse ignored ({now - last_resume:.1f}s after resume)")
                    continue
                if now - started < STARTUP_IGNORE_S or now - last_pulse < DEBOUNCE_S:
                    continue
                last_pulse = now
                state = not state
                write_state(state)
                log(f"pulse -> keyboard_present={int(state)}")
            else:
                if check_resume():
                    continue
                fd = kb_fds.get(_node)
                if fd is None:
                    continue
                try:
                    data = os.read(fd, 24 * 64)
                except BlockingIOError:
                    data = b""
                except OSError as e:
                    # 唤醒/重枚举后旧 evdev 节点会 ENODEV；丢掉重扫，不能崩
                    try:
                        sel.unregister(fd)
                    except (KeyError, ValueError):
                        pass
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    kb_fds.pop(_node, None)
                    last_resume = time.time()
                    log(f"input node {_node} vanished ({e}); rescan, ignore pulses {RESUME_SUPPRESS_S:.0f}s")
                    continue
                if data and not state:
                    state = True
                    write_state(state)
                    log(f"input activity -> keyboard_present=1 ({_node})")
        check_resume()
        sc = suspend_count()
        if sc != suspend_seen:
            suspend_seen = sc
            last_resume = time.time()
            drop_kb()
            refresh_kb()
            log(f"resume detected (suspend #{sc}); ignore pulses {RESUME_SUPPRESS_S:.0f}s, rescan input nodes")
        if time.time() - last_scan >= RESCAN_S:
            last_scan = time.time()
            refresh_kb()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
