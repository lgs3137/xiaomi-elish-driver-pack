#!/usr/bin/env python3
"""把 chromatix_extract.py / lsc_compare.py 的产物整理成 Linux 可直接消费的参数包
linux-recommended-params.json（LSC 增益网格 / CCM / gamma LUT / AWB 参考点与权重 / 初始增益）。"""
import argparse, json, os

W, H = 17, 13


def main():
    ap = argparse.ArgumentParser(description='把 chromatix_extract.py 的本地产物整理成 linux-recommended-params.json')
    ap.add_argument('--data', default='.', help='chromatix_extract.py --out 的目录')
    ap.add_argument('--out', default=None, help='输出 JSON 路径（默认 <data>/linux-recommended-params.json）')
    a = ap.parse_args()
    HERE = os.path.abspath(a.data)
    outpath = a.out or os.path.join(HERE, 'linux-recommended-params.json')
    out = dict(note='由 Android vendor com.qti.tuned.*.bin 逆向；LSC 为乘性增益(中心≈1)；'
                    'Bayer 通道顺序按 QTI 惯例 R/Gr/Gb/B。后摄优先用 EEPROM per-unit LSC（见 lsc_compare.json）。',
               cameras={})
    for tag, name in [('wide_ov13b10', 'rear_wide'), ('front_ov8856', 'front'),
                      ('depth_hi556', 'rear_depth')]:
        j = json.load(open(os.path.join(HERE, 'lsc_%s.json' % tag)))
        ccm = json.load(open(os.path.join(HERE, 'ccm_%s.json' % tag)))
        gam = json.load(open(os.path.join(HERE, 'gamma_%s.json' % tag)))
        awb = json.load(open(os.path.join(HERE, 'awb_%s.json' % tag)))
        sets = [s for s in j['lsc34'] if not s['golden']]
        golden = [s for s in j['lsc34'] if s['golden']]
        lsc_main = sets[0]
        ccm_real = [e for e in ccm if not (abs(e['m3x3'][0][0] - 1) < 1e-6 and
                                           abs(e['m3x3'][1][1] - 1) < 1e-6 and
                                           abs(e['m3x3'][2][2] - 1) < 1e-6)]
        g = gam[0] if gam else None
        cam = dict(lsc=dict(node=lsc_main['node'], idx=lsc_main['idx'], cct=lsc_main['cct'],
                            grid='4ch x 13(row) x 17(col)', channels=lsc_main['channels'],
                            variants=[dict(idx=s['idx'], cct=s['cct'],
                                           corner=s['channels'][0][0]) for s in sets]),
                   lsc_golden_q10=dict(node=golden[0]['node'], idx=golden[0]['idx'],
                                       channels=golden[0]['channels']) if golden else None,
                   ccm=dict(entries=[dict(cct=e['cct'], m3x3=e['m3x3'], node=e['node'], idx=e['idx'])
                                     for e in ccm_real]),
                   gamma=dict(luts=g['luts']) if g else None)
        # AWB 可解释字段
        def literals(node):
            """序列化流里 u64 子节点引用会被当作 float32 读成 <1e-40 的 denormal，
            真正的字面量是 1e-4..1e5 的实数；按原顺序过滤即得字面量序列。"""
            v = awb.get(node)
            if not v:
                return None
            return [x for x in v['floats_raw'] if 1e-4 <= abs(x) <= 1e5]
        ref = None
        vals = [v for v in (literals('refPtV1') or []) if 1e-4 < abs(v) < 10]
        if vals:
            ref = [dict(rg=round(vals[i], 5), bg=round(vals[i + 1], 5))
                   for i in range(0, len(vals) - 1, 2)]
        bgv = [v for v in (literals('bgStatsConfigV1') or []) if 1e-4 < abs(v) < 10]
        inv = literals('initDataV1') or []
        cam['awb'] = dict(
            ref_points_rg_bg=ref,
            bg_stats_weights=bgv[:3],
            bg_stats_extra=bgv[3:],
            init_gains=(inv[:3] if len(inv) >= 3 else None),
            init_cct=(inv[3] if len(inv) >= 4 else None),
            flash_wv=(literals('flashWV1') or None))
        out['cameras'][name] = cam
    json.dump(out, open(outpath, 'w'), indent=1)
    for k, c in out['cameras'].items():
        print('%s: lsc idx=%d variants=%d ccm_real=%d gamma_luts=%s awb_ref=%s bg=%s init=%s' % (
            k, c['lsc']['idx'], len(c['lsc']['variants']), len(c['ccm']['entries']),
            (len(c['gamma']['luts']) if c['gamma'] else 0),
            (len(c['awb']['ref_points_rg_bg']) if c['awb']['ref_points_rg_bg'] else 0),
            c['awb']['bg_stats_weights'], (c['awb']['init_gains'], c['awb']['init_cct'])))


if __name__ == '__main__':
    main()
