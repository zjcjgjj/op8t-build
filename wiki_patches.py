#!/usr/bin/env python3
"""按 KernelSU-Next 官方 wiki 的 manual hook 规范，给 4.19 内核源码打补丁。

官方页面：https://kernelsu-next.github.io/webpage/pages/how-to-integrate-for-non-gki.html
（"Manually modify the kernel source" 一节，5 个调用点）

重要：wiki 里的补丁是 4.14 时代写的，legacy 分支(2026-10-26)的真实函数
签名已经变了。本脚本以 **legacy 分支实际源码** 为准：

  int  ksu_handle_execveat(int *, struct filename **, void *, void *, int *)
  int  ksu_handle_faccessat(int *, const char __user **, int *, int *)
  void ksu_handle_sys_read(unsigned int fd)              <-- wiki 写成 3 参数，已过时
  int  ksu_handle_stat(int *, const char __user **, int *)
  int  ksu_handle_sys_reboot(int, int, unsigned int, void __user **)

一加 4.19.157 的函数形态与 wiki 的 4.14 示例也不完全一致，所以每个调用点
都用「多候选锚点 + 显式插入模式」自动适配：

  body   : 锚点是函数签名（可能跨行），插到之后第一个函数体 '{' 的后面
  before : 插到锚点行之前（hook 必须先于被拦截的语句执行）
  after  : 插到锚点行之后（局部变量声明之后）

任何一处没找到就 exit 1，绝不在半成品上继续编译。
用法：python3 wiki_patches.py <kernel-source-root>
"""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()

# 每个补丁：(文件, 标记字符串, extern 声明块, [(锚点正则, 模式, 插入语句), ...])
PATCHES = [
    dict(
        file='fs/exec.c',
        marker='ksu_handle_execveat',
        label='execve (__do_execve_file / do_execveat_common)',
        decl=(
            '#ifdef CONFIG_KSU\n'
            'extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n'
            '\t\t\t\tvoid *argv, void *envp, int *flags);\n'
            '#endif\n'
        ),
        anchors=[
            (r'^\s*static int __do_execve_file\s*\(', 'body',
             '\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n'),
            (r'^\s*static int do_execveat_common\s*\(', 'body',
             '\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n'),
        ],
    ),
    dict(
        file='fs/open.c',
        marker='ksu_handle_faccessat',
        label='faccessat',
        decl=(
            '#ifdef CONFIG_KSU\n'
            'extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n'
            '\t\t\t\tint *mode, int *flags);\n'
            '#endif\n'
        ),
        anchors=[
            (r'^\s*unsigned int lookup_flags\s*=\s*LOOKUP_FOLLOW\s*;', 'after',
             '\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n'),
            (r'^\s*long do_faccessat\s*\(', 'body',
             '\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n'),
        ],
    ),
    dict(
        file='fs/read_write.c',
        marker='ksu_handle_sys_read',
        label='sys_read',
        decl=(
            '#ifdef CONFIG_KSU\n'
            'extern void ksu_handle_sys_read(unsigned int fd);\n'
            '#endif\n'
        ),
        anchors=[
            (r'^\s*struct fd f\s*=\s*fdget_pos\(fd\)\s*;', 'after',
             '\tksu_handle_sys_read(fd);\n'),
            (r'^SYSCALL_DEFINE3\(read,', 'body',
             '\tksu_handle_sys_read(fd);\n'),
        ],
    ),
    dict(
        file='fs/stat.c',
        marker='ksu_handle_stat',
        label='newfstatat',
        decl=(
            '#ifdef CONFIG_KSU\n'
            'extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n'
            '\t\t\tint *flags);\n'
            '#endif\n'
        ),
        anchors=[
            (r'^\s*error\s*=\s*vfs_fstatat\s*\(', 'before',
             '\tksu_handle_stat(&dfd, &filename, &flag);\n'),
            (r'^\s*int vfs_fstatat\s*\(', 'body',
             '\tksu_handle_stat(&dfd, &filename, &flag);\n'),
        ],
    ),
    dict(
        file='kernel/reboot.c',
        marker='ksu_handle_sys_reboot',
        label='sys_reboot (Kbuild 用这个判断 manual hook 是否存在)',
        decl=(
            '#ifdef CONFIG_KSU\n'
            'extern int ksu_handle_sys_reboot(int magic1, int magic2,\n'
            '\t\t\tunsigned int cmd, void __user **arg);\n'
            '#endif\n'
        ),
        anchors=[
            (r'^\s*/\* We only trust the superuser with rebooting', 'before',
             '\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n'),
            (r'^SYSCALL_DEFINE4\(reboot,', 'body',
             '\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n'),
        ],
    ),
]


def read(p):
    return open(p, encoding='utf-8', errors='replace').read()


def write(p, s):
    open(p, 'w', encoding='utf-8').write(s)


def insert_decl(src, decl):
    """把 extern 声明插到最后一个 #include 之后（保证类型已定义）。"""
    lines = src.splitlines(keepends=True)
    last = -1
    for i, l in enumerate(lines):
        if l.lstrip().startswith('#include'):
            last = i
    if last < 0:
        return decl + '\n' + src
    return ''.join(lines[:last + 1]) + '\n' + decl + '\n' + ''.join(lines[last + 1:])


def insertion_point(src, m, mode):
    """返回插入位置（字符偏移），保证落在一个完整行的边界上。"""
    line_start = src.rfind('\n', 0, m.start()) + 1
    line_end = src.find('\n', m.end())
    if line_end < 0:
        line_end = len(src)
    if mode == 'before':
        return line_start
    if mode == 'after':
        return line_end + 1 if line_end < len(src) else line_end
    if mode == 'body':
        # 函数签名可能跨多行：从锚点匹配结束处往后找第一个单独 '{' 行
        bm = re.search(r'^\s*\{\s*$', src[m.end():], re.M)
        if not bm:
            return None
        pos = m.end() + bm.end()
        nxt = src.find('\n', pos)
        return (nxt + 1) if nxt >= 0 else len(src)
    return None


def patch_one(p):
    path = os.path.join(ROOT, p['file'])
    if not os.path.isfile(path):
        print('  [FAIL] %-24s 文件不存在' % p['file'])
        return False
    src = read(path)
    if p['marker'] in src:
        print('  [SKIP] %-24s 已包含 %s（幂等）' % (p['file'], p['marker']))
        return True

    chosen = None
    for regex, mode, call in p['anchors']:
        m = re.search(regex, src, re.M)
        if not m:
            continue
        pos = insertion_point(src, m, mode)
        if pos is None:
            continue
        chosen = (m, mode, call, pos, regex)
        break
    if not chosen:
        print('  [FAIL] %-24s 找不到可用锚点；候选：' % p['file'])
        for r, md, _ in p['anchors']:
            print('           [%s] %s' % (md, r))
        for l in src.splitlines():
            if any(k in l for k in ('do_execveat_common', '__do_execve_file',
                                    'do_faccessat', 'SYSCALL_DEFINE3(read',
                                    'SYSCALL_DEFINE4(newfstatat',
                                    'SYSCALL_DEFINE4(reboot')):
                print('           实际源码: ' + l.strip()[:120])
        return False

    m, mode, call, pos, regex = chosen
    if0, end0 = src.count('#ifdef CONFIG_KSU'), src.count('#endif')
    ins = '#ifdef CONFIG_KSU\n' + call + '#endif\n'
    src = src[:pos] + ins + src[pos:]
    src = insert_decl(src, p['decl'])
    # 结构自检：本轮新增的 #ifdef CONFIG_KSU 与 #endif 必须各 2 个
    # （一个包 extern 声明，一个包调用），且调用确实存在。
    assert src.count('#ifdef CONFIG_KSU') - if0 == 2, \
        '%s 的 extern 声明块不完整' % p['file']
    assert src.count('#endif') - end0 == 2, '%s 的 #endif 不配平' % p['file']
    assert call.strip() in src, '%s 的 hook 调用丢失' % p['file']
    write(path, src)
    print('  [ OK ] %-24s %-46s mode=%-6s 行 %d'
          % (p['file'], p['label'], mode, src[:pos].count('\n') + 1))
    return True


def main():
    print('=== KernelSU-Next 官方 wiki manual hook 补丁 (4.19 适配版) ===')
    print('源码根目录: %s' % ROOT)
    ok = 0
    for p in PATCHES:
        if patch_one(p):
            ok += 1
    print('=== 结果: %d/%d 处就位 ===' % (ok, len(PATCHES)))
    if ok != len(PATCHES):
        print('[FAIL] manual hook 不完整，Kbuild 会拒绝编译，禁止继续')
        return 1
    rb = read(os.path.join(ROOT, 'kernel/reboot.c'))
    assert 'ksu_handle_sys_reboot' in rb, 'Kbuild 检测字符串缺失'
    print('Kbuild 检测项 (kernel/reboot.c 含 ksu_handle_sys_reboot): PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
