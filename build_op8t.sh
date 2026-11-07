#!/usr/bin/env bash
# =============================================================================
# OnePlus 8T (kebab / KB2000) — 干净编译链（社区 ColorOS/OOS 完整树）
#
# 与之前 OnePlusOSS 官方分支的区别：
#   1. 换用 toraidl/android_kernel_oneplus_sm8250 的 op8t 分支 —— 完整的
#      Oplus 树（含 oplus/ techpack/ OplusKernelEnvConfig.mk），defconfig 里
#      有 CONFIG_TOUCHPANEL_FOCAL_FT3658U / CONFIG_OPLUS_FEATURE_VIRTUAL_NET，
#      而 OnePlusOSS 的 u_14.0.0 分支里这两个符号根本不存在。
#   2. 不再打任何"让 OSS 树能编过"的补丁（kallsyms 过滤、CRC 覆盖、
#      check_version 放行、配置强对齐）——那套东西是为残缺源码打的补丁。
#   3. 关键：同时产出 Image + 树自己的 dtb + dtbo.img。之前 14 个版本全部
#      是「OSS 内核 + 原厂 qcdt」，内核与 DTB 不是配套的一对。
#
# 用法：
#   PHASE=base ./build_op8t.sh      # 无 KernelSU 的空白对照
#   PHASE=ksu  ./build_op8t.sh      # 内置 KernelSU-Next (legacy 分支)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
PHASE="${PHASE:-base}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/toraidl/android_kernel_oneplus_sm8250.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-op8t}"
KSU_REPO="${KSU_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}"
KSU_REF="${KSU_REF:-legacy}"
DEFCONFIG="${DEFCONFIG:-vendor/kona-perf_defconfig}"
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$WORK" "$OUT"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "===== 依赖检查 ====="
for c in git make python3 bc bison flex unzip curl tar; do
  command -v "$c" >/dev/null || { echo "[FAIL] 缺少 $c"; exit 1; }
done
command -v aarch64-linux-gnu-as >/dev/null || {
  echo "[FAIL] 缺少 aarch64-linux-gnu-as（apt install binutils-aarch64-linux-gnu）"
  echo "       否则汇编会误用主机 x86 的 as，报 unrecognized option '-EL'"
  exit 1; }

# ------------------------------------------------------------------ 1. 源码
log "===== 克隆内核树 $KERNEL_BRANCH ====="
if [ ! -d "$WORK/kernel/.git" ]; then
  rm -rf "$WORK/kernel"
  git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$WORK/kernel"
fi
cd "$WORK/kernel"
log "  HEAD $(git rev-parse --short HEAD)  $(git log -1 --format=%cd --date=short)"

# --------------------------------------------------------------- 2. 工具链
log "===== 准备 clang 10 ====="
TC="$WORK/tc"; mkdir -p "$TC"
if ! "$TC/clang10/bin/clang" --version >/dev/null 2>&1; then
  if [ ! -d "$TC/clang+llvm-10" ]; then
    curl -fL --retry 3 --retry-delay 3 -o "$TC/clang10.tar.xz" \
      "https://github.com/llvm/llvm-project/releases/download/llvmorg-10.0.1/clang%2Bllvm-10.0.1-x86_64-linux-gnu-ubuntu-16.04.tar.xz" || true
    tar -xf "$TC/clang10.tar.xz" -C "$TC" 2>/dev/null || true
    d=$(find "$TC" -maxdepth 1 -type d -name 'clang+llvm-10*' | head -1)
    [ -n "$d" ] && rm -rf "$TC/clang10" && mv "$d" "$TC/clang10"
  fi
  # LLVM 10 的预编译包依赖 libtinfo5，Ubuntu 22.04 已移除 → 直接装 focal 的 deb
  if ! "$TC/clang10/bin/clang" --version >/dev/null 2>&1; then
    log "  clang 无法运行，安装 libtinfo5"
    for deb in \
      http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.2-0ubuntu2.1_amd64.deb \
      http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.2-0ubuntu2_amd64.deb; do
      curl -fsSL --retry 3 -o "$TC/libtinfo5.deb" "$deb" || continue
      sudo dpkg -i "$TC/libtinfo5.deb" >/dev/null 2>&1 && break
    done
  fi
  if ! "$TC/clang10/bin/clang" --version >/dev/null 2>&1; then
    log "  仍未跑起来，回退 AOSP prebuilt r416183b"
    rm -rf "$TC/prebuilt-clang"
    git clone --depth 1 -q \
      https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b \
      "$TC/prebuilt-clang"
    rm -rf "$TC/clang10"; ln -sfn "$TC/prebuilt-clang" "$TC/clang10"
  fi
fi
export PATH="$TC/clang10/bin:$PATH"
clang --version | head -2 || { echo "[FAIL] 工具链不可用"; exit 1; }

# ------------------------------------------------------- 3. 可选 KernelSU 集成
if [ "$PHASE" = "ksu" ]; then
  log "===== 集成 KernelSU-Next（$KSU_REF）====="
  if [ ! -d "$WORK/KernelSU-Next/.git" ]; then
    git clone --depth 1 -b "$KSU_REF" "$KSU_REPO" "$WORK/KernelSU-Next"
  fi
  ( cd "$WORK/KernelSU-Next" && git rev-parse --short HEAD )
  bash "$WORK/KernelSU-Next/kernel/setup.sh" "$WORK/kernel" || {
    echo "[FAIL] setup.sh 失败"; exit 1; }
fi

# --------------------------------------------------------------- 4. 配置
log "===== 生成 .config（$DEFCONFIG）====="
rm -rf out
KMAKE="ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-"
make O=out $KMAKE "$DEFCONFIG" >/dev/null

# 两个阶段都必须关掉 MODULE_SIG_FORCE：
#   原厂 y，且 vendor .ko 由一加私钥签名；我们没有一加的私钥，保持 FORCE=y
#   会让全部 vendor 模块被拒 -> lcd/触摸/音频不加载 -> 黑屏。
#   保留 MODULE_SIG=y（struct module 布局更贴近原厂），只把 FORCE 关掉，
#   这样签名验证失败只 taint 而不会拒绝加载。
OVERRIDES="CONFIG_MODULE_SIG_FORCE=n"
if [ "$PHASE" = "ksu" ]; then
  OVERRIDES="$OVERRIDES CONFIG_KSU=y CONFIG_KSU_SYSCALL_TABLE_HOOK=y CONFIG_KALLSYMS_ALL=y CONFIG_KPROBES=y"
fi
python3 - "$PWD/out/.config" $OVERRIDES <<'PYEOF'
import sys
p, pairs = sys.argv[1], sys.argv[2:]
want = dict(x.split('=', 1) for x in pairs)
s = open(p, encoding='utf-8', errors='replace').read()
lines = [l for l in s.splitlines()
         if not any(l.startswith(k + '=') or l.startswith('# ' + k + ' is not set')
                    for k in want)]
for k, v in want.items():
    lines.append('%s=%s' % (k, v))
open(p, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('  已覆盖: ' + ', '.join('%s=%s' % kv for kv in want.items()))
PYEOF
make O=out $KMAKE olddefconfig >/dev/null

if [ "$PHASE" = "ksu" ]; then
  for k in CONFIG_KSU CONFIG_KSU_SYSCALL_TABLE_HOOK CONFIG_KALLSYMS_ALL; do
    grep -q "^$k=y" out/.config || { echo "[FAIL] $k 未生效"; exit 1; }
  done
fi
grep -q "^# CONFIG_MODULE_SIG_FORCE is not set" out/.config || {
  echo "[FAIL] MODULE_SIG_FORCE 未关闭"; exit 1; }

log "  关键配置："
grep -E "^CONFIG_(KSU|KSU_SYSCALL|KPROBES|KALLSYMS_ALL|MODVERSIONS|MODULE_SIG|DEBUG_FS)=|^# CONFIG_(MODULE_SIG|DEBUG_FS) " out/.config | head -12 || true
grep -c "^CONFIG_OPLUS_" out/.config | sed 's/^/  CONFIG_OPLUS_* 数量: /'

# --------------------------------------------------------------- 5. 编译
log "===== 编译 Image（-j$JOBS）====="
set +e
make -j"$JOBS" O=out $KMAKE Image > "$OUT/_img_$PHASE.log" 2>&1
RC=$?
set -e
tail -25 "$OUT/_img_$PHASE.log"
if [ $RC -ne 0 ]; then
  if grep -qiE "relocation .*__crc|recompile with -fPIC|dangerous relocation" "$OUT/_img_$PHASE.log"; then
    log "  bfd 链接器报 __crc 重定位错误 → 改用 ld.lld 重试"
    make -j"$JOBS" O=out $KMAKE LD=ld.lld Image > "$OUT/_img2_$PHASE.log" 2>&1 || {
      tail -40 "$OUT/_img2_$PHASE.log"; echo "[FAIL] ld.lld 重试仍失败"; exit 1; }
    tail -15 "$OUT/_img2_$PHASE.log"
  else
    echo "[FAIL] 编译 Image 失败，完整日志见 _img_$PHASE.log"
    exit 1
  fi
fi
log "===== 编译 dtb / dtbo ====="
make -j"$JOBS" O=out $KMAKE dtbs 2>&1 | tail -15 || log "  dtbs 目标失败，尝试直接构建 dtb"
make -j"$JOBS" O=out $KMAKE arch/arm64/boot/dtb 2>&1 | tail -10 || true
make -j"$JOBS" O=out $KMAKE arch/arm64/boot/dtbo.img 2>&1 | tail -10 || true

# --------------------------------------------------------------- 6. 收集产物
TAG="kernel_op8t_$PHASE"
IMG="out/arch/arm64/boot/Image"
[ -f "$IMG" ] || { echo "[FAIL] 未生成 Image"; exit 1; }
cp -f "$IMG" "$OUT/$TAG"

DTB=""
for c in out/arch/arm64/boot/dtb out/arch/arm64/boot/dtb.img out/dtb; do
  [ -f "$c" ] && DTB="$c" && break
done
if [ -z "$DTB" ]; then
  DTB=$(find out -maxdepth 4 -name 'dtb' -type f -size +10k 2>/dev/null | head -1)
fi
if [ -n "$DTB" ]; then
  cp -f "$DTB" "$OUT/${TAG}.dtb"; log "  dtb  ← $DTB"
else
  log "  [WARN] 未找到 qcdt dtb 产物"
fi

DTBO=$(find out -maxdepth 4 -name 'dtbo.img' -type f 2>/dev/null | head -1)
if [ -n "$DTBO" ]; then
  cp -f "$DTBO" "$OUT/${TAG}_dtbo.img"; log "  dtbo ← $DTBO"
else
  log "  [WARN] 未找到 dtbo.img"
fi

cp -f out/.config "$OUT/$TAG.config"

# -------- CRC 一致性：这棵树到底是不是出厂那份源码，这里最直接 -----------
if [ -f out/vmlinux ] && [ -f "$HERE/stock_crc.txt" ]; then
  log "===== 导出符号 CRC 与原厂对比 ====="
  python3 "$HERE/crc_verify.py" out/vmlinux "$HERE/stock_crc.txt" 2>&1 \
    | tee "$OUT/$TAG.crc" | tail -12 || log "  CRC 校验脚本出错（不影响产物）"
fi

# --------------------------------------------------------------- 7. 汇报
log "===== 产物摘要 ====="
for f in "$OUT/$TAG" "$OUT/${TAG}.dtb" "$OUT/${TAG}_dtbo.img"; do
  [ -f "$f" ] && printf '  %-40s %10d B  md5=%s\n' \
    "$(basename "$f")" "$(stat -c%s "$f")" "$(md5sum "$f" | cut -d' ' -f1)"
done
echo "  --- vermagic ---"
grep -a -o "4\.19\.[0-9]*-perf+[ -~]\{0,60\}" "$OUT/$TAG" | sort -u | head -3
echo "  --- KSU 痕迹 ---"
for s in KernelSU ksu_ KSU_SYSCALL; do
  printf '  %-14s %s\n' "$s" "$(grep -a -o "$s" "$OUT/$TAG" | wc -l)"
done
log "PHASE=$PHASE 完成"
