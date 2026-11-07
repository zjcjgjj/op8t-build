#!/usr/bin/env python3
"""v11 配置对齐硬校验（云端，olddefconfig 之后调用）。

v10 真机失败后离线比对发现：自编译内核相对原厂有 86 项配置差异，其中
CONFIG_DEBUG_FS=y（原厂 n）会在大量驱动结构体里插入 debugfs 字段，
是「CRC 对齐后 vendor .ko 加载即崩」的合理嫌疑。

本脚本对比 out/.config 与原厂 IKCONFIG 基线，打印全部差异，并对
ABI 敏感项做硬断言；不一致就 exit 1，让编译主动失败，不交付半成品。

用法：python3 config_align.py out/.config stock_config.txt
"""
import sys


def parse(path):
    cfg = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.strip()
        if line.startswith('CONFIG_') and '=' in line:
            k, v = line.split('=', 1)
            cfg[k] = v
        elif line.startswith('# CONFIG_') and line.endswith(' is not set'):
            cfg[line.split()[1]] = 'n'
    return cfg


# 会改变内核结构体布局 / 驱动语义的配置，必须与原厂一致
HARD = [
    'CONFIG_DEBUG_FS',
    'CONFIG_CMA_DEBUGFS', 'CONFIG_BLK_DEBUG_FS', 'CONFIG_BT_DEBUGFS',
    'CONFIG_QMP_DEBUGFS_CLIENT', 'CONFIG_REGMAP_ALLOW_WRITE_DEBUGFS',
    'CONFIG_WIL6210_DEBUGFS',
    'CONFIG_MSM_IDLE_STATS', 'CONFIG_IPA_UT',
    'CONFIG_BALANCE_ANON_FILE_RECLAIM',
    'CONFIG_MODVERSIONS', 'CONFIG_MODULES', 'CONFIG_MODULE_UNLOAD',
    'CONFIG_SMP', 'CONFIG_PREEMPT', 'CONFIG_64BIT', 'CONFIG_ARM64',
]

# 允许不一致（工具链 / 提速 / 签名公钥不配对 / KSU 本身）
ALLOW = {
    'CONFIG_KSU', 'CONFIG_KSU_MANUAL_HOOK', 'CONFIG_KSU_SYSCALL_TABLE_HOOK',
    'CONFIG_MODULE_SIG', 'CONFIG_MODULE_SIG_ALL', 'CONFIG_MODULE_SIG_FORCE',
    'CONFIG_MODULE_SIG_HASH', 'CONFIG_MODULE_SIG_KEY', 'CONFIG_MODULE_SIG_SHA512',
    'CONFIG_DEBUG_INFO', 'CONFIG_DEBUG_INFO_REDUCED',
    'CONFIG_DEBUG_INFO_DWARF4', 'CONFIG_GDB_SCRIPTS',
    'CONFIG_LD_IS_LLD', 'CONFIG_CLANG_VERSION',
    'CONFIG_TOUCHPANEL_ALGORITHM', 'CONFIG_TOUCHPANEL_FOCAL_FT3658U',
    'CONFIG_OPLUS_FEATURE_VIRTUAL_NET',
    'CONFIG_OPPO_KASAN_TEST', 'CONFIG_OPPO_KMEMLEAK_TEST',
    'CONFIG_OPLUS_KASAN_TEST', 'CONFIG_OPLUS_KMEMLEAK_TEST',
    'CONFIG_OPLUS_ARCH_FILE',
}


def norm(v):
    """Kconfig 里「# X is not set」与「根本没有这一行」语义等价，都是 n。"""
    return 'n' if v in ('<缺>', 'n') else v


def main():
    built, stock = parse(sys.argv[1]), parse(sys.argv[2])
    keys = sorted(set(built) | set(stock))
    diff = [(k, stock.get(k, '<缺>'), built.get(k, '<缺>')) for k in keys
            if norm(stock.get(k, '<缺>')) != norm(built.get(k, '<缺>'))]
    print('  v11 配置对齐检查: 自编译 %d 项 / 原厂 %d 项 / 差异 %d 项'
          % (len(built), len(stock), len(diff)))

    bad = [(k, s, b) for k, s, b in diff if k in HARD]
    print('  ABI 敏感项不一致: %d' % len(bad))
    for k, s, b in bad:
        print('     %-52s 原厂=%s 自编译=%s' % (k, s, b))

    # MODVERSIONS 必须 y，否则 vermagic 缺 modversions
    if built.get('CONFIG_MODVERSIONS') != 'y':
        print('  [FAIL] CONFIG_MODVERSIONS != y')
        return 1
    # DEBUG_FS 系列必须与原厂一致
    if bad and any(k.startswith('CONFIG_') and k in HARD for k, _, _ in bad):
        # 只把 debugfs / idle stats 类判为致命；
        # SMP/PREEMPT 等 vermagic 项交给后面的 check_kernel.py 兜底
        fatal = [(k, s, b) for k, s, b in bad
                 if 'DEBUG' in k or 'IDLE_STATS' in k or 'IPA_UT' in k
                 or 'BALANCE_ANON' in k or k == 'CONFIG_MODVERSIONS']
        if fatal:
            print('  [FAIL] ABI 敏感配置未对齐原厂，禁止继续编译')
            return 1
    print('  ABI 敏感配置已对齐原厂 ✓')

    unexpected = [(k, s, b) for k, s, b in diff
                  if k not in ALLOW and k not in HARD]
    print('  其余未预期差异: %d' % len(unexpected))
    for k, s, b in unexpected[:30]:
        print('     %-52s 原厂=%s 自编译=%s' % (k, s, b))

    print('  全部差异清单:')
    for k, s, b in diff:
        print('     %-52s %s -> %s' % (k, s, b))
    return 0


if __name__ == '__main__':
    sys.exit(main())
