#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
hi556-build-dtb.py — 为 Xiaomi Pad 5 Pro (elish / SM8250 / CSOT) 生成启用景深相机 Hi556
的联合 DTB，并做完整的“只增不丢”校验。

背景
----
部署链：/usr/lib/linux-image-$(uname -r)/qcom/sm8250-xiaomi-elish-csot.dtb
        -> /etc/kernel/postinst.d/zz-update-abl-kernel（cat Image.gz + dtb -> mkbootimg）
        -> armbian-kernel-csot.img -> boot_b（ABL 启动）。
当前联合 DTB 的真实构建源已丢失（见 .work/android-cam-20261120/hi556-dts.md §2）。
本脚本以部署中的 DTB 为基线，提供 3 种可复现的构建方式，产物语义一致：

  --method fdt    直接用 libfdt 在基线 DTB 上增补节点（默认；不经 dtc 文本往返）
  --method dtc    dtc 反编译 -> 文本增补 -> dtc 编译 -> 还原 dtc 往返损坏的属性
  --method dtbo   编译 DTBO overlay -> fdtoverlay 离线合并 -> 修正 fdtoverlay 重分配的 phandle

所有方式都会验证：
  * 与基线 DTB 相比只有计划内新增（节点/属性），无删除、无改动；
  * 新增节点的电压/GPIO/时钟/lane/link-freq/phandle 引用正确；
  * 基线 DTB 的定制节点（指纹/GNSS/fastrpc vmid/rear OV13B10 等）与 L10C 4 字节属性保持不变；
  * fdt_check_full() 通过。

用法
----
  ./hi556-build-dtb.py                                  # 默认：基线=包内联合 DTB，输出 /tmp/...dtb
  ./hi556-build-dtb.py --base <joint.dtb> --out /tmp/x.dtb
  ./hi556-build-dtb.py --stage 1                        # 仅 ldo2+pinctrl+CCI0 传感器节点（不动 camss）
  ./hi556-build-dtb.py --method dtc --emit-dts /tmp/patched.dts
  ./hi556-build-dtb.py --method dtbo --emit-dtso /tmp/hi556.dtso

只读、不写 /boot、不写块设备；root 不需要。
"""

import argparse
import ctypes as C
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------- 常量/基线

BASE_SHA256 = "14909d42d6a1935f6dd49ff8b4700e0adf4164024c6f0c25f6ba94b6ad3ee4a8"
# 包内联合 DTB（2026-11-20 起）已把 Hi556 合并进去；用这个基线时无需再生成。
MERGED_SHA256 = "0d639355650ad34ef3a03ed6af44f4fd2e1ec287aadd543a7c707238f8b544e8"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BASE = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "sm8250-xiaomi-elish-csot.dtb"))
DEFAULT_OUT = "/tmp/sm8250-xiaomi-elish-csot-hi556.dtb"
VERIFY_SCRIPT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "verify-combined-dtb.sh"))

CAMCC_CLK_ID = 75          # CAM_CC_MCLK1_CLK
LINK_FREQ = 437000000      # hi556.c HI556_LINK_FREQ_437MHZ
MCLK_RATE = 19200000       # hi556.c HI556_MCLK
GPIO_RESET = 26            # &tlmm 26, GPIO_ACTIVE_LOW
GPIO_MCLK = 95             # MCLK1 pin

# 新增 phandle（基线 DTB 最大 phandle = 0x1106）
PH = {"ldo2": 0x1200, "hi556_ep": 0x1201, "mclk1": 0x1202,
      "depth_active": 0x1203, "csiphy0_ep": 0x1204, "l3p": 0x1205}

P_LDO2 = "/soc@0/rsc@18200000/regulators-1/ldo2"
P_PINCTRL = "/soc@0/pinctrl@f100000"
P_MCLK1 = P_PINCTRL + "/cam-mclk1-default-state"
P_DEPTH = P_PINCTRL + "/camera-depth-active-state"
P_CCI0 = "/soc@0/cci@ac4f000"
P_BUS1 = P_CCI0 + "/i2c-bus@1"
P_CAM = P_BUS1 + "/camera@20"
P_CAM_EP = P_CAM + "/port/endpoint"
P_CAMSS = "/soc@0/camss@ac6a000"
P_CSIPHY0 = P_CAMSS + "/ports/port@0"
P_CSIPHY0_EP = P_CSIPHY0 + "/endpoint"
P_PM8008_L3P = "/soc@0/geniqup@8c0000/i2c@884000/pmic@8/regulators/ldo3"
P_TLMM = "/soc@0/pinctrl@f100000"
P_CAMCC = "/soc@0/clock-controller@ad00000"
P_LDO1C = "/soc@0/rsc@18200000/regulators-1/ldo1"
P_L10C = "/soc@0/rsc@18200000/regulators-1/ldo10"

# 基线 L10C 4 字节原值（dtc 往返会写成 3 字节，必须还原）
L10C_MIN = bytes.fromhex("00324b00")

ALLOWED_ADDED_NODES = {
    1: [P_LDO2, P_MCLK1, P_DEPTH, P_CAM, P_CAM + "/port", P_CAM_EP],
    2: [P_LDO2, P_MCLK1, P_DEPTH, P_CAM, P_CAM + "/port", P_CAM_EP, P_CSIPHY0_EP],
}
ALLOWED_ADDED_PROPS = {P_PM8008_L3P: ["phandle"]}


class VerifyError(RuntimeError):
    pass


# ---------------------------------------------------------------- libfdt 绑定
# 作用：加载/遍历/修改 FDT；系统 libfdt.so.1 即够用，无需 python-libfdt。

_lib = C.CDLL("libfdt.so.1")
_lib.fdt_check_header.argtypes = [C.c_void_p]
_lib.fdt_check_header.restype = C.c_int
_lib.fdt_path_offset.argtypes = [C.c_void_p, C.c_char_p]
_lib.fdt_path_offset.restype = C.c_int
_lib.fdt_subnode_offset.argtypes = [C.c_void_p, C.c_int, C.c_char_p]
_lib.fdt_subnode_offset.restype = C.c_int
_lib.fdt_add_subnode.argtypes = [C.c_void_p, C.c_int, C.c_char_p]
_lib.fdt_add_subnode.restype = C.c_int
_lib.fdt_setprop.argtypes = [C.c_void_p, C.c_int, C.c_char_p, C.c_void_p, C.c_int]
_lib.fdt_setprop.restype = C.c_int
_lib.fdt_getprop.argtypes = [C.c_void_p, C.c_int, C.c_char_p, C.POINTER(C.c_int)]
_lib.fdt_getprop.restype = C.c_void_p
_lib.fdt_get_name.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_int)]
_lib.fdt_get_name.restype = C.c_char_p
_lib.fdt_first_subnode.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_first_subnode.restype = C.c_int
_lib.fdt_next_subnode.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_next_subnode.restype = C.c_int
_lib.fdt_first_property_offset.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_first_property_offset.restype = C.c_int
_lib.fdt_next_property_offset.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_next_property_offset.restype = C.c_int
_lib.fdt_get_property_by_offset.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_int)]
_lib.fdt_get_property_by_offset.restype = C.c_void_p
_lib.fdt_string.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_string.restype = C.c_char_p
_lib.fdt_open_into.argtypes = [C.c_void_p, C.c_void_p, C.c_int]
_lib.fdt_open_into.restype = C.c_int
_lib.fdt_del_node.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_del_node.restype = C.c_int
_lib.fdt_pack.argtypes = [C.c_void_p]
_lib.fdt_pack.restype = C.c_int
_lib.fdt_check_full.argtypes = [C.c_void_p, C.c_int]
_lib.fdt_check_full.restype = C.c_int

ERR = {-1: "NOTFOUND", -2: "EXISTS", -3: "NOSPACE", -4: "BADOFFSET",
       -5: "BADPATH", -6: "BADPHANDLE", -7: "BADSTATE", -8: "TRUNCATED",
       -9: "BADMAGIC"}


def errname(r):
    return ERR.get(r, "ERR(%d)" % r)


class Fdt:
    """整块 FDT 的可增长修改器（capacity 为缓冲区字节数）。"""

    def __init__(self, blob, capacity=None):
        cap = capacity or (len(blob) + 262144)
        self.buf = C.create_string_buffer(cap)
        C.memmove(self.buf, blob, len(blob))
        self.cap = cap
        ret = _lib.fdt_open_into(self.buf, self.buf, cap)
        if ret:
            raise VerifyError("fdt_open_into: " + errname(ret))

    @property
    def ptr(self):
        return C.cast(self.buf, C.c_void_p)

    def total(self):
        return int.from_bytes(C.string_at(self.ptr, 8)[4:8], "big")

    def check_full(self):
        return _lib.fdt_check_full(self.ptr, self.total())

    def tobytes(self):
        ret = _lib.fdt_pack(self.ptr)
        if ret:
            raise VerifyError("fdt_pack: " + errname(ret))
        return self.buf.raw[:self.total()]

    def off(self, path):
        ret = _lib.fdt_path_offset(self.ptr, path.encode())
        if ret < 0:
            raise KeyError("%s: %s" % (path, errname(ret)))
        return ret

    def name(self, off):
        n = _lib.fdt_get_name(self.ptr, off, None)
        return n.decode() if n else None

    def del_node(self, off):
        ret = _lib.fdt_del_node(self.ptr, off)
        if ret:
            raise VerifyError("del_node: " + errname(ret))

    def add_node(self, parent_off, name):
        ret = _lib.fdt_add_subnode(self.ptr, parent_off, name.encode())
        if ret < 0:
            raise VerifyError("add_subnode %s: %s" % (name, errname(ret)))
        return ret

    def set_raw(self, off, prop, data):
        buf = C.create_string_buffer(data, len(data)) if data else None
        ret = _lib.fdt_setprop(self.ptr, off, prop.encode(),
                               C.cast(buf, C.c_void_p) if buf else None, len(data))
        if ret:
            raise VerifyError("setprop %s: %s" % (prop, errname(ret)))

    def set_u32(self, off, prop, *vals):
        self.set_raw(off, prop, b"".join(v.to_bytes(4, "big") for v in vals))

    def set_u64(self, off, prop, *vals):
        self.set_raw(off, prop, b"".join(v.to_bytes(8, "big") for v in vals))

    def set_str(self, off, prop, s):
        self.set_raw(off, prop, s.encode() + b"\0")

    def get_raw(self, off, prop):
        ln = C.c_int()
        p = _lib.fdt_getprop(self.ptr, off, prop.encode(), C.byref(ln))
        if p is None or ln.value < 0:
            return None
        return C.string_at(p, ln.value)

    def get_u32(self, off, prop):
        b = self.get_raw(off, prop)
        return None if b is None else int.from_bytes(b, "big")

    def _props(self, nodeoff):
        out = []
        po = _lib.fdt_first_property_offset(self.ptr, nodeoff)
        while po >= 0:
            ln = C.c_int()
            pp = _lib.fdt_get_property_by_offset(self.ptr, po, C.byref(ln))
            raw = C.string_at(pp, 12)
            tag = int.from_bytes(raw[0:4], "big")
            if tag != 3:
                raise VerifyError("bad FDT_PROP tag at %d" % po)
            plen = int.from_bytes(raw[4:8], "big")
            nameoff = int.from_bytes(raw[8:12], "big")
            pname = _lib.fdt_string(self.ptr, nameoff).decode()
            out.append((pname, C.string_at(pp + 12, plen)))
            po = _lib.fdt_next_property_offset(self.ptr, po)
        return out

    def _children(self, nodeoff):
        out, ch = [], _lib.fdt_first_subnode(self.ptr, nodeoff)
        while ch >= 0:
            out.append(ch)
            ch = _lib.fdt_next_subnode(self.ptr, ch)
        return out

    def dump(self):
        res = {}

        def walk(off, path):
            res[path] = dict(self._props(off))
            for ch in self._children(off):
                walk(ch, path.rstrip("/") + "/" + self.name(ch))
        walk(0, "/")
        return res


def load(path, capacity=None):
    with open(path, "rb") as f:
        return Fdt(f.read(), capacity=capacity)


# ---------------------------------------------------------------- 公共工具

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def diff(base, new):
    b, n = base.dump(), new.dump()
    added_nodes = sorted(set(n) - set(b))
    removed_nodes = sorted(set(b) - set(n))
    added_props, removed_props, changed = [], [], []
    for path in sorted(set(b) & set(n)):
        for p, v in n[path].items():
            if p not in b[path]:
                added_props.append((path, p))
            elif b[path][p] != v:
                changed.append(path)
        for p in b[path]:
            if p not in n[path]:
                removed_props.append((path, p))
    return added_nodes, removed_nodes, added_props, removed_props, sorted(set(changed))


def restore_base_props(base, new):
    """把 dtc 文本往返 / overlay 合并可能改动的属性字节还原为基线原值。"""
    b, n = base.dump(), new.dump()
    restored = []
    for path in b:
        if path not in n:
            continue
        for prop, val in b[path].items():
            cur = n[path].get(prop)
            if cur is not None and cur != val:
                new.set_raw(new.off(path), prop, val)
                restored.append((path, prop))
    return restored


def resolve_phandle(dump, ph):
    for path, props in dump.items():
        p = props.get("phandle")
        if p is not None and int.from_bytes(p, "big") == ph:
            return path
    return None


def cell(props, name, idx=0):
    raw = props[name]
    return int.from_bytes(raw[idx * 4:(idx + 1) * 4], "big")


def sval(props, name):
    return props[name].rstrip(b"\0").decode()


def p32(props, name, val, idx=0):
    if cell(props, name, idx) != val:
        raise VerifyError("%s[%d] != %#x (实际 %#x)"
                          % (name, idx, val, cell(props, name, idx)))


def pstr(path, name, val):
    if sval(path, name) != val:
        raise VerifyError("%s/%s != %r" % (path, name, val))


# ---------------------------------------------------------------- 写入 DTB 节点

def write_fdt_nodes(f, ph):
    """在 Fdt 上直接增补全部节点；ph 为 phandle 字典。"""
    # (1) pm8150l rpmh ldoc2
    r1 = f.off("/soc@0/rsc@18200000/regulators-1")
    n = f.add_node(r1, "ldo2")
    f.set_str(n, "regulator-name", "vreg_l2c_1p2")
    f.set_u32(n, "regulator-min-microvolt", 1200000)
    f.set_u32(n, "regulator-max-microvolt", 1304000)
    f.set_u32(n, "regulator-initial-mode", 3)  # RPMH_REGULATOR_MODE_HPM
    f.set_u32(n, "phandle", ph["ldo2"])

    # (2) pm8008 L3P 补 phandle（原本未引用，DTB 里没有 phandle）
    l3p = f.off(P_PM8008_L3P)
    f.set_u32(l3p, "phandle", ph["l3p"])

    # (3) pinctrl
    tlmm = f.off(P_PINCTRL)
    n = f.add_node(tlmm, "cam-mclk1-default-state")
    f.set_str(n, "pins", "gpio%d" % GPIO_MCLK)
    f.set_str(n, "function", "cam_mclk")
    f.set_u32(n, "drive-strength", 4)
    f.set_raw(n, "bias-disable", b"")
    f.set_u32(n, "phandle", ph["mclk1"])
    n = f.add_node(tlmm, "camera-depth-active-state")
    f.set_str(n, "pins", "gpio%d" % GPIO_RESET)
    f.set_str(n, "function", "gpio")
    f.set_u32(n, "drive-strength", 2)
    f.set_raw(n, "bias-disable", b"")
    f.set_u32(n, "phandle", ph["depth_active"])

    # (4) Hi556 sensor on CCI0 master1 (cci0 i2c-bus@1)
    bus1 = f.off(P_BUS1)
    cam = f.add_node(bus1, "camera@20")
    f.set_str(cam, "compatible", "hynix,hi556")
    f.set_u32(cam, "reg", 0x20)
    f.set_u32(cam, "avdd-supply", ph["l3p"])
    f.set_u32(cam, "dovdd-supply", f.get_u32(f.off(P_LDO1C), "phandle"))
    f.set_u32(cam, "dvdd-supply", ph["ldo2"])
    camcc_ph = f.get_u32(f.off(P_CAMCC), "phandle")
    f.set_u32(cam, "clocks", camcc_ph, CAMCC_CLK_ID)
    f.set_str(cam, "clock-names", "clk")
    f.set_u32(cam, "assigned-clocks", camcc_ph, CAMCC_CLK_ID)
    f.set_u32(cam, "assigned-clock-rates", MCLK_RATE)
    f.set_u32(cam, "reset-gpios", f.get_u32(f.off(P_TLMM), "phandle"),
               GPIO_RESET, 1)  # GPIO_ACTIVE_LOW
    f.set_u32(cam, "pinctrl-0", ph["mclk1"], ph["depth_active"])
    f.set_str(cam, "pinctrl-names", "default")
    port = f.add_node(cam, "port")
    ep = f.add_node(port, "endpoint")
    f.set_u64(ep, "link-frequencies", LINK_FREQ)
    f.set_u32(ep, "data-lanes", 1, 2)
    f.set_u32(ep, "phandle", ph["hi556_ep"])
    return ep


def write_camss_ep(f, ph, cam_ep_off):
    """camss port@0（CSIPHY0）加 endpoint，并与 Hi556 endpoint 互连。"""
    port0 = f.off(P_CSIPHY0)
    ep = f.add_node(port0, "endpoint")
    f.set_u32(ep, "clock-lanes", 7)      # Qualcomm 约定：clock lane 由驱动/UMD 指定
    f.set_u32(ep, "data-lanes", 0, 1)    # camss 侧用 0-based 物理 lane（与 ov8856/ov13b10 相同写法）
    f.set_u32(ep, "bus-type", 4)         # V4L2_FWNODE_BUS_TYPE_CSI2_DPHY
    f.set_u32(ep, "remote-endpoint", ph["hi556_ep"])
    f.set_u32(ep, "phandle", ph["csiphy0_ep"])
    f.set_u32(cam_ep_off, "remote-endpoint", ph["csiphy0_ep"])


# ---------------------------------------------------------------- 文本增补（dtc 路线）

def _tabs(line):
    return len(line) - len(line.lstrip("\t"))


def _find_open(lines, needle, start=0):
    for i in range(start, len(lines)):
        if lines[i].strip() == needle.strip():
            return i
    raise VerifyError("node not found: %r" % needle)


def _find_close(lines, open_idx):
    ind = _tabs(lines[open_idx])
    for i in range(open_idx + 1, len(lines)):
        s = lines[i].rstrip("\n")
        if _tabs(s) == ind and s.strip() == "};":
            return i
    raise VerifyError("closing brace not found for line %d" % open_idx)


def _find_open_by_prop(lines, prop, start=0):
    for i in range(start, len(lines)):
        if prop in lines[i]:
            ind = _tabs(lines[i])
            for j in range(i - 1, -1, -1):
                if _tabs(lines[j]) < ind and lines[j].rstrip("\n").strip().endswith("{"):
                    return j
            raise VerifyError("enclosing node not found for %r" % prop)
    raise VerifyError("property not found: %r" % prop)


def _insert_subtree(lines, parent_open, block, before_close=False):
    """block 为无缩进的子树行列表；按 parent 缩进 +1 tab 插入。"""
    ind = "\t" * (_tabs(lines[parent_open]) + 1)
    body = [ind + ln + "\n" if ln else "\n" for ln in block]
    close = _find_close(lines, parent_open)
    pos = close if before_close else close + 1
    if not before_close and pos < len(lines) and lines[pos].strip() == "":
        pos += 1
    lines.insert(pos, "\n" if before_close else "")
    for i, ln in enumerate(body):
        lines.insert(pos + (0 if before_close else 1) + i, ln)


def _blocks(ph, stage=2):
    ldo2 = [
        "ldo2 {",
        '\tregulator-name = "vreg_l2c_1p2";',
        "\tregulator-min-microvolt = <0x124f80>;",
        "\tregulator-max-microvolt = <0x13e5c0>;",
        "\tregulator-initial-mode = <0x03>;",
        "\tphandle = <%s>;" % hex(ph["ldo2"]),
        "};",
    ]
    cam = [
        "camera@20 {",
        '\tcompatible = "hynix,hi556";',
        "\treg = <0x20>;",
        "\tavdd-supply = <%s>;" % hex(ph["l3p"]),
        "\tdovdd-supply = <0x13b>;",
        "\tdvdd-supply = <%s>;" % hex(ph["ldo2"]),
        "\tclocks = <0xd4 %s>;" % hex(CAMCC_CLK_ID),
        '\tclock-names = "clk";',
        "\tassigned-clocks = <0xd4 %s>;" % hex(CAMCC_CLK_ID),
        "\tassigned-clock-rates = <%s>;" % hex(MCLK_RATE),
        "\treset-gpios = <0x3a %s 0x01>;" % hex(GPIO_RESET),
        "\tpinctrl-0 = <%s %s>;" % (hex(ph["mclk1"]), hex(ph["depth_active"])),
        '\tpinctrl-names = "default";',
        "\tport {",
        "\t\tendpoint {",
        "\t\t\tlink-frequencies = /bits/ 64 <%s>;" % hex(LINK_FREQ),
        "\t\t\tdata-lanes = <0x01 0x02>;",
        "\t\t\tphandle = <%s>;" % hex(ph["hi556_ep"]),
    ] + (["\t\t\tremote-endpoint = <%s>;" % hex(ph["csiphy0_ep"])] if stage >= 2 else []) + [
        "\t\t};",
        "\t};",
        "};",
    ]
    return ldo2, cam


def insert_dts_text(lines, ph, stage):
    ldo2, cam = _blocks(ph, stage)
    # ldo2：紧跟在 regulators-1/ldo1 之后
    r1 = _find_open(lines, "regulators-1 {")
    ldo1 = _find_open(lines, "ldo1 {", r1)
    _insert_subtree(lines, ldo1, ldo2)
    # pm8008 ldo3 加 phandle（已有节点，仅加一个属性）
    ldo3 = _find_open_by_prop(lines, 'regulator-name = "vreg_l3p";')
    _insert_subtree(lines, ldo3, ["phandle = <%s>;" % hex(ph["l3p"])],
                    before_close=True)
    # pinctrl
    mclk3 = _find_open(lines, "cam-mclk3-default-state {")
    _insert_subtree(lines, mclk3, [
        "cam-mclk1-default-state {",
        '\tpins = "gpio%d";' % GPIO_MCLK,
        '\tfunction = "cam_mclk";',
        "\tdrive-strength = <0x04>;",
        "\tbias-disable;",
        "\tphandle = <%s>;" % hex(ph["mclk1"]),
        "};",
        "",
        "camera-depth-active-state {",
        '\tpins = "gpio%d";' % GPIO_RESET,
        '\tfunction = "gpio";',
        "\tdrive-strength = <0x02>;",
        "\tbias-disable;",
        "\tphandle = <%s>;" % hex(ph["depth_active"]),
        "};",
    ])
    # Hi556 传感器
    cci0 = _find_open(lines, "cci@ac4f000 {")
    bus1 = _find_open(lines, "i2c-bus@1 {", cci0)
    _insert_subtree(lines, bus1, cam, before_close=True)
    # camss port@0
    if stage >= 2:
        camss = _find_open(lines, "camss@ac6a000 {")
        port0 = _find_open(lines, "port@0 {", camss)
        _insert_subtree(lines, port0, [
            "endpoint {",
            "\tclock-lanes = <0x07>;",
            "\tdata-lanes = <0x00 0x01>;",
            "\tbus-type = <0x04>;",
            "\tremote-endpoint = <%s>;" % hex(ph["hi556_ep"]),
            "\tphandle = <%s>;" % hex(ph["csiphy0_ep"]),
            "};",
        ], before_close=True)
    # stage1：Hi556 endpoint 没有 remote-endpoint，camss port@0 保持空，
    #          camss async notifier 不会等待 Hi556 probe（前/后摄不受影响）。


def build_dtc(base_path, out_path, ph, stage, tmpdir, emit_dts=None):
    dts = os.path.join(tmpdir, "joint-base.dts")
    patched = os.path.join(tmpdir, "joint-hi556.dts")
    dtb = os.path.join(tmpdir, "joint-hi556.dtb")
    subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, base_path],
                   check=True, capture_output=True, text=True)
    lines = open(dts).readlines()
    insert_dts_text(lines, ph, stage)
    open(patched, "w").writelines(lines)
    if emit_dts:
        shutil.copyfile(patched, emit_dts)
    cp = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", dtb, patched],
                        capture_output=True, text=True)
    if cp.returncode:
        raise VerifyError("dtc 编译失败:\n" + cp.stderr)
    base = load(base_path)
    new = load(dtb)
    restored = restore_base_props(base, new)
    with open(out_path, "wb") as f:
        f.write(new.tobytes())
    return restored, [l for l in cp.stderr.splitlines()
                      if "unique_unit_address" not in l and "avoid_unnecessary" not in l]


# ---------------------------------------------------------------- DTBO overlay 路线

def dtso_text(ph, stage):
    frag = []

    def add(i, target, body):
        frag.append("""\tfragment@%d {
		target-path = "%s";
		__overlay__ {
%s
		};
	};
""" % (i, target, "\n".join("\t\t\t" + l if l else "" for l in body)))

    add(0, "/soc@0/rsc@18200000/regulators-1", [
        "vreg_l2c_1p2: ldo2 {",
        '\tregulator-name = "vreg_l2c_1p2";',
        "\tregulator-min-microvolt = <1200000>;",
        "\tregulator-max-microvolt = <1304000>;",
        "\tregulator-initial-mode = <3>;",
        "};",
    ])
    add(1, P_PM8008_L3P, ["phandle = <%s>;" % hex(ph["l3p"])])
    add(2, P_PINCTRL, [
        "cam_mclk1_default: cam-mclk1-default-state {",
        '\tpins = "gpio%d";' % GPIO_MCLK,
        '\tfunction = "cam_mclk";',
        "\tdrive-strength = <4>;",
        "\tbias-disable;",
        "};",
        "",
        "camera_depth_active: camera-depth-active-state {",
        '\tpins = "gpio%d";' % GPIO_RESET,
        '\tfunction = "gpio";',
        "\tdrive-strength = <2>;",
        "\tbias-disable;",
        "};",
    ])
    cam_body = [
        "camera@20 {",
        '\tcompatible = "hynix,hi556";',
        "\treg = <0x20>;",
        "\tavdd-supply = <%s>;" % hex(ph["l3p"]),
        "\tdovdd-supply = <0x13b>;",
        "\tdvdd-supply = <&vreg_l2c_1p2>;",
        "\tclocks = <0xd4 %s>;" % hex(CAMCC_CLK_ID),
        '\tclock-names = "clk";',
        "\tassigned-clocks = <0xd4 %s>;" % hex(CAMCC_CLK_ID),
        "\tassigned-clock-rates = <%s>;" % hex(MCLK_RATE),
        "\treset-gpios = <0x3a %s 1>;" % hex(GPIO_RESET),
        "\tpinctrl-0 = <&cam_mclk1_default &camera_depth_active>;",
        '\tpinctrl-names = "default";',
        "\tport {",
    ]
    if stage >= 2:
        cam_body += [
            "\t\thi556_ep: endpoint {",
            "\t\t\tlink-frequencies = /bits/ 64 <%s>;" % LINK_FREQ,
            "\t\t\tdata-lanes = <1 2>;",
            "\t\t\tremote-endpoint = <&csiphy0_ep>;",
            "\t\t};",
        ]
    else:
        cam_body += [
            "\t\tendpoint {",
            "\t\t\tlink-frequencies = /bits/ 64 <%s>;" % LINK_FREQ,
            "\t\t\tdata-lanes = <1 2>;",
            "\t\t};",
        ]
    cam_body += ["\t};", "};"]
    add(3, P_BUS1, cam_body)
    if stage >= 2:
        add(4, P_CSIPHY0, [
            "csiphy0_ep: endpoint {",
            "\tclock-lanes = <7>;",
            "\tdata-lanes = <0 1>;",
            "\tbus-type = <4>;",
            "\tremote-endpoint = <&hi556_ep>;",
            "};",
        ])
    return """/dts-v1/;
/plugin/;

/* 由 hi556-build-dtb.py --method dtbo 生成；离线合并（fdtoverlay），非运行时 overlay */
/ {
%s};
""" % "".join(frag)


def build_dtbo(base_path, out_path, ph, stage, tmpdir, emit_dtso=None):
    src = os.path.join(tmpdir, "hi556-camera.dtso")
    overlay = os.path.join(tmpdir, "hi556-camera.dtbo")
    merged = os.path.join(tmpdir, "merged.dtb")
    text = dtso_text(ph, stage)
    if emit_dtso:
        open(emit_dtso, "w").write(text)
    open(src, "w").write(text)
    cp = subprocess.run(["dtc", "-@", "-I", "dts", "-O", "dtb", "-o", overlay, src],
                        capture_output=True, text=True)
    if cp.returncode:
        raise VerifyError("dtbo 编译失败:\n" + cp.stderr)
    cp = subprocess.run(["fdtoverlay", "-i", base_path, "-o", merged, overlay],
                        capture_output=True, text=True)
    if cp.returncode:
        raise VerifyError("fdtoverlay 失败:\n" + cp.stderr)
    base = load(base_path)
    new = load(merged)
    # fdtoverlay 会把 overlay 的 /__symbols__ 等辅助节点也合并进基树；基树原本没有
    # （且 boot 不需要），删除以保持“只增计划内节点”。
    for aux in ("/__symbols__", "/__fixups__", "/__local_fixups__"):
        try:
            new.del_node(new.off(aux))
        except KeyError:
            pass
    # fdtoverlay 会给 overlay 内节点重分配 phandle（含“已有节点上新增的 phandle”），
    # 因此 ldo3 的 phandle 会被改写；用合并后的真实值回填 avdd-supply。
    l3p_ph = new.get_u32(new.off(P_PM8008_L3P), "phandle")
    cam_off = new.off(P_CAM)
    if new.get_u32(cam_off, "avdd-supply") != l3p_ph:
        new.set_u32(cam_off, "avdd-supply", l3p_ph)
    restored = restore_base_props(base, new)
    with open(out_path, "wb") as f:
        f.write(new.tobytes())
    return restored, []


# ---------------------------------------------------------------- 校验

def verify(base_path, new_path, stage, quiet=False):
    base = load(base_path)
    new = load(new_path)
    cb = new.check_full()
    if cb:
        raise VerifyError("fdt_check_full failed: %s" % errname(cb))

    an, rn, ap, rp, ch = diff(base, new)
    if set(an) != set(ALLOWED_ADDED_NODES[stage]):
        raise VerifyError("新增节点与计划不符:\n  实际: %s\n  期望: %s"
                          % (sorted(set(an) - set(ALLOWED_ADDED_NODES[stage])),
                             sorted(set(ALLOWED_ADDED_NODES[stage]) - set(an))))
    if rn:
        raise VerifyError("有节点被删除: %s" % rn)
    if rp:
        raise VerifyError("有属性被删除: %s" % rp)
    if ch:
        raise VerifyError("有属性被改动: %s" % ch)
    expect_props = {(p, q) for p, qs in ALLOWED_ADDED_PROPS.items() for q in qs}
    if set(ap) != expect_props:
        raise VerifyError("额外属性与计划不符: 实际 %s 期望 %s" % (ap, sorted(expect_props)))

    d = new.dump()
    for p in ALLOWED_ADDED_NODES[stage]:
        if p not in d:
            raise VerifyError("缺少节点 " + p)

    # ---- ldo2 ----
    ldo2 = d[P_LDO2]
    pstr(ldo2, "regulator-name", "vreg_l2c_1p2")
    p32(ldo2, "regulator-min-microvolt", 1200000)
    p32(ldo2, "regulator-max-microvolt", 1304000)
    p32(ldo2, "regulator-initial-mode", 3)
    ph_ldo2 = cell(ldo2, "phandle")

    # ---- pinctrl ----
    m = d[P_MCLK1]
    pstr(m, "pins", "gpio%d" % GPIO_MCLK)
    pstr(m, "function", "cam_mclk")
    p32(m, "drive-strength", 4)
    if d[P_MCLK1].get("bias-disable") != b"":
        raise VerifyError("cam-mclk1 缺 bias-disable")
    ph_mclk = cell(m, "phandle")
    r = d[P_DEPTH]
    pstr(r, "pins", "gpio%d" % GPIO_RESET)
    pstr(r, "function", "gpio")
    p32(r, "drive-strength", 2)
    if r.get("bias-disable") != b"":
        raise VerifyError("camera-depth 缺 bias-disable")
    ph_rst = cell(r, "phandle")

    # ---- Hi556 节点 ----
    cam = d[P_CAM]
    pstr(cam, "compatible", "hynix,hi556")
    p32(cam, "reg", 0x20)
    pstr(cam, "clock-names", "clk")
    p32(cam, "assigned-clock-rates", MCLK_RATE)
    p32(cam, "clocks", cell(d[P_CAMCC], "phandle"))
    p32(cam, "clocks", CAMCC_CLK_ID, 1)
    p32(cam, "assigned-clocks", cell(d[P_CAMCC], "phandle"))
    p32(cam, "reset-gpios", cell(d[P_TLMM], "phandle"))
    p32(cam, "reset-gpios", GPIO_RESET, 1)
    p32(cam, "reset-gpios", 1, 2)
    pstr(cam, "pinctrl-names", "default")
    p32(cam, "pinctrl-0", ph_mclk)
    p32(cam, "pinctrl-0", ph_rst, 1)
    # supply 解析到正确的 regulator
    want_sup = {"dovdd-supply": "vreg_l1c_1p8", "avdd-supply": "vreg_l3p",
                "dvdd-supply": "vreg_l2c_1p2"}
    for prop, rname in want_sup.items():
        ph = cell(cam, prop)
        target = resolve_phandle(d, ph)
        if not target:
            raise VerifyError("%s 的 phandle %#x 无对应节点" % (prop, ph))
        if sval(d[target], "regulator-name") != rname:
            raise VerifyError("%s -> %s（期望 %s）" % (prop, target, rname))

    # ---- Hi556 endpoint ----
    ep = d[P_CAM_EP]
    if int.from_bytes(ep["link-frequencies"], "big") != LINK_FREQ:
        raise VerifyError("link-frequencies 不是 437MHz")
    p32(ep, "data-lanes", 1)
    p32(ep, "data-lanes", 2, 1)
    ph_hi_ep = cell(ep, "phandle")
    if stage >= 2:
        if cell(ep, "remote-endpoint") != cell(d[P_CSIPHY0_EP], "phandle"):
            raise VerifyError("Hi556 endpoint remote-endpoint 不指向 csiphy0 endpoint")
        cs = d[P_CSIPHY0_EP]
        p32(cs, "clock-lanes", 7)
        p32(cs, "data-lanes", 0)
        p32(cs, "data-lanes", 1, 1)
        p32(cs, "bus-type", 4)
        if cell(cs, "remote-endpoint") != ph_hi_ep:
            raise VerifyError("csiphy0 endpoint remote-endpoint 不指向 Hi556 endpoint")

    # phandle 唯一性
    seen = {}
    for path, props in d.items():
        if "phandle" in props:
            v = cell(props, "phandle")
            if v in seen:
                raise VerifyError("phandle %#x 重复: %s / %s" % (v, seen[v], path))
            seen[v] = path

    # ---- 基线不变量 ----
    for path in ("/fingerprint", "/bcm4775", "/reserved-memory/fastrpc"):
        if path not in d:
            raise VerifyError("基线节点丢失: " + path)
    l10c = d[P_L10C]
    if l10c.get("regulator-min-microvolt") != L10C_MIN or \
       l10c.get("regulator-max-microvolt") != L10C_MIN:
        raise VerifyError("L10C 电压属性被 dtc 往返破坏（必须为 4 字节 %s）"
                          % L10C_MIN.hex())
    vmids = d["/soc@0/remoteproc@5c00000/glink-edge/fastrpc"].get("qcom,vmids")
    if vmids is None:
        raise VerifyError("fastrpc qcom,vmids 丢失")

    if not quiet:
        print("== 校验通过 ==")
        print("  新增节点 %d 个 / 新增属性 %d 个 / 删除 0 / 改动 0"
              % (len(an), len(ap)))
        for p in an:
            print("   + %s" % p)
        if ap:
            for p, q in ap:
                print("   + %s %s = <%#x>" % (p, q, cell(d[p], q)))
        print("  ldo2: 1200000-1304000uV, mode HPM")
        print("  Hi556: CCI0 i2c-bus@1 / 0x20 / MCLK1 19.2MHz / reset gpio%d ACTIVE_LOW"
              % GPIO_RESET)
        print("  供电: dovdd=vreg_l1c_1p8 avdd=vreg_l3p dvdd=vreg_l2c_1p2")
        if stage >= 2:
            print("  camss port@0: CSIPHY0, data-lanes <0 1> / D-PHY, 对端 Hi556 <1 2>")
        else:
            print("  stage1：未接 camss port@0（camss async notifier 不依赖 Hi556 probe）")
    return dict(added_nodes=an, added_props=ap, sha256=sha256(new_path))


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(
        description="构建/校验 Hi556 景深相机联合 DTB（elish/CSOT，只读基线，不写 boot）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default=DEFAULT_BASE, help="基线联合 DTB")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出 DTB")
    ap.add_argument("--method", choices=("fdt", "dtc", "dtbo"), default="fdt",
                    help="构建方式（默认 fdt：libfdt 直接增补，不经文本往返）")
    ap.add_argument("--stage", type=int, choices=(1, 2), default=2,
                    help="1=仅 ldo2+pinctrl+CCI0 传感器节点；2=再连 camss port@0（默认）")
    ap.add_argument("--allow-other-base", action="store_true",
                    help="允许基线 DTB 不是已知 sha256（仍会做全部校验）")
    ap.add_argument("--emit-dts", help="dtc 方式：把增补后的完整 DTS 保存到此路径")
    ap.add_argument("--emit-dtso", help="dtbo 方式：把 overlay 源保存到此路径")
    ap.add_argument("--verify-combined", action="store_true",
                    help="额外运行包内 verify-combined-dtb.sh")
    ap.add_argument("--check-only", metavar="DTB", help="只校验已有 DTB（基线用 --base）")
    ap.add_argument("--fix-roundtrip", metavar="DTB",
                    help="修复手工 dtc 往返编出的 DTB（还原 dtc 破坏的属性）后写到 --out 并校验")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if a.check_only:
        r = verify(a.base, a.check_only, a.stage, a.quiet)
        print("sha256:", r["sha256"])
        return 0

    if a.fix_roundtrip:
        base = load(a.base)
        new = load(a.fix_roundtrip)
        restored = restore_base_props(base, new)
        with open(a.out, "wb") as fh:
            fh.write(new.tobytes())
        if not a.quiet:
            print("[fixup] 还原属性 %d 个:" % len(restored))
            for p, q in restored:
                print("   %s %s" % (p, q))
        r = verify(a.base, a.out, a.stage, a.quiet)
        print("输出: %s" % a.out)
        print("sha256: %s" % r["sha256"])
        return 0

    if not os.path.isfile(a.base):
        print("找不到基线 DTB: %s" % a.base, file=sys.stderr)
        return 2
    bs = sha256(a.base)
    if bs == MERGED_SHA256:
        print("基线已是含 Hi556 的合并 DTB，无需再生成补丁。")
        if a.out and os.path.abspath(a.out) != os.path.abspath(a.base):
            shutil.copyfile(a.base, a.out)
            print("copied:", a.out)
        return 0
    if bs != BASE_SHA256:
        msg = ("基线 DTB sha256 与已知值不同:\n  实际: %s\n  期望: %s\n"
               "（若确实要用其它基线，加 --allow-other-base；路径可能与预期不符时校验会报错）"
               % (bs, BASE_SHA256))
        if not a.allow_other_base:
            print(msg, file=sys.stderr)
            return 2
        print("[warn] " + msg, file=sys.stderr)

    tmpdir = tempfile.mkdtemp(prefix="hi556-dtb-")
    try:
        if a.method == "fdt":
            f = load(a.base)
            ep = write_fdt_nodes(f, PH)
            if a.stage >= 2:
                write_camss_ep(f, PH, ep)
            with open(a.out, "wb") as fh:
                fh.write(f.tobytes())
            restored = []
        elif a.method == "dtc":
            restored, warns = build_dtc(a.base, a.out, PH, a.stage, tmpdir,
                                        emit_dts=a.emit_dts)
            if warns and not a.quiet:
                print("[dtc] 过滤后警告 %d 条（%s）"
                      % (len(warns), "均为基线反编译既有的 unit-address/clocks 警告"
                         if all("clocks_property" in w or "Warning" not in w for w in warns) else "见上"))
        else:
            restored, _ = build_dtbo(a.base, a.out, PH, a.stage, tmpdir,
                                     emit_dtso=a.emit_dtso)
            if not a.quiet:
                print("[dtbo] overlay 已离线合并（内核无 CONFIG_OF_OVERLAY，非运行时加载）")

        if restored and not a.quiet:
            print("[fixup] 已还原 dtc/overlay 合并误改的属性 %d 个:" % len(restored))
            for p, q in restored:
                print("   %s %s" % (p, q))

        r = verify(a.base, a.out, a.stage, a.quiet)
        print("输出: %s" % a.out)
        print("sha256: %s" % r["sha256"])

        if a.verify_combined and os.path.isfile(VERIFY_SCRIPT):
            print("== 包内 verify-combined-dtb.sh ==")
            cp = subprocess.run(["bash", VERIFY_SCRIPT, a.out])
            if cp.returncode:
                print("verify-combined-dtb.sh 失败", file=sys.stderr)
                return 1
        return 0
    except VerifyError as e:
        print("[FAIL] %s" % e, file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
