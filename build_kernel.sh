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
grep -q 'drivers/kernelsu/Kconfig' Kconfig || \
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' Kconfig
ls -l kernelsu | sed 's/^/    /'

# ---------------------------------------------------------------- 5. 配置内核
cd "$WORK/kernel"
log "生成 defconfig: $DEFCONFIG"
make ARCH=arm64 O=out "$DEFCONFIG"

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
make ARCH=arm64 O=out olddefconfig

grep -E "^CONFIG_(KSU|KPROBES|KALLSYMS_ALL|MODVERSIONS|MODULE_SIG)" out/.config || true

# ---------------------------------------------------------------- 6. 编译
log "开始编译 Image（jobs=$JOBS）"
make -j"$JOBS" ARCH=arm64 O=out \
  CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  KCFLAGS="-Wno-error" \
  Image

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
