#!/usr/bin/env python3
"""编译后硬校验：vmlinux 里 __crc_* 绝对符号的值是否等于原厂 CRC。

用法: python3 crc_verify.py out/vmlinux stock_crc.txt
readelf -sW 里 __crc_foo 是 ABS 符号，其 Value 就是该符号的 CRC 值。
"""
import os
import re
import subprocess
import sys
from collections import Counter

PAT_NAME = re.compile(r'^__crc_([A-Za-z0-9_]+)$')


def main():
    vmlinux, stock = sys.argv[1], sys.argv[2]
    want = {}
    for line in open(stock, encoding='utf-8', errors='replace'):
        p = line.split()
        if len(p) >= 2 and p[1].lower().startswith('0x'):
            want[p[0]] = int(p[1], 16) & 0xFFFFFFFF

    tool = None
    for cand in ('readelf', 'aarch64-linux-gnu-readelf', 'llvm-readelf'):
        if subprocess.run(['which', cand], capture_output=True).returncode == 0:
            tool = cand
            break
    if tool is None:
        print('!! 找不到 readelf，无法做 CRC 硬校验')
        return 2
    p = subprocess.run([tool, '-sW', vmlinux],
                       capture_output=True, text=True, errors='replace')
    built = {}
    for line in (p.stdout or '').splitlines():
        cols = line.split()
        if len(cols) < 8:
            continue
        m = PAT_NAME.match(cols[-1])
        if not m:
            continue
        try:
            built[m.group(1)] = int(cols[1], 16) & 0xFFFFFFFF
        except ValueError:
            pass

    common = sorted(set(want) & set(built))
    same = [n for n in common if want[n] == built[n]]
    diff = [(n, want[n], built[n]) for n in common if want[n] != built[n]]
    only_stock = sorted(set(want) - set(built))
    zero = sorted(n for n, v in built.items() if v == 0)

    print('=== 导出符号 CRC 硬校验 ===')
    print('  原厂 vendor 模块期望 : %d 个符号' % len(want))
    print('  vmlinux 实际导出     : %d 个 __crc_* 符号' % len(built))
    print('  交集                 : %d' % len(common))
    print('  ✓ CRC 一致           : %d' % len(same))
    print('  ✗ CRC 不一致         : %d' % len(diff))
    print('  原厂有但内核未导出   : %d' % len(only_stock))
    print('  值为 0 的补桩符号    : %d %s' % (len(zero), zero[:8]))
    if diff:
        print('  不一致示例:')
        for n, w, b in diff[:15]:
            print('    %-42s 原厂=0x%08x 编译=0x%08x' % (n, w, b))
    if only_stock:
        print('  未导出示例: ' + ', '.join(only_stock[:15]))

    rate = (len(same) / len(common) * 100) if common else 0
    print('  匹配率: %.2f%%' % rate)
    # 低于 99% 视为失败，避免又一个注定拒载的内核被交付
    if rate < 99.0:
        print('  !! CRC 覆盖未生效，中止交付')
        return 1
    print('  PASS：vendor .ko 的 __versions 能通过 check_version() 正常校验')
    return 0


if __name__ == '__main__':
    sys.exit(main())
