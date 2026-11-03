#!/usr/bin/env bash
# =============================================================================
# build_all.sh —— 本工程**一键复现**：源码 → 比特流 + 四镜像 + 卡镜像
#
# 设计口径（照本工程实测过的命令，不发明新机制）：
#   · 每个阶段**只做一件事**，跑完立刻打**产物指纹**（字节数 + md5）⇒ 可对账、可断点续跑
#   · 每个阶段可单独跑：`--only <阶段>` / 从某阶段起：`--from <阶段>` / 跳过：`--skip <阶段>`
#   · 默认**不**跑 core（核网表很少变，且要 sbt；要跑就显式加 core）
#   · 阶段之间环境不同（Windows 工具 / WSL），脚本负责分发 —— 本脚本在 **Git Bash(Windows)** 里跑
#
# 阶段（顺序）：
#   core    核网表          scripts/gen_core.sh                     (Windows, sbt)
#   glue    Chisel 胶合      scala-cli package --assembly + java -jar (Windows)
#   liteeth LiteEth 黑盒     sim/liteeth_gen/gen_liteeth.py          (Windows, **必须 Python 3.9**)
#   devmap  PDS dev_map     pds/run_devmap_yeshen.tcl + 闸门检查      (Windows)
#   pnr     PnR + 比特流     pds/run_pnr_yeshen.tcl                  (Windows)
#   images  四镜像          scripts/build_images.sh (在 WSL)          (WSL + 可选代理 relay)
#   sdimg   卡镜像          sim/mk_sd_image.py                       (Windows)
#
# 用法：
#   bash scripts/build_all.sh                            # glue liteeth devmap pnr images sdimg
#   bash scripts/build_all.sh --with-core                # 连核网表一起
#   bash scripts/build_all.sh --only images,sdimg        # 只重做镜像与卡镜像（改了内核补丁/DTS 后常用）
#   bash scripts/build_all.sh --from pnr                 # 从 PnR 起（RTL 变了、镜像没变）
#   TAG=m10 bash scripts/build_all.sh --from devmap      # 换交付标签（默认 m9）
#
# 关键环境变量：
#   TAG              交付标签（比特流工程目录名 / flash 脚本用它）默认 m9
#   REBUILD_PKGS     传给 build_images.sh；改了内核补丁/overlay/DTS 必须 "linux"（默认透传）
#   JOBS             并发（build_images 用）
#   代理：改了内核/包需要下载时，先在 Windows 起 scripts/win_proxy_relay.py（WSL 够不到 Clash 的 127.0.0.1）
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 9
ROOT=$(pwd -P)
TAG=${TAG:-m9}
LOG_DIR="$ROOT/sim/reglogs"
mkdir -p "$LOG_DIR"

# --- 工具路径（可用环境变量覆盖）---
PDS_BIN=${PDS_BIN:-/c/Pango/PDS_2025.2-ads/bin}
SC=${SC:-/c/Users/Ziqi/AppData/Local/Coursier/data/bin/scala-cli.bat}
PY39=${PY39:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}
WS_IMG="$ROOT/sw/images"

ALL_STAGES=(glue liteeth devmap pnr images sdimg)
ONLY=""; FROM=""; SKIP=""; WITH_CORE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY=$2; shift 2;;
    --from) FROM=$2; shift 2;;
    --skip) SKIP=$2; shift 2;;
    --with-core) WITH_CORE=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "!! 未知参数 $1"; exit 2;;
  esac
done

# 组装本次要跑的阶段列表
STAGES=()
if [ -n "$ONLY" ]; then
  IFS=',' read -r -a STAGES <<< "$ONLY"
else
  [ "$WITH_CORE" = 1 ] && STAGES+=(core)
  started=0
  for s in "${ALL_STAGES[@]}"; do
    if [ -n "$FROM" ]; then
      [ "$s" = "$FROM" ] && started=1
      [ "$started" = 0 ] && continue
    fi
    STAGES+=("$s")
  done
  if [ -n "$FROM" ] && [ "$started" = 0 ]; then echo "!! --from 的阶段名不认识: $FROM"; exit 2; fi
fi
if [ -n "$SKIP" ]; then
  IFS=',' read -r -a _sk <<< "$SKIP"
  keep=()
  for s in "${STAGES[@]}"; do
    drop=0; for k in "${_sk[@]}"; do [ "$s" = "$k" ] && drop=1; done
    [ "$drop" = 0 ] && keep+=("$s")
  done
  STAGES=("${keep[@]}")
fi

phase() { echo; echo "========== [$1] $* =========="; }
fp() {  # 指纹：字节数 + md5
  local f=$1
  if [ -f "$f" ]; then printf '  %-52s %10d B  md5=%s\n' "$f" "$(wc -c < "$f")" "$(md5sum "$f" | cut -d' ' -f1)"
  else printf '  %-52s MISSING\n' "$f"; fi
}
die() { echo "!! $*"; exit 1; }

echo "=== build_all：TAG=$TAG  阶段=${STAGES[*]} ==="
echo "=== ROOT=$ROOT ==="

for st in "${STAGES[@]}"; do
  case "$st" in

  core)
    phase core "核网表（VexiiRiscv，需 sbt + third_party 克隆）"
    bash scripts/gen_core.sh > "$LOG_DIR/build_all_core.log" 2>&1 || die "gen_core.sh 失败（见 $LOG_DIR/build_all_core.log）"
    fp rtl/vexiiriscv/VexiiRiscv.v
    ;;

  glue)
    phase glue "Chisel 胶合 → rtl/YeshenSocGlue.v"
    # ⚠️ 必须打 assembly jar 再 java -jar（scala-cli run 会撞 CreateProcess error 206 命令行过长）
    "$SC" --power package src --assembly -o YeshenSocGlue.jar --main-class YeshenSocGlueMain -f \
      > "$LOG_DIR/build_all_glue.log" 2>&1 || die "scala-cli package 失败（见 $LOG_DIR/build_all_glue.log）"
    java -jar YeshenSocGlue.jar >> "$LOG_DIR/build_all_glue.log" 2>&1 || die "java -jar 失败（见 $LOG_DIR/build_all_glue.log）"
    grep -q "^module YeshenSocGlue" rtl/YeshenSocGlue.v || die "rtl/YeshenSocGlue.v 里没有模块头"
    fp rtl/YeshenSocGlue.v
    ;;

  liteeth)
    phase liteeth "LiteEth 黑盒 → third_party/liteeth_mac/liteeth_mac_top.v"
    [ -x "$PY39" ] || die "Python 3.9 venv 不存在：$PY39（黑盒生成**必须** 3.9，见 third_party/PINS.md）"
    "$PY39" sim/liteeth_gen/gen_liteeth.py > "$LOG_DIR/build_all_liteeth.log" 2>&1 \
      || die "gen_liteeth 失败（见 $LOG_DIR/build_all_liteeth.log）"
    fp third_party/liteeth_mac/liteeth_mac_top.v
    ;;

  devmap)
    phase devmap "PDS dev_map（资源 + DRC 预检，作为跑 PnR 前的闸门）"
    rm -f "$LOG_DIR/build_all_devmap.log"
    "$PDS_BIN/pds_shell.exe" -file "D:/code/PDS/VexiiYeshenLinux/pds/run_devmap_yeshen.tcl" \
      > "$LOG_DIR/build_all_devmap.log" 2>&1 || die "pds_shell 非零退出（见 $LOG_DIR/build_all_devmap.log）"
    grep -q "YESHENMINI_DEVMAP_DONE" "$LOG_DIR/build_all_devmap.log" || die "dev_map 没跑到 DONE（见日志）"
    python scripts/check_devmap.py "$LOG_DIR/build_all_devmap.log" || die "dev_map 闸门不过（0 error / 0 DRC 才算过）"
    grep -aA10 "Device Utilization Summary" "$LOG_DIR/build_all_devmap.log" | grep -aE "LUT|FF|DRM|APM|IO " | sed 's/^/  /'
    ;;

  pnr)
    phase pnr "PnR + 比特流（TAG=$TAG，复用刚建好的 devmap 工程）"
    YESHENMINI_PNR_TAG=$TAG "$PDS_BIN/pds_shell.exe" -file "D:/code/PDS/VexiiYeshenLinux/pds/run_pnr_yeshen.tcl" \
      > "$LOG_DIR/build_all_pnr_$TAG.log" 2>&1 || die "PnR 非零退出（见 $LOG_DIR/build_all_pnr_$TAG.log）"
    grep -q "YESHENMINI_PNR_DONE" "$LOG_DIR/build_all_pnr_$TAG.log" || die "PnR 没跑到 DONE（见日志）"
    # ⚠️ 判据必须读**报告本体**（`Design Summary : All Constraints Met.`）：
    #    以前 grep 的是日志里的 "All Constraints Met" —— 而那句话**也出现在 tcl 自己的
    #    `puts "=== pnr: report_timing（判据 1：看 All Constraints Met …）==="` 里**
    #    ⇒ 闸门恒真（2026-10-25 实测：sdcrc1 seed3 有 1 条 −0.005 ns 违例，闸门照样绿）。
    #    以后要改 tcl 的这句话，别再把判据串写进注释/puts。
    RTR="sim/reglogs/pds_${TAG}_p10.000/prj_tasks/pnr_1/place_route/report_timing/yeshen_mini_board_top.rtr"
    [ -f "$RTR" ] || die "没找到时序报告：$RTR"
    grep -aq "Design Summary : All Constraints Met" "$RTR" \
      || die "时序未收敛（Design Summary 不是 All Constraints Met，见 $RTR）"
    SB="sim/reglogs/pds_${TAG}_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit"
    [ -f "$SB" ] || die "比特流没生成：$SB"
    grep -a -A12 "Performance Summary" "$RTR" | grep -aE "MHz|Period|Slack|^ [a-z]" | sed 's/^/  /'
    echo "  [ok] Design Summary = All Constraints Met"
    fp "$SB"
    ;;

  images)
    phase images "四镜像（在 WSL 里编；改了内核补丁/overlay/DTS 要 REBUILD_PKGS=linux）"
    [ -n "${REBUILD_PKGS:-}" ] && echo "  REBUILD_PKGS=${REBUILD_PKGS}"
    RK=""; [ -n "${REBUILD_PKGS:-}" ] && RK="REBUILD_PKGS=\"$REBUILD_PKGS\""
    # 代理：需要下载时先在 Windows 起 scripts/win_proxy_relay.py；这里透传（连不上也不致命，只是不能下新包）
    wsl -e bash -lc "cd /mnt/d/code/PDS/VexiiYeshenLinux && export http_proxy=http://172.21.128.1:7898 https_proxy=http://172.21.128.1:7898 && export no_proxy=\"sources.buildroot.net,buildroot.net,localhost,127.0.0.1\" && $RK bash scripts/build_images.sh" \
      > "$LOG_DIR/build_all_images.log" 2>&1
    grep -aq "DONE" "$LOG_DIR/build_all_images.log" || die "build_images 没跑到 DONE（见 $LOG_DIR/build_all_images.log）"
    for f in fw_jump.bin Image linux.dtb rootfs.cpio; do fp "$WS_IMG/$f"; done
    ;;

  sdimg)
    phase sdimg "卡镜像 sd.img（SdLoader 装载表 + 四镜像）"
    for f in fw_jump.bin Image linux.dtb rootfs.cpio; do
      [ -f "$WS_IMG/$f" ] || die "缺 $WS_IMG/$f（先跑 images 阶段）"
    done
    python sim/mk_sd_image.py --out "$WS_IMG/sd.img" \
      --entry 0x80000000="$WS_IMG/fw_jump.bin" \
      --entry 0x82000000="$WS_IMG/Image" \
      --entry 0x82F80000="$WS_IMG/linux.dtb" \
      --entry 0x83000000="$WS_IMG/rootfs.cpio" || die "mk_sd_image 失败"
    # 自证：段内字节必须与源文件逐字节相同（防止"算完忘 write / 拼错路径"这类静默错）
    # ⚠️ 段偏移**从块 0 的表里读**，不写死：镜像大小一变（dtb 4→5 块）写死的偏移就会
    #    比到错的位置、报假红（2026-10-25 实测踩过）。
    python - "$WS_IMG" <<'PY' || die "sd.img 段内校验不过"
import hashlib, sys, os, struct, zlib
d = sys.argv[1]
img = open(os.path.join(d, "sd.img"), "rb").read()
names = {0x82000000: "Image", 0x82F80000: "linux.dtb", 0x83000000: "rootfs.cpio"}
n = struct.unpack(">I", img[4:8])[0]
ok = img[:4] == b"YSLD"
for i in range(n):
    addr, sb, nb = struct.unpack(">III", img[8 + 12 * i:20 + 12 * i])
    want_crc = struct.unpack(">I", img[128 + 4 * i:132 + 4 * i])[0]
    seg = img[sb * 512:(sb + nb) * 512]
    if zlib.crc32(seg) & 0xFFFFFFFF != want_crc:
        print(f"  段 {i} ({addr:#x}) CRC MISMATCH"); ok = False
    if addr in names:
        cur = open(os.path.join(d, names[addr]), "rb").read()
        same = seg[:len(cur)] == cur and not any(seg[len(cur):])
        ok &= same
        print(f"  段内校验 {names[addr]:14s} {'ok' if same else 'MISMATCH'}  (blk {sb}, crc {want_crc:08X})")
hdr_crc = struct.unpack(">I", img[160:164])[0]
if zlib.crc32(img[:160]) & 0xFFFFFFFF != hdr_crc:
    print("  表头 CRC MISMATCH"); ok = False
print("  sd.img md5 =", hashlib.md5(img).hexdigest())
sys.exit(0 if ok else 1)
PY
    fp "$WS_IMG/sd.img"
    ;;

  *) die "未知阶段: $st";;
  esac
done

# ---- 收尾：指纹总表 ----
phase done "指纹总表（把这张表抄进交付记录，别只记'跑过了'）"
fp "sim/reglogs/pds_${TAG}_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit"
for f in fw_jump.bin Image linux.dtb rootfs.cpio sd.img; do fp "$WS_IMG/$f"; done
echo
echo "下一步：写卡（先 Get-Disk 核对盘号）→ 烧板 → 判据，见 docs/board_bringup.md"
