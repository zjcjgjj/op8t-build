#!/usr/bin/env python3
"""校验一个 kernel_Image 能否让 OnePlus 8T 的原厂 vendor 模块正常加载。

背景（真机实测 + 逐字节证据）：
  * 官方 vbmeta + Magisk 修补 boot（只改 ramdisk，原厂内核不变）→ 能进系统
  * 官方 vbmeta + 换掉内核的 boot                              → 回退 recovery
  结论：bootloader 不校验 boot 内容，差异只在内核本身。

根因：原厂内核 IKCONFIG 是 CONFIG_MODVERSIONS=y，vermagic 里带 "modversions"；
      vendor 分区所有 .ko 也带这个标记。自编译内核若关掉 MODVERSIONS，
      vermagic 变成 "... mod_unload aarch64"，内核 same_magic() 拒绝加载
      全部 vendor 模块（显示/触控/wlan/相机/音频），Android init 起不来。

用法：
  python check_kernel.py kernel_Image                  # 校验单个内核
  python check_kernel.py kernel_Image --compare       # 顺带和原厂内核对比
"""
import argparse
import os
import re
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
STOCK_BOOT = os.path.join(HERE, 'stock_boot_KB2000_14.0.0.602.img')
STOCK_CFG = os.path.join(HERE, 'stock_config.txt')
KSIZE = 47511568
PAGE = 4096
WANT_VERMAGIC = b'4.19.157-perf+ SMP preempt mod_unload modversions aarch64'


def parse_config(data):
    """从内核的 IKCFG_ST..IKCFG_ED 段解出内嵌 .config。"""
    i = data.find(b'IKCFG_ST')
    j = data.find(b'IKCFG_ED')
    if i < 0 or j <= i:
        return None
    try:
        raw = zlib.decompress(data[i + 8:j], 16 + zlib.MAX_WBITS)
    except Exception:
        return None
    cfg = {}
    for line in raw.decode('utf-8', 'replace').splitlines():
        line = line.strip()
        if line.startswith('CONFIG_') and '=' in line:
            k, v = line.split('=', 1)
            cfg[k] = v
        elif line.startswith('# CONFIG_') and ' is not set' in line:
            cfg[line.split()[1]] = 'n'
    return cfg


def inspect(name, data, compare=False):
    print('\n===== %s  (%d bytes) =====' % (name, len(data)))
    ok = True

    # ARM64 Image 头
    magic = data[56:60]
    print(' ARM64 magic@56      : %s  %s'
          % (magic, 'OK' if magic == b'ARMd' else 'FAIL'))
    ok &= magic == b'ARMd'

    m = re.search(rb'Linux version ([^\x00\s]+)', data)
    print(' Linux version       : %s' % (m.group(1).decode() if m else 'N/A'))

    # vermagic —— 决定性检查
    vms = sorted(set(re.findall(rb'4\.19\.[0-9]+-perf\+ SMP [ -~]{0,90}', data)))
    print(' vermagic 候选       :')
    for v in vms[:5]:
        print('   %s' % v.decode('ascii', 'replace'))
    hit = WANT_VERMAGIC in data
    print(' 含原厂 modversions  : %s  %s' % (hit, 'OK' if hit else '*** FAIL ***'))
    if not hit:
        print('   → vendor 分区所有 .ko 会加载失败，刷入必定回退 recovery')
        print('   → 重编时设 CONFIG_MODVERSIONS=y，不要被 olddefconfig 改回 n')
    ok &= hit

    # IKCONFIG
    cfg = parse_config(data)
    if cfg:
        print(' IKCONFIG            : %d 项' % len(cfg))
        for k in ['CONFIG_MODVERSIONS', 'CONFIG_MODULE_SIG',
                  'CONFIG_MODULE_SIG_FORCE', 'CONFIG_MODULES',
                  'CONFIG_KSU', 'CONFIG_KSU_SYSCALL_TABLE_HOOK',
                  'CONFIG_LOCALVERSION', 'CONFIG_IKCONFIG']:
            print('   %-38s %s' % (k, cfg.get(k, '<缺>')))
        if not hit and cfg.get('CONFIG_MODVERSIONS') == 'n':
            print('   已确认：CONFIG_MODVERSIONS=n 就是根因')
    else:
        print(' IKCONFIG            : 未内嵌（无法进一步比对）')

    # KSU 集成痕迹
    print(' KSU 标记            : KernelSU=%d  ksu_=%d  ksud=%d'
          % (data.count(b'KernelSU'), data.count(b'ksu_'), data.count(b'ksud')))

    # 与原厂对比
    if compare and os.path.isfile(STOCK_BOOT):
        stock = open(STOCK_BOOT, 'rb').read()[PAGE:PAGE + KSIZE]
        scfg = parse_config(stock) or {}
        print('\n 与原厂内核对比:')
        svm = re.findall(rb'4\.19\.[0-9]+-perf\+ SMP [ -~]{0,90}', stock)
        print('   原厂 vermagic : %s' % (svm[0].decode('ascii', 'replace') if svm else 'N/A'))
        if cfg and scfg:
            keys = set(cfg) | set(scfg)
            diff = [k for k in keys if cfg.get(k, '<缺>') != scfg.get(k, '<缺>')]
            print('   config 差异   : %d / %d 项' % (len(diff), len(keys)))
            fatal = [k for k in diff if k in (
                'CONFIG_MODVERSIONS', 'CONFIG_SMP', 'CONFIG_PREEMPT',
                'CONFIG_MODULE_UNLOAD', 'CONFIG_ARM64', 'CONFIG_64BIT')]
            print('   影响 vermagic/ABI 的差异: %s' % (fatal if fatal else '无'))
            ok &= not fatal

    print('\n 结论: %s' % ('PASS —— 具备开机条件（仍需真机验证）' if ok
                          else 'FAIL —— 不要刷入，先重编'))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image', nargs='?', default=os.path.join(HERE, 'kernel_Image'))
    ap.add_argument('--compare', action='store_true', help='与原厂内核逐项对比')
    a = ap.parse_args()
    if not os.path.isfile(a.image):
        sys.exit('找不到内核: %s' % a.image)
    return 0 if inspect(os.path.basename(a.image),
                        open(a.image, 'rb').read(), a.compare) else 1


if __name__ == '__main__':
    sys.exit(main())
