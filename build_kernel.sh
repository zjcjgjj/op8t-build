#!/usr/bin/env bash
# =============================================================================
# OnePlus 8T (kebab / KB2000) — ColorOS 14 / Android 14
# 编译带 KernelSU-Next 的内核，并打包成可 fastboot 刷入的 boot.img
#
# 固件基线：KB2000_14.0.0.602(CN01)，内核 4.19.157-perf+（非 GKI）
# 源码分支：OnePlusOSS/android_kernel_oneplus_sm8250  oneplus/sm8250_u_14.0.0_op8t
#
# 运行环境要求：Ubuntu 20.04 / 22.04 / 24.04（x86_64）
#   磁盘 >= 60GB，内存 >= 8GB（-j4 时）
# 用法：
#   ./build_kernel.sh                 # 全自动
#   KSU_TAG=v3.4.2 ./build_kernel.sh  # 指定 KernelSU-Next 版本
#   JOBS=4 ./build_kernel.sh          # 限制并行度（8G 内存建议 4）
# =============================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/OnePlusOSS/android_kernel_oneplus_sm8250.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-oneplus/sm8250_u_14.0.0_op8t}"
# 一加把 oplus 私有模块源码单独开源在另一个仓库；主仓库里
# kernel/sched_assist、block/blk、include/linux/sched_assist 等全是指向
# vendor/oplus/kernel/oplus_performance/... 的 symlink，单独 clone 是断链。
# 不补这份源码会缺头文件（如 sched_assist_locking.h）导致编译中断。
MODULES_REPO="${MODULES_REPO:-https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8250.git}"
MODULES_BRANCH="${MODULES_BRANCH:-oneplus/sm8250_u_14.0.0_op8t}"
KSU_REPO="${KSU_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}"
KSU_TAG="${KSU_TAG:-v3.4.0-legacy}"     # 4.19 非 GKI 必须用 legacy 分支（带 compat 兼容层）
DEFCONFIG="${DEFCONFIG:-vendor/kona-perf_defconfig}"
JOBS="${JOBS:-$(nproc)}"
WORK="${WORK:-$PWD/build}"
STOCK_BOOT="${STOCK_BOOT:-$PWD/stock_boot_KB2000_14.0.0.602.img}"
PART_SIZE=100663296                    # 8T boot 分区固定 96MiB

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 0. 依赖检查
log "检查依赖"
for c in git make python3 bc bison flex unzip curl; do
  command -v "$c" >/dev/null || { echo "缺少依赖: $c  →  sudo apt install -y $c"; exit 1; }
done
if ! command -v aarch64-linux-gnu-gcc >/dev/null; then
  echo "缺少 aarch64 交叉 binutils：sudo apt install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libssl-dev"
  exit 1
fi
mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- 1. 内核源码
if [ ! -d kernel ]; then
  log "克隆内核源码（约 4GB，浅克隆单分支）"
  git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" kernel
else
  log "源码已存在，跳过克隆"
fi

# ---------------------------------------------------------------- 1b. 补齐 oplus 私有模块源码
if [ ! -d "$WORK/kernel/vendor/oplus/kernel/oplus_performance" ]; then
  log "克隆一加私有模块源码（$MODULES_BRANCH，约 34MB）"
  rm -rf "$WORK/modules"
  git clone --depth 1 -b "$MODULES_BRANCH" "$MODULES_REPO" "$WORK/modules"
  rm -rf "$WORK/modules/.git"
  # 合并到内核源码树根目录，让所有断链 symlink 解析成功
  cp -a "$WORK/modules/." "$WORK/kernel/"
  rm -rf "$WORK/modules"
else
  log "私有模块源码已存在，跳过"
fi
cd "$WORK/kernel"

# 一加的 symlink 是按完整 AOSP 树层级写的（如
#   include/linux/sched_assist -> ../../../../vendor/oplus/... 
#   kernel/sched_assist        -> ../../../vendor/oplus/...
# ），独立 clone 出来的树浅两级 → 全部断链。
# 这里统一按 vendor/... 真实位置重连，不再依赖原始相对层级。
log "重连指向 vendor/ 的断链 symlink"
python3 - <<'PYEOF'
import os, re
ROOT = os.getcwd()
fixed, failed = 0, []
for base, dirs, files in os.walk(ROOT):
    if '.git' in dirs:
        dirs.remove('.git')
    for name in list(dirs) + list(files):
        p = os.path.join(base, name)
        if not os.path.islink(p) or os.path.exists(p):
            continue
        tgt = os.readlink(p).rstrip('/')
        m = re.search(r'vendor/(?:oplus|qcom)/.*$', tgt)
        if not m:
            continue
        new = os.path.join(ROOT, m.group(0))
        if os.path.exists(new):
            os.unlink(p)
            os.symlink(os.path.relpath(new, os.path.dirname(p)), p)
            fixed += 1
        else:
            failed.append('%s -> %s' % (os.path.relpath(p, ROOT), m.group(0)))
print('  重连 %d 个断链 symlink' % fixed)
for f in failed[:8]:
    print('  仍未解析:', f)
PYEOF

if [ ! -f include/linux/sched_assist/sched_assist_locking.h ]; then
  echo "===== 诊断：私有头文件未就位 ====="
  ls -ld vendor vendor/oplus/kernel/oplus_performance 2>&1 || true
  readlink include/linux/sched_assist 2>&1 || true
  find "$WORK/kernel" -name 'sched_assist_locking.h' 2>/dev/null | head -3
  echo "中止"; exit 1
fi
log "私有模块源码就位：$(find vendor/oplus/kernel/oplus_performance -maxdepth 1 -type d | wc -l) 个目录"
ls -l kernel/sched_assist block/blk include/linux/sched_assist | sed 's/^/    /'

# ---------------------------------------------------------------- 2. 工具链
# 官方镜像 version 串为 clang 10.0.7 → 用 LLVM 10.0.1 官方发布版最接近
# 坑1：LLVM 10.0.1 的 x86_64 资产只发布了 ubuntu-16.04（没有 18.04）
# 坑2：16.04 产物在 22.04 上依赖 libtinfo5；若仍跑不起来，自动换 AOSP prebuilt clang
TC="$WORK/toolchain"
mkdir -p "$TC"

try_llvm10() {
  local url="https://github.com/llvm/llvm-project/releases/download/llvmorg-10.0.1/clang%2Bllvm-10.0.1-x86_64-linux-gnu-ubuntu-16.04.tar.xz"
  log "下载 LLVM 10.0.1 工具链（~381MB）"
  curl -fL --retry 3 --retry-delay 3 -o "$TC/clang10.tar.xz" "$url" || return 1
  local sz; sz=$(stat -c%s "$TC/clang10.tar.xz" 2>/dev/null || echo 0)
  [ "$sz" -gt 100000000 ] || { echo "工具链体积异常：$sz 字节"; return 1; }
  tar -xf "$TC/clang10.tar.xz" -C "$TC" || return 1
  local d; d=$(find "$TC" -maxdepth 1 -type d -name 'clang+llvm-10*' | head -1)
  [ -n "$d" ] || { echo "解压后未找到 clang+llvm-10 目录"; return 1; }
  rm -rf "$TC/clang10"; mv "$d" "$TC/clang10"
  "$TC/clang10/bin/clang" --version >/dev/null 2>&1 || { echo "clang 无法运行（多为缺 libtinfo5）"; return 1; }
  return 0
}

try_aosp_clang() {
  log "回退到 AOSP prebuilt clang r383902（自包含，不依赖系统 libtinfo）"
  rm -rf "$TC/prebuilt-clang"
  git clone --depth 1 -q \
    https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r383902 \
    "$TC/prebuilt-clang" || return 1
  rm -rf "$TC/clang10"; ln -sfn "$TC/prebuilt-clang" "$TC/clang10"
  "$TC/clang10/bin/clang" --version >/dev/null 2>&1
}

if [ -x "$TC/clang10/bin/clang" ] && "$TC/clang10/bin/clang" --version >/dev/null 2>&1; then
  log "工具链已就绪（复用）"
else
  try_llvm10 || try_aosp_clang || { echo "工具链准备失败，中止"; exit 1; }
fi
export PATH="$TC/clang10/bin:$PATH"
clang --version | head -2

# ---------------------------------------------------------------- 3. KernelSU-Next
cd "$WORK/kernel"
if [ ! -d "$WORK/KernelSU-Next/.git" ]; then
  log "克隆 KernelSU-Next（$KSU_TAG）"
  rm -rf "$WORK/KernelSU-Next"
  # 直接 -b 到指定 tag：浅克隆后再切 tag 容易因 commit 不在浅历史而失败
  git clone --depth 1 -b "$KSU_TAG" "$KSU_REPO" "$WORK/KernelSU-Next"
fi
cd "$WORK/KernelSU-Next"
KSU_VER="$(git describe --tags --abbrev=0 2>/dev/null || echo "$KSU_TAG")"
log "KernelSU-Next 版本: $KSU_VER"

# ---------------------------------------------------------------- 4. 集成到驱动树
cd "$WORK/kernel/drivers"
log "把 KernelSU-Next 挂进 drivers/（等价于官方 setup.sh）"
rm -f kernelsu
ln -sfn "$(realpath --relative-to="$PWD" "$WORK/KernelSU-Next/kernel")" kernelsu
grep -q "kernelsu" Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> Makefile
# 只插一次（原来的 sed 会在每个 ^endmenu 前都插一条，导致重复 source）
if ! grep -q 'drivers/kernelsu/Kconfig' Kconfig; then
  awk 'BEGIN{d=0} /^endmenu/ && !d {print "source \"drivers/kernelsu/Kconfig\""; d=1} {print}' \
    Kconfig > Kconfig.new && mv Kconfig.new Kconfig
fi
grep -n 'kernelsu/Kconfig' Kconfig | sed 's/^/    /'
ls -l kernelsu | sed 's/^/    /'

# ---------------------------------------------------------------- 5. 配置内核
cd "$WORK/kernel"

# 一加 OSS 源码在 Kconfig 里直接写了 C 预处理器指令（如 init/Kconfig 的
#   #ifdef OPLUS_FEATURE_SCHED_ASSIST
#   source "kernel/sched_assist/Kconfig"
#   #endif
# ），标准 kconfig 解析器不认识 #ifdef，会报 unexpected/invalid option；
# 且 sched_assist/tuning/uad 这些目录在本分支里只是几十字节的占位文件（源码未开源）。
# 官方构建用 C 预处理器处理 Kconfig，这些 OPLUS_FEATURE_* 宏是定义过的；
# 现在私有源码已补齐，按「宏已定义」保留 #ifdef 块内容、丢弃 #ifndef 块。
log "预处理 Kconfig 中的 #ifdef 块"
python3 - <<'PYEOF'
import os, re
DIRECTIVE = re.compile(r'^(\s*)#\s*(ifdef|ifndef|endif|else|elif)\b')

def strip(path):
    keep, out, hit = [], [], False
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = DIRECTIVE.match(line)
            if m:
                hit = True
                d = m.group(2)
                if d == 'ifdef':
                    keep.append(True)           # 官方定义了该宏 → 保留内容
                elif d == 'ifndef':
                    keep.append(False)          # 官方定义了该宏 → 丢弃内容
                elif d == 'elif':
                    if keep: keep[-1] = False
                elif d == 'else':
                    if keep: keep[-1] = not keep[-1]
                elif d == 'endif':
                    if keep: keep.pop()
                continue
            if all(keep):
                out.append(line)
    if hit:
        with open(path, 'w', encoding='utf-8') as fh:
            fh.writelines(out)
    return hit

n = 0
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d != '.git']
    for f in files:
        if f == 'Kconfig' or f.endswith('.kconfig'):
            if strip(os.path.join(root, f)):
                n += 1
print('  cleaned %d kconfig file(s)' % n)

# OSS 仓库里 block/blk、block/uxio_first、kernel/sched_assist、kernel/tuning、kernel/uad
# 都是指向 vendor/oplus/kernel/oplus_performance/... 的 symlink，独立 clone 后是断链。
# 一旦 Kconfig 里 source 到它们（有的还没被 #ifdef 包住，如 block/Kconfig:249），
# kconfig 会 fatal 退出。这里把指向不存在文件的 source 行注释掉。
SRC_A = re.compile(r'^(\s*)source\s+"([^"]+)"\s*$')
SRC_B = re.compile(r'^(\s*)source\s+(\S+)\s*$')
VAR = re.compile(r'\$\(([A-Za-z0-9_]+)\)')
# 关键：Kconfig 的 source 允许带 $(SRCARCH) 这类变量。
# arch/Kconfig:1978 的 source "arch/$(SRCARCH)/Kconfig" 若按字面路径判断
# 会被误判成断链 → CONFIG_ARM64 / CONFIG_64BIT 全部丢失 →
# 编译到 kernel/bounds.s 才报 unknown type name 'atomic64_t'。
# 本构建固定 arm64，先把变量展开成真实路径再判断。
KENV = {'SRCARCH': 'arm64', 'ARCH': 'arm64', 'srctree': '.',
        'objtree': '.', 'KERNELVERSION': '4.19.157'}

def expand_vars(s):
    return VAR.sub(lambda m: KENV.get(m.group(1), m.group(0)), s)

skipped = []

def fix_sources():
    changed = 0
    for root, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if d != '.git']
        for f in files:
            if not (f == 'Kconfig' or f.endswith('.kconfig')):
                continue
            p = os.path.join(root, f)
            try:
                lines = open(p, encoding='utf-8', errors='replace').readlines()
            except OSError:
                continue
            out, hit = [], False
            for line in lines:
                if line.lstrip().startswith('#'):
                    out.append(line); continue
                m = SRC_A.match(line) or SRC_B.match(line)
                if m:
                    tgt = m.group(2)
                    resolved = expand_vars(tgt)
                    if '$(' in resolved:
                        # 变量无法解析 → 一律保留，绝不注释
                        out.append(line)
                        continue
                    cands = [resolved, os.path.normpath(os.path.join(root, resolved))]
                    if not any(os.path.isfile(c) for c in cands):
                        out.append('%s# [skip] dangling source: %s\n' % (m.group(1), tgt))
                        skipped.append('%s -> %s' % (p, tgt))
                        hit = True
                        continue
                out.append(line)
            if hit:
                open(p, 'w', encoding='utf-8').write(''.join(out))
                changed += 1
    return changed

print('  fixed %d kconfig with dangling source' % fix_sources())
for s in skipped[:12]:
    print('    skipped: %s' % s)
if len(skipped) > 12:
    print('    ... 共 %d 条' % len(skipped))
# 架构 Kconfig 必须保留，这是硬性校验
for must in ('arch/$(SRCARCH)/Kconfig',):
    if any(must in s for s in skipped):
        raise SystemExit('FATAL: 架构 Kconfig 被跳过，配置必然残缺')

# Makefile 里 obj-y += blk/ 这类指向不存在目录的条目同样会让 kbuild 直接报错，
# 只处理「整行所有目录都不存在」的情况，避免误伤。
MK = re.compile(r'^(\s*)obj-[^\s]+\s*(?:\+=|=)\s*(.*)$')
mk_fixed = 0
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d != '.git']
    if 'Makefile' not in files:
        continue
    p = os.path.join(root, 'Makefile')
    try:
        lines = open(p, encoding='utf-8', errors='replace').readlines()
    except OSError:
        continue
    out, hit = [], False
    for line in lines:
        if line.lstrip().startswith('#'):
            out.append(line); continue
        m = MK.match(line)
        if m:
            subs = [t for t in m.group(2).split() if t.endswith('/')]
            if subs and not any(os.path.isdir(os.path.join(root, s.rstrip('/'))) for s in subs):
                out.append('%s# [skip] missing dir: %s\n' % (m.group(1), ' '.join(subs)))
                hit = True
                continue
        out.append(line)
    if hit:
        open(p, 'w', encoding='utf-8').write(''.join(out))
        mk_fixed += 1
print('  fixed %d Makefile with missing dir' % mk_fixed)
PYEOF

log "生成 defconfig: $DEFCONFIG"
# 必须显式带 CC=clang：init/Kconfig 里有
#   default $(shell,$(srctree)/scripts/gcc-version.sh -p $(CC) | sed 's/^0*//') if CC_IS_GCC
# kconfig 的 $(shell,...) 从环境变量取 $(CC)，命令行变量才会进 environ；
# 不传则 $(CC) 为空 → 命令失败 → 展开成空值 → "default" 没值 → syntax error。
KMAKE_ARGS="CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-"
if ! make ARCH=arm64 O=out $KMAKE_ARGS "$DEFCONFIG"; then
  log "defconfig 仍失败 → 改写 init/Kconfig 的 \$(shell,...)/\$(success,...) 后重试"
  python3 - <<'PYEOF'
import re
p = 'init/Kconfig'
t = open(p, encoding='utf-8', errors='replace').read()
BOOL_FUNCS = ('success', 'cc-option', 'ld-option', 'as-option',
              'gcc-min-version', 'clang-min-version')
out, i, n = [], 0, len(t)
while i < n:
    if t.startswith('$(', i):
        j, depth = i + 2, 1
        while j < n and depth:
            if t[j] == '(':
                depth += 1
            elif t[j] == ')':
                depth -= 1
            j += 1
        if depth == 0:
            name = t[i + 2:j - 1].split(',', 1)[0].strip()
            if name in BOOL_FUNCS:
                out.append('n'); i = j; continue
            if name == 'shell':
                out.append('0'); i = j; continue
    out.append(t[i]); i += 1
new = ''.join(out)
new = new.replace('def_bool 0', 'def_bool n').replace('def_bool n if', 'def_bool n')
open(p, 'w', encoding='utf-8').write(new)
print('  init/Kconfig 已改写')
PYEOF
  make ARCH=arm64 O=out $KMAKE_ARGS "$DEFCONFIG"
fi

log "打开 KernelSU 相关选项 / 处理厂商模块兼容性"
CFG="out/.config"
# 先删旧行再写，避免出现重复键（.config 里 "X=y" 与 "# X is not set" 并存会被 Kconfig 警告）
set_cfg() {
  local k="$1" v="$2"
  sed -i -e "/^${k}=/d" -e "/^# ${k} is not set\$/d" "$CFG"
  if [ "$v" = "n" ]; then
    printf '# %s is not set\n' "$k" >> "$CFG"
  else
    printf '%s=%s\n' "$k" "$v" >> "$CFG"
  fi
}
set_cfg CONFIG_KSU y
set_cfg CONFIG_KPROBES y
set_cfg CONFIG_KALLSYMS y
set_cfg CONFIG_KALLSYMS_ALL y
set_cfg CONFIG_EXT4_FS y
set_cfg CONFIG_OVERLAY_FS y
# ↓↓ 4.19 非 GKI：不能用 kprobes hook（作者注明仅 5.10+ 适用），
#    改用 syscall table hook（作者注明面向 non-GKI，要求内核 >= 4.17）
set_cfg CONFIG_KSU_MANUAL_HOOK n
set_cfg CONFIG_KSU_SYSCALL_TABLE_HOOK y
# ↓↓ 关键：关闭厂商模块签名强制与符号版本校验，
#    否则原厂 vendor 分区里的已签名模块（wlan/camera/audio）会拒绝加载
set_cfg CONFIG_MODULE_SIG_FORCE n
set_cfg CONFIG_MODULE_SIG n
set_cfg CONFIG_MODVERSIONS n
# ↓↓ 提速：调试信息不进 Image，却占掉整个编译时间的一大半（clang 生成 DWARF 极慢）
set_cfg CONFIG_DEBUG_INFO n
set_cfg CONFIG_DEBUG_INFO_REDUCED n
set_cfg CONFIG_DEBUG_INFO_DWARF4 n
set_cfg CONFIG_GDB_SCRIPTS n
make ARCH=arm64 O=out $KMAKE_ARGS olddefconfig

grep -E "^CONFIG_(KSU|KPROBES|KALLSYMS_ALL|MODVERSIONS|MODULE_SIG)" out/.config || true
echo "  KPROBES: $(grep -E '^(CONFIG_KPROBES=y|# CONFIG_KPROBES)' out/.config)"
echo "  MODULES: $(grep -E '^(CONFIG_MODULES=y|# CONFIG_MODULES)' out/.config)"
echo "  DEBUG_INFO: $(grep -E '^CONFIG_DEBUG_INFO' out/.config | tr '\n' ' ')"

# Kconfig 的 choice 组在 KPROBES=n 时行为不可靠，分三级兜底
MAKE_EXTRA=""
if ! grep -q '^CONFIG_KSU_SYSCALL_TABLE_HOOK=y' out/.config; then
  echo "  hook 模式未落盘 → 二次强制写入"
  set_cfg CONFIG_KSU_MANUAL_HOOK n
  set_cfg CONFIG_KSU_SYSCALL_TABLE_HOOK y
  make ARCH=arm64 O=out $KMAKE_ARGS olddefconfig >/dev/null 2>&1 || true
fi

if ! grep -q '^CONFIG_KSU_SYSCALL_TABLE_HOOK=y' out/.config; then
  log "Kconfig choice 仍不接受 → 直接改 KSU 的 Kbuild 强制 syscall table 模式"
  KB="$WORK/KernelSU-Next/kernel/Kbuild"
  if ! grep -q 'KSU_FORCE_SYSCALL' "$KB"; then
    cat >> "$KB" <<'KBEOF'

# --- 构建脚本强制追加：4.19 + KPROBES=n 时 Kconfig choice 不生效 ---
KSU_FORCE_SYSCALL := 1
ccflags-y += -DKSU_SYSCALL_TABLE_HOOK
kernelsu-objs += hook/patch_memory.o
kernelsu-objs += hook/syscall_table_hook.o
kernelsu-objs += infra/symbol_resolver.o
KBEOF
  fi
  # Kbuild 里的 $(error ...) 用命令行的 HAVE_KSU_HOOK 绕开
  MAKE_EXTRA="HAVE_KSU_HOOK=0"
  echo "  已启用 Kbuild 兜底（HAVE_KSU_HOOK=0 + -DKSU_SYSCALL_TABLE_HOOK）"
fi

# 架构 Kconfig 必须真的被加载：arch/Kconfig 里的
#   source "arch/$(SRCARCH)/Kconfig"
# 一旦被当成断链注释掉，CONFIG_ARM64 / CONFIG_64BIT 全丢，
# 要等编译几分钟才在 kernel/bounds.s 报 unknown type name 'atomic64_t'。
# 这里提前断言，配置阶段立刻失败。
for k in CONFIG_ARM64 CONFIG_64BIT; do
  grep -q "^$k=y" out/.config || { echo "架构 Kconfig 未加载：$k 缺失 —— 中止"; exit 1; }
done
if ! grep -q '^#define CONFIG_64BIT 1' out/include/generated/autoconf.h; then
  echo "autoconf.h 缺 CONFIG_64BIT —— 中止"; exit 1
fi
echo "  架构: $(grep -E '^CONFIG_(ARM64|64BIT)=' out/.config | tr '\n' ' ')"

# 早期断言：核心配置没真正生效就立刻停，别等编译几十分钟才失败
grep -q "^CONFIG_KSU=y" out/.config || { echo "配置未生效：CONFIG_KSU —— 中止"; exit 1; }
grep -q "^CONFIG_KALLSYMS_ALL=y" out/.config || { echo "配置未生效：CONFIG_KALLSYMS_ALL —— 中止"; exit 1; }
# EXT4 / OVERLAY 只做提示：syscall hook 不依赖它们硬性成立
for k in CONFIG_EXT4_FS CONFIG_OVERLAY_FS; do
  grep -q "^$k=y" out/.config || echo "  提示：$k 不是 y → $(grep -E "^(# )?${k}" out/.config | head -1)"
done
echo "  --- 关键配置实际值 ---"
grep -E "^(# )?CONFIG_(KSU|KPROBES|EXT4_FS|OVERLAY_FS|DEBUG_INFO|MODULES|MODVERSIONS|MODULE_SIG)" out/.config | sed 's/^/    /'

# ---------------------------------------------------------------- 6. 编译
log "开始编译 Image（jobs=$JOBS）"
# ccache：失败重跑时绝大多数 .o 直接命中缓存，编译从十几分钟降到 1-3 分钟。
# 出问题可用 USE_CCACHE=0 关掉。defconfig 阶段仍用裸 clang（kconfig 要读 CC）。
BUILD_CC="clang"
if [ "${USE_CCACHE:-1}" = "1" ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$WORK/.ccache}"
  mkdir -p "$CCACHE_DIR"
  ccache -M 4G >/dev/null 2>&1 || true
  ccache -z >/dev/null 2>&1 || true
  BUILD_CC="ccache clang"
  echo "  ccache 已启用：$CCACHE_DIR"
fi
T0=$(date +%s)
make -j"$JOBS" ARCH=arm64 O=out \
  CC="$BUILD_CC" CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  KCFLAGS="-Wno-error" $MAKE_EXTRA \
  Image
log "编译完成，耗时 $(( $(date +%s) - T0 )) 秒"
if command -v ccache >/dev/null 2>&1; then ccache -s 2>/dev/null | head -8 || true; fi

IMG="out/arch/arm64/boot/Image"
[ -f "$IMG" ] || { echo "编译失败：找不到 $IMG"; exit 1; }
ls -lh "$IMG"
grep -a -o "Linux version 4\.19\.[0-9]*-perf[^\"]\{0,40\}" "$IMG" | head -1 || true

# ---------------------------------------------------------------- 7. 打包 boot.img
if [ -f "$STOCK_BOOT" ]; then
  log "替换原厂 boot.img 中的内核并重新打包"
  PACKDIR="$WORK/pack"
  rm -rf "$PACKDIR"; mkdir -p "$PACKDIR"
  python3 "$HERE/mkboot.py" unpack "$STOCK_BOOT" "$PACKDIR"
  cp "$IMG" "$PACKDIR/kernel"
  python3 "$HERE/mkboot.py" pack "$STOCK_BOOT" "$PACKDIR" "$HERE/boot_kernelsu_next.img" "$PART_SIZE"
  log "完成 → $HERE/boot_kernelsu_next.img"
else
  log "无原厂 boot.img（$STOCK_BOOT），跳过封装，仅产出内核 Image"
  cp "$IMG" "$HERE/kernel_Image"
  exit 0
fi

# ---------------------------------------------------------------- 8. 卡刷 zip
log "生成关闭 AVB 的 vbmeta 与卡刷 zip"
python3 "$HERE/vbmeta_patch.py" "$HERE/stock_vbmeta.img" "$HERE/vbmeta_avb_disabled.img"
ZIP="$HERE/OP8T_KernelSU-Next_${KSU_VER}.zip"
python3 "$HERE/make_flash_zip.py" \
  --boot "$HERE/boot_kernelsu_next.img" \
  --vbmeta "$HERE/vbmeta_avb_disabled.img" \
  --name "OP8T_KernelSU-Next_${KSU_VER}" \
  --out "$ZIP" \
  --readme "
内核: Linux 4.19.157 + KernelSU-Next ${KSU_VER}
基线: KB2000_14.0.0.602(CN01)
"

log "卡刷包 → $ZIP"
cat <<'EOF'

刷入（任选其一）：
  A. recovery：安装 OP8T_KernelSU-Next_*.zip
  B. fastboot：
     fastboot flash boot boot_kernelsu_next.img
     fastboot flash vbmeta vbmeta_avb_disabled.img
     fastboot reboot

回滚到原厂：
  fastboot flash boot stock_boot_KB2000_14.0.0.602.img
  fastboot flash vbmeta stock_vbmeta.img
EOF
