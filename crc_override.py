#!/usr/bin/env python3
"""genksyms 输出过滤器：把自编译内核的导出符号 CRC 替换成原厂值。

Linux 4.19 的 scripts/Makefile.build 在 CONFIG_MODVERSIONS=y 时执行：

    genksyms ...  > .tmp_xxx.ver      # 内容是链接器脚本
    ld -r -o xxx.o .tmp_xxx.o -T .tmp_xxx.ver

.ver 文件里每一行形如：
    __crc_module_layout = 0x12345678;

本过滤器插在 genksyms 与 .ver 之间，把 stock_crc.txt 里有的符号的值
强制改成原厂内核的 CRC。这样 vendor .ko 的 __versions 段能通过内核
check_version() 的**正常**数值比对，无需关闭/跳过校验。

stock_crc.txt 来自 41 个原厂 vendor .ko 的 __versions 段（1033 个符号，
各模块 CRC 完全一致，即原厂内核导出符号的真实 CRC）。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_stock():
    crc = {}
    path = os.path.join(HERE, 'stock_crc.txt')
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            p = line.split()
            if len(p) >= 2 and p[1].lower().startswith('0x'):
                try:
                    crc[p[0]] = int(p[1], 16) & 0xFFFFFFFF
                except ValueError:
                    pass
    return crc


# genksyms 的链接器脚本输出行
PAT = re.compile(r'^(\s*__crc_([A-Za-z0-9_]+)\s*=\s*)0[xX][0-9a-fA-F]+\s*;\s*$')


def main():
    crc = load_stock()
    # CRC_STAT_FILE：记录「genksyms 原值 != 原厂值」的符号。
    # 这是本轮最关键的诊断量：空白对照内核若漂移很多，说明一加 OSS
    # 源码树本身与原厂内核不同；若 KSU 阶段比对照阶段多出漂移，说明
    # 官方 Kbuild 的自动 backport（struct seccomp / selinux）改动了 ABI。
    stat = os.environ.get('CRC_STAT_FILE')
    hit = 0
    for line in sys.stdin:
        m = PAT.match(line)
        if m and m.group(2) in crc:
            want = crc[m.group(2)]
            had = int(m.group(0).split('=')[1].strip().rstrip(';'), 16)
            if had != want and stat:
                with open(stat, 'a', encoding='utf-8') as f:
                    f.write('%s 0x%08x 0x%08x\n' % (m.group(2), had, want))
            line = '%s0x%08x;\n' % (m.group(1), want)
            hit += 1
        sys.stdout.write(line)
    # 只在确有覆盖时打印，避免几千条噪音；输出到 stderr 会进 build.log
    if hit:
        print('  [crc_override] 覆盖 %d 个导出符号 CRC' % hit, file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
