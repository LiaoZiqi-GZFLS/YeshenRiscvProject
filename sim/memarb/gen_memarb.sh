#!/bin/bash
# ===================== MemArbiter 单元测试网表生成 =====================
# 产出 `build_memarb/MemArbiter.v`（`build_*` 在 .gitignore 里，不入库），
# 供 `sim/memarb/run_unit.sh` 用 verilator `--top-module MemArbiter` 装配单元装置。
#
# 环境：Chisel 生成在 **Windows**（scala-cli 组装 jar + java 跑 firtool）。本脚本在 WSL 或
#   git-bash 里都能跑（WSL 下经 cmd.exe 调 Windows 的 java），写法照抄 `sim/ddr3bridge/gen_bridge.sh`。
# 用法：bash sim/memarb/gen_memarb.sh
#   REBUILD_JAR=1（默认）先重建 `YeshenSocGlue.jar`（与 build_all.sh 的 glue 阶段同一条命令）；
#   REBUILD_JAR=0 跳过（jar 已是最新时省时间）。
set -u
# 仓库根**从脚本自身位置反推**（历史上多个闸门写死过别的 checkout 的路径 ⇒ 会打错树）。
ROOT_MSYS="$(cd "$(dirname "$0")/../.." && pwd)"
in_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }
if in_wsl; then
  R_WIN="$(wslpath -w "$ROOT_MSYS")"
else
  R_WIN="$(cd "$ROOT_MSYS" && pwd -W 2>/dev/null | tr '/' '\\')"
  [ -n "$R_WIN" ] || R_WIN="$ROOT_MSYS"
fi
OUT=${OUT:-build_memarb}
SCALA_CLI='C:\Users\Ziqi\AppData\Local\Coursier\data\bin\scala-cli.bat'
echo "[gen] 仓库根（Windows）= $R_WIN"

win_run() {  # $1 = Windows 侧命令行
  if in_wsl; then
    /mnt/c/Windows/System32/cmd.exe /c "cd /d $R_WIN && $1"
  else
    eval "$1"
  fi
}

if [ "${REBUILD_JAR:-1}" = "1" ]; then
  echo "[gen] 重建 YeshenSocGlue.jar（scala-cli assembly，Windows 侧）..."
  win_run "$SCALA_CLI --power package src --assembly -o YeshenSocGlue.jar --main-class YeshenSocGlueMain -f" \
    > /tmp/memarb_jar.log 2>&1 || { echo "[gen] JAR 构建失败，见 /tmp/memarb_jar.log"; tail -20 /tmp/memarb_jar.log; exit 1; }
  echo "[gen] jar ok"
fi

echo "[gen] 生成 $OUT/MemArbiter.v ..."
win_run "java -cp YeshenSocGlue.jar MemArbiter $OUT" > /tmp/memarb_gen.log 2>&1 \
  || { echo "[gen] 生成失败，见 /tmp/memarb_gen.log"; tail -20 /tmp/memarb_gen.log; exit 1; }
tail -2 /tmp/memarb_gen.log
ls -l "$OUT/MemArbiter.v" || exit 1
grep -c "module MemArbiter" "$OUT/MemArbiter.v" > /dev/null || { echo "[gen] 产物里没有 module MemArbiter"; exit 1; }
echo "[gen] ok：$OUT/MemArbiter.v"
