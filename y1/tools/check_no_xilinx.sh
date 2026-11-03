#!/usr/bin/env bash
# 判据：生成网表里不得出现任何 Xilinx 原语/IP 例化名。
# 用法: check_no_xilinx.sh <gen_dir>
# 退出码：0 = PASS（零命中）；1 = FAIL（有命中）；非零均视为判据未过。
#
# 覆盖范围（B5–B9 的净交付里出现过的全部 Xilinx 名字）：
#   B5 内存 : xpm_memory_sdpram / xpm_memory_sprom / blk_mem_gen
#   B6 FIFO : xpm_fifo_sync
#   B7 MAC  : dsp_macro   (+ xpm_cdc：原 DSP IP 内部用 xpm_cdc_gray 做跨时钟)
#   B8 乘法 : mult_gen
#   B9 IP   : c_addsub（AddZero/addAdd/addAdd64_64/biasAdd/concatAdd/leakyAddZ3/leakySubZ3
#             这 7 个黑盒的 IP 本名）/ axis_dwidth_converter（conv11DataCvt 黑盒的 IP 本名）
#             + 生成它们用的 tcl 命令 create_ip / get_ips
#
# 只判「真代码」：先剥掉 /* */ 块注释与 // 行注释，再对剩下的代码匹配。
# 理由：网表里把「已停用的 Xilinx IP」写成**注释**时会留下 IP 名
#（如 B7 在 gen/DspTop.v 里写 "this used to be a Xilinx dsp_macro IP instance"），
# 那是**移除记录**、不是残留；不剥注释会把它当命中 ⇒ 假阳性。负对照证明本判据仍有区分度。
set -uo pipefail
d="${1:?usage: check_no_xilinx.sh <gen_dir>}"
[ -e "$d" ] || { echo "FATAL: 目录不存在 $d"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: 需要 perl 才能剥注释"; exit 2; }

# ⚠ 2026-10-08 修正（继承缺陷）：原来各选项**没有左锚定**，于是 `c_addsub` 会命中 CPU 网表里
#   一个叫 `logic_addsub_combined_rs2` 的**内部信号名**（子串）⇒ 对整个 `rtl/` 查会**假 FAIL**，
#   而那个文件与 Xilinx 毫无关系（实测：`rtl` 报 10 hits，`rtl/YeshenSocGlue.v` 报 0 hits）。
#   修法 = **左锚定 `\b`**（要求命中处前面是非单词字符，即它是个标识符的**开头**）。
#   为什么**不**两侧都锚：本判据**故意**用 `xpm_cdc` 前缀去命中 `xpm_cdc_gray`（见上面 B7 行），
#   右侧再加 `\b` 会把这条前缀匹配废掉。
pat='\b(xpm_memory_sdpram|xpm_memory_sprom|xpm_fifo_sync|xpm_cdc|dsp_macro|mult_gen|blk_mem_gen|c_addsub|axis_dwidth_converter|create_ip|get_ips)'

strip_comments() { perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g'; }

hits=0
while IFS= read -r -d '' f; do
  m="$(strip_comments < "$f" | grep -nE "$pat" || true)"
  [ -z "$m" ] && continue
  printf 'HIT %s\n' "$f"
  printf '%s\n' "$m"
  hits=$(( hits + $(printf '%s\n' "$m" | wc -l) ))
done < <(find "$d" -type f -print0 2>/dev/null)

echo "xilinx-residual hits: $hits"
if [ "$hits" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
