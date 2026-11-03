#!/usr/bin/env bash
# ===================== GPU 译码窗口的负对照 =====================
# 纪律同 negctl_pbus.sh：判据必须能翻红。这里用 patch_exact.py 对 **输入件** rtl/YeshenSocGlue.v
#   做**精确的单行变异**：把 GPU **读窗基址**从 20'hF0005 改到 20'hF0085（= 0xF0085000，无人译码）。
#   ⇒ 判据 ⑦c 的两笔 GPU 读全部落到未译码路径（rresp=DECERR、rdata=0、io_gpuAxi_arvalid=0）
#   ⇒ 装置必须报 `=== TEST FAILED ===`。
#   （只动读窗；写窗 isGpuW 不动 ⇒ 变异的"恰好是一个译码窗口"。）
#
# 用法（WSL）：bash sim/glue_pbus/negctl_gpu_pbus.sh
# ⚠️ 变异只用于跑负对照；跑完**必须**把 rtl/YeshenSocGlue.v 恢复成与原文件**逐字节一致**（记 md5）。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R" || exit 2
SRC=rtl/YeshenSocGlue.v
BAK=/tmp/yeshensocglue_gpu_negctl_bak.v

cp "$SRC" "$BAK" || exit 2
MD5_BEFORE=$(md5sum "$SRC" | awk '{print $1}')
echo "[nc] 原始 rtl/YeshenSocGlue.v md5 = $MD5_BEFORE"

restore() { cp "$BAK" "$SRC"; }
trap restore EXIT

# ---- 精确单行变异：GPU 读窗基址 20'hF0005 -> 20'hF0085 ----
if ! python3 sim/glue_pbus/patch_exact.py "$SRC" \
      "io_cpuIo_araddr[31:12] == 20'hF0005" \
      "io_cpuIo_araddr[31:12] == 20'hF0085"; then
  echo "[nc] ✗ 补丁未命中（RTL 变了吗？）"; exit 4
fi
MD5_MUT=$(md5sum "$SRC" | awk '{print $1}')
echo "[nc] 变异后 md5 = $MD5_MUT（应与原始不同）"
if [ "$MD5_MUT" = "$MD5_BEFORE" ]; then echo "[nc] ✗ 变异没有改变文件"; exit 4; fi

# ---- 用**变异后的网表**重建并跑装置 ----
bash sim/glue_pbus/run_unit.sh > "$R/sim/reglogs/pbus_gpu_negctl.log" 2>&1
cp "$R/sim/reglogs/pbus_unit.log" "$R/sim/reglogs/pbus_gpu_negctl_device.log" 2>/dev/null || true
v=$(grep -aoE "TEST (PASSED|FAILED)" "$R/sim/reglogs/pbus_gpu_negctl.log" | tail -1)
echo "[nc] 变异后判定 => ${v:-NO-VERDICT}（期望 TEST FAILED）"
grep -aE "\[FAIL\]|^=== |BUILD_FAIL|NO-VERDICT" "$R/sim/reglogs/pbus_gpu_negctl.log" | head -12 | sed 's/^/     /'

# ---- 恢复输入件并核对逐字节一致 ----
restore
MD5_AFTER=$(md5sum "$SRC" | awk '{print $1}')
echo "[nc] 恢复后 md5 = $MD5_AFTER"
if [ "$MD5_AFTER" != "$MD5_BEFORE" ]; then
  echo "[nc] ✗ 恢复后 md5 与原文件不一致！"; exit 5
fi
echo "[nc] 恢复后与原 rtl/YeshenSocGlue.v **逐字节一致**（md5 相同）"

if [ "$v" = "TEST FAILED" ]; then
  echo "=== 负对照结论：GPU 窗单行变异被装置当场翻红（TEST FAILED）=> 判据确有区分力 ==="
  exit 0
else
  echo "=== 负对照结论：异常！变异后装置没有翻红 => 判据没有测到它声称的那一处 ==="
  exit 1
fi
