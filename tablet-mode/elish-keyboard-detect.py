#!/usr/bin/env python3
"""elish-keyboard-detect: 用 TLMM GPIO83 的脉冲检测 pogo 键盘插拔

背景（本机实测）:
- GPIO83 = 厂商 DTS 的 `xiaomi-keyboard,in-irq-gpio`；
- 该引脚平时为高，**拔插瞬间会产生一个 ~1ms 的低脉冲**（falling→rising），
  打字/空闲不产生脉冲；
- 因此用“每个低脉冲翻转一次状态”来跟踪键盘在/不在，初始状态默认“在”，
  并持久化到 /var/lib/elish-keyboard-present（服务重启不丢，极端情况可手动 --set 校准）。

输出: /run/elish-keyboard-present (1=键盘在, 0=拔出)
只读 GPIO83（gpiomon 带上拉），不触碰键盘供电(gpio127)/复位(gpio141)。

用法: elish-keyboard-detect            # 后台服务
      elish-keyboard-detect --set 0|1 # 手动校准并退出
      elish-keyboard-detect --status  # 打印当前状态
"""
import glob
import os
import subprocess
import sys
import time

LINE = 83
RUN = "/run/elish-keyboard-present"
PERSIST = "/var/lib/elish-keyboard-present"
TLMM_LABEL = "f100000.pinctrl"
DEBOUNCE_S = 0.3
STARTUP_IGNORE_S = 2.0


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


def initial_state():
    """沿用上次持久化的状态（USB/电平/霍尔在本机都不可靠，见 README）。
    服务停过且期间拔插过、或关机时拔插导致错位时，用 --set 校准。"""
    return load_state()


def tlmm_base():
    for chip in glob.glob("/sys/class/gpio/gpiochip*"):
        try:
            label = open(os.path.join(chip, "label")).read().strip()
            if TLMM_LABEL not in label:
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
    # gpiodetect 会打印 "gpiochipN [f100000.pinctrl] (181 lines)"
    try:
        out = subprocess.run(["gpiodetect"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if TLMM_LABEL in line:
            return line.split()[0]
    return None


def main():
    if "--status" in sys.argv:
        print("1" if load_state() else "0")
        return 0
    if "--set" in sys.argv:
        v = "1" if sys.argv[sys.argv.index("--set") + 1] != "0" else "0"
        write_state(v == "1")
        log(f"keyboard_present set to {v}")
        return 0

    state = initial_state()
    log(f"initial state from persist: {int(state)}")
    write_state(state)
    unexport()
    chip = find_chip()
    if not chip:
        log("TLMM gpiochip not found; retry in 5s")
        time.sleep(5)
        return 1
    log(f"watching {chip} line {LINE}, initial keyboard_present={int(state)}")

    proc = subprocess.Popen(
        ["stdbuf", "-oL", "-eL", "gpiomon", "-B", "pull-up", chip, str(LINE)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    started = time.time()
    last = 0.0
    for line in proc.stdout:
        if "FALLING EDGE" not in line or f"offset: {LINE}" not in line:
            continue
        now = time.time()
        if now - started < STARTUP_IGNORE_S or now - last < DEBOUNCE_S:
            continue
        last = now
        state = not state
        write_state(state)
        log(f"pulse -> keyboard_present={int(state)}")
    return proc.wait()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
