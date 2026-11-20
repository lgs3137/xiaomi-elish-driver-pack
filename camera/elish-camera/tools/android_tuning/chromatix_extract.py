#!/usr/bin/env python3
"""QTI Chromatix tuning bin（com.qti.tuned.*.bin）只读解析器 —— 2026-11-20 逆向。

容器（与 sensormodule .bin 同族，见 elish-camera/docs/evidence/chromatix_parse.py）：
  +0x00 char[20] "QTI Chromatix Header" (+4B 保留)
  +0x1c u32 total_size;  +0x20 u32 version=2
  +0x28 char[32] "Parameter Parser V2.0.0 (...)";  +0x98 u32 sectionTableOff, u32 sectionCount
  section table: {u64 id, u64 fileOff, u64 size} * count
  section[0] = 节点表: +0x00 u64 <未知计数>，从 +0x08 起每记录 0x48 字节:
      char name[40]（24 字节 + 两个 u64 里的续接字符）；u64 0xffffffff 标记；
      u64 dataOff（相对 section[1] 基址）；u64 dataSize；u64 nodeIdx
  section[1] = 数据段（float32 数组等）；section[2] = 小目录。

本脚本提取（全部只读，不写镜像）：
  * nodes 清单     -> nodes_<tag>.csv
  * LSC 4ch x 13x17（mod_lsc34_cct_data / golden / lsc40 首块） -> lsc_<tag>.json/.csv
  * CCM 3x3（mod_cc13_*/mod_cc12_* cct_data，每条 18 float = [cct_lo,0,cct_hi,0]+9 矩阵+5 附加）
  * gamma（mod_gamma16_channel_data，3 通道 x 64 项 LUT）
  * AWB/AF 尾部模块参数（refPtV1 / bgStatsConfigV1 / initDataV1 / flashWV1 ...）原始 + 可解释值
  * 模块清单汇总 tuning_summary.json
"""
import struct, sys, os, json, csv, collections

MESH_W, MESH_H = 17, 13
MESH_N = MESH_W * MESH_H  # 221


def load(path):
    d = open(path, 'rb').read()
    assert d[:20] == b'QTI Chromatix Header', 'not a chromatix bin: %r' % d[:24]
    total = struct.unpack_from('<I', d, 0x1c)[0]
    ver = struct.unpack_from('<I', d, 0x20)[0]
    st_off, st_cnt = struct.unpack_from('<II', d, 0x98)
    secs = [struct.unpack_from('<QQQ', d, st_off + i * 24) for i in range(st_cnt)]
    recs = []
    o = secs[0][1] + 8
    end = secs[0][1] + secs[0][2]
    while o + 0x48 <= end:
        raw = d[o:o + 40].split(b'\0')[0]
        if not raw or not all(32 <= b < 127 for b in raw):
            break
        doff, dsz, idx = struct.unpack_from('<3Q', d, o + 0x30)
        recs.append(dict(name=raw.decode(), doff=doff, dsz=dsz, idx=idx, off=o))
        o += 0x48
    return dict(raw=d, total=total, ver=ver, secs=secs, D=secs[1][1],
                recs=recs, byidx={r['idx']: r for r in recs}, path=path)


def blob(m, r):
    return m['raw'][m['D'] + r['doff']: m['D'] + r['doff'] + r['dsz']]


def f32(b, n=None):
    n = len(b) // 4 if n is None else n
    return list(struct.unpack('<%df' % n, b[:n * 4]))


def parse_lsc34(m):
    """mod_lsc34_*_cct_data 0xdf0=892 float:
       [cct_lo,0,cct_hi,0] + 4ch x (221 float + 1 float 0 分隔)。"""
    out = []
    for r in m['recs']:
        if r['name'] in ('mod_lsc34_cct_data', 'mod_lsc34_golden_cct_data'):
            f = f32(blob(m, r))
            if len(f) < 4 + 4 * 222:
                continue
            chans = []
            for c in range(4):
                base = 4 + c * 222
                chans.append(f[base:base + MESH_N])
            out.append(dict(node=r['name'], idx=r['idx'], cct=[f[0], f[2]],
                            channels=chans, golden=r['name'].endswith('golden_cct_data')))
    return out


def parse_lsc40(m):
    """mod_lsc40_cct_data：0x2a60=2712 float。首个 entry = [cct_lo,0,cct_hi,0]+4ch x (221+1)。
       其余为同一 tree 里的附加模式数据（未完全解码，按 entry 原样保存前 892 float）。"""
    out = []
    for r in m['recs']:
        if r['name'] != 'mod_lsc40_cct_data':
            continue
        f = f32(blob(m, r))
        if len(f) < 4 + 4 * 222:
            continue
        chans = [f[4 + c * 222: 4 + c * 222 + MESH_N] for c in range(4)]
        out.append(dict(node=r['name'], idx=r['idx'], cct=[f[0], f[2]],
                        channels=chans, raw_head=f[:892], nfloat=len(f)))
    return out


def parse_ccm(m):
    """mod_cc13/cc12_*_cct_data -> 每 18 float 一条: cct_lo,0,cct_hi,0, 9x3x3, 5 附加(全 0)。"""
    out = []
    for r in m['recs']:
        if r['name'] not in ('mod_cc13_cct_data', 'mod_cc12_cct_data'):
            continue
        f = f32(blob(m, r))
        if len(f) % 18:
            continue
        for i in range(0, len(f), 18):
            e = f[i:i + 18]
            mat = [e[4:7], e[7:10], e[10:13]]
            out.append(dict(node=r['name'], idx=r['idx'], entry=i // 18,
                            cct=[e[0], e[2]], m3x3=mat, extra=e[13:18]))
    return out


def parse_gamma(m):
    """mod_gamma16_channel_data 0x330=204 float：头部 3 float（计数/版本），随后 3 个 64 项 LUT。"""
    out = []
    for r in m['recs']:
        if r['name'] != 'mod_gamma16_channel_data':
            continue
        f = f32(blob(m, r))
        idxs = [i for i in (3, 71, 139) if i + 64 <= len(f)]
        luts = [f[i:i + 64] for i in idxs]
        out.append(dict(node=r['name'], idx=r['idx'], head=f[:3], luts=luts))
    return out


AWB_NODES = ['refPtV1', 'AWBExtensionParam', 'custRefPtV1', 'flashWV1', 'initDataV1',
             'bgStatsConfigV1', 'Arbitration', 'SAGenV1DataArray', 'SASpatialGenV1DataArray',
             'DAV1', 'AFDTuningData', 'SFDistWVV1', 'AFExtension', 'Touch', 'aecMultiCamSync']


def parse_awb(m):
    out = {}
    for r in m['recs']:
        if r['name'] not in AWB_NODES:
            continue
        b = blob(m, r)
        us = struct.unpack('<%dQ' % (len(b) // 8), b[:len(b) // 8 * 8])
        # 序列化流 = u64 子节点引用 + float32 字面量；这里保留原始 u64 与 "偶数槽 float"
        floats = [struct.unpack('<f', b[i:i + 4])[0] for i in range(0, len(b) // 4 * 4, 4)]
        literals = [floats[i] for i in range(0, len(floats), 2)]
        out[r['name']] = dict(idx=r['idx'], size=r['dsz'], u64=list(us),
                              floats_raw=floats, f32_literals=literals)
    return out


def decimate(recs, tag):
    summ = collections.Counter()
    for r in recs:
        p = r['name'].split('_')[0]
        summ[p] += 1
    return dict(nodes=len(recs), modules=dict(summ))


def main(binpath, tag, outdir):
    m = load(binpath)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, 'nodes_%s.csv' % tag), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['idx', 'record', 'name', 'file_off', 'data_off', 'data_size'])
        for r in m['recs']:
            w.writerow([r['idx'], r['off'], r['name'], hex(r['off']), hex(r['doff']), hex(r['dsz'])])
    lsc = parse_lsc34(m)
    lsc40 = parse_lsc40(m)
    ccm = parse_ccm(m)
    gam = parse_gamma(m)
    awb = parse_awb(m)
    json.dump(dict(file=binpath, total_size=m['total'], version=m['ver'],
                   sections=[[s[0], s[1], s[2]] for s in m['secs']],
                   lsc34=lsc, lsc40=lsc40),
              open(os.path.join(outdir, 'lsc_%s.json' % tag), 'w'), indent=1)
    json.dump(ccm, open(os.path.join(outdir, 'ccm_%s.json' % tag), 'w'), indent=1)
    json.dump(gam, open(os.path.join(outdir, 'gamma_%s.json' % tag), 'w'), indent=1)
    json.dump(awb, open(os.path.join(outdir, 'awb_%s.json' % tag), 'w'), indent=1)
    # CSV: 取第一个非 golden lsc34（主 LSC），4ch x 13x17
    if lsc:
        main_lsc = next((x for x in lsc if not x['golden']), lsc[0])
        with open(os.path.join(outdir, 'lsc_%s.csv' % tag), 'w', newline='') as fh:
            w = csv.writer(fh)
            w.writerow(['channel', 'row', 'col', 'gain'])
            for c, ch in enumerate(main_lsc['channels']):
                for y in range(MESH_H):
                    for x in range(MESH_W):
                        w.writerow([c, y, x, '%.6f' % ch[y * MESH_W + x]])
    # CSV: CCM
    with open(os.path.join(outdir, 'ccm_%s.csv' % tag), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['node', 'idx', 'entry', 'cct_lo', 'cct_hi'] +
                   ['m%d%d' % (i, j) for i in range(3) for j in range(3)])
        for c in ccm:
            w.writerow([c['node'], c['idx'], c['entry'], c['cct'][0], c['cct'][1]] +
                       [v for row in c['m3x3'] for v in row])
    summary = dict(file=binpath, tag=tag, sections=[[s[0], hex(s[1]), hex(s[2])] for s in m['secs']],
                   **decimate(m['recs'], tag),
                   lsc34_count=len(lsc), lsc40_count=len(lsc40),
                   ccm_entries=len(ccm), gamma_sets=len(gam), awb_nodes=sorted(awb))
    json.dump(summary, open(os.path.join(outdir, 'tuning_summary_%s.json' % tag), 'w'), indent=1)
    print('[%s] nodes=%d sections=%s' % (tag, len(m['recs']),
          [(hex(s[1]), hex(s[2])) for s in m['secs']]))
    print('  lsc34=%d lsc40=%d ccm=%d gamma=%d awb=%d' %
          (len(lsc), len(lsc40), len(ccm), len(gam), len(awb)))
    return m, lsc, lsc40, ccm, gam, awb


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description='解析本机 Android vendor 中的 com.qti.tuned.*.bin（只读，不生成/不分发数据）')
    ap.add_argument('--bins', required=True, help='包含 com.qti.tuned.*.bin 的目录（从你自己的设备只读提取）')
    ap.add_argument('--out', default='.', help='脚本输出目录（CSV/JSON，仅本地使用，不要提交）')
    a = ap.parse_args()
    # 只读取你自己设备上的文件；不随包分发任何 .bin 或解析产物。
    jobs = [('com.qti.tuned.elish_ofilm_ov13b10_wide.bin', 'wide_ov13b10'),
            ('com.qti.tuned.elish_aac_ov8856_front.bin', 'front_ov8856'),
            ('com.qti.tuned.elish_qtech_hi556_depth.bin', 'depth_hi556'),
            ('com.qti.tuned.default.bin', 'default')]
    for f, tag in jobs:
        path = os.path.join(a.bins, f)
        if not os.path.exists(path):
            print('skip (missing):', path)
            continue
        main(path, tag, a.out)
