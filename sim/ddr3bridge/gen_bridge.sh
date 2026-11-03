#!/bin/bash
# ===================== DDR3Bridge 单元测试网表生成 =====================
# 产出 `build_ddr/DDR3Bridge.v`（`build_*/` 在 .gitignore 里，不入库），
# 供 `sim/ddr3bridge/run_unit.sh` 用 verilator `--top-module DDR3Bridge` 装配单元装置。
#
# 环境：Chisel 生成在 **Windows**（scala-cli 组装 jar + java 跑 firtool）。
#   本脚本在 WSL 或 git-bash 里都能跑：WSL 下经 `cmd.exe` 调 Windows 的 java。
# 用法：bash sim/ddr3bridge/gen_bridge.sh
#   REBUILD_JAR=1（默认）先重建 `NaxMiniGlue.jar`（与 NaxMiniGlueMain 同一条 scala-cli 命令）；
#   REBUILD_JAR=0 跳过（jar 已是最新时省时间）。
set -u
# 仓库根**从脚本自身位置反推**（`<repo>/sim/ddr3bridge/gen_bridge.sh`）：
#   本脚本历史上写死过 `D:\code\PDS\NaxYeshenLinux`，本仓库（VexiiYeshenLinux）搬过家 ⇒
#   写死会去生成**另一棵 checkout** 的网表（`git remote` 都不同），产物与本仓库源码无关。
ROOT_MSYS="$(cd "$(dirname "$0")/../.." && pwd)"
in_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }
if in_wsl; then
  R_WIN="$(wslpath -w "$ROOT_MSYS")"          # /mnt/d/... -> D:\...
else
  R_WIN="$(cd "$ROOT_MSYS" && pwd -W 2>/dev/null | tr '/' '\\')"   # git-bash: /d/... -> D:\...
  [ -n "$R_WIN" ] || R_WIN="$ROOT_MSYS"
fi
OUT=${OUT:-build_ddr}
SCALA_CLI='C:\Users\Ziqi\AppData\Local\Coursier\data\bin\scala-cli.bat'
echo "[gen] 仓库根（Windows）= $R_WIN"

# cmd.exe 调 Windows 命令（WSL 下用；git-bash 下直接跑）
win_run() {  # $1 = Windows 侧命令行
  if in_wsl; then
    /mnt/c/Windows/System32/cmd.exe /c "cd /d $R_WIN && $1"
  else
    eval "$1"
  fi
}

if [ "${REBUILD_JAR:-1}" = "1" ]; then
  echo "[gen] 重建 NaxMiniGlue.jar（scala-cli assembly，Windows 侧）..."
  # 注意：scala-cli.bat 的路径里没有空格 ⇒ 不要加引号（经 cmd.exe 时反斜杠转义引号会被当成字面量）
  win_run "$SCALA_CLI --power package src --assembly -o NaxMiniGlue.jar --main-class NaxMiniGlueMain -f" \
    > /tmp/ddr3bridge_jar.log 2>&1 || { echo "[gen] JAR 构建失败，见 /tmp/ddr3bridge_jar.log"; tail -20 /tmp/ddr3bridge_jar.log; exit 1; }
  echo "[gen] jar ok"
fi

echo "[gen] 生成 $OUT/DDR3Bridge.v ..."
win_run "java -cp NaxMiniGlue.jar DDR3Bridge $OUT" > /tmp/ddr3bridge_gen.log 2>&1 \
  || { echo "[gen] 生成失败，见 /tmp/ddr3bridge_gen.log"; tail -20 /tmp/ddr3bridge_gen.log; exit 1; }
tail -3 /tmp/ddr3bridge_gen.log
ls -l "$OUT/DDR3Bridge.v" || exit 1
grep -c "module DDR3Bridge" "$OUT/DDR3Bridge.v" > /dev/null || { echo "[gen] 产物里没有 module DDR3Bridge"; exit 1; }
echo "[gen] ok：$OUT/DDR3Bridge.v"
