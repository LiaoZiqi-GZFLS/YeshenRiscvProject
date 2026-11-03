#!/bin/bash
# ===================== YeshenSocGlue 网表重生成（与 scripts/build_all.sh 的 glue 阶段同一条命令）=====
# 产出 rtl/YeshenSocGlue.v（**交付产物**，入库）。
# 用法：bash sim/glue_pbus/gen_glue.sh
#   REBUILD_JAR=1（默认）先重建 YeshenSocGlue.jar（scala-cli assembly，Windows 侧）；
#   REBUILD_JAR=0 跳过（jar 已是最新时省时间）。
# 环境：Chisel 生成在 Windows；本脚本在 WSL 或 git-bash 里都能跑（WSL 下经 cmd.exe 调 java）。
set -u
ROOT_MSYS="$(cd "$(dirname "$0")/../.." && pwd)"
in_wsl() { grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }
if in_wsl; then R_WIN="$(wslpath -w "$ROOT_MSYS")"; else R_WIN="$(cd "$ROOT_MSYS" && pwd -W 2>/dev/null | tr '/' '\\')"; [ -n "$R_WIN" ] || R_WIN="$ROOT_MSYS"; fi
SCALA_CLI='C:\Users\Ziqi\AppData\Local\Coursier\data\bin\scala-cli.bat'
echo "[glue] 仓库根（Windows）= $R_WIN"
win_run() { if in_wsl; then /mnt/c/Windows/System32/cmd.exe /c "cd /d $R_WIN && $1"; else eval "$1"; fi; }

if [ "${REBUILD_JAR:-1}" = "1" ]; then
  echo "[glue] 重建 YeshenSocGlue.jar（scala-cli assembly）..."
  win_run "$SCALA_CLI --power package src --assembly -o YeshenSocGlue.jar --main-class YeshenSocGlueMain -f" \
    > /tmp/glue_jar.log 2>&1 || { echo "[glue] JAR 构建失败，见 /tmp/glue_jar.log"; tail -25 /tmp/glue_jar.log; exit 1; }
  echo "[glue] jar ok"
fi
echo "[glue] 生成 rtl/YeshenSocGlue.v ..."
win_run "java -jar YeshenSocGlue.jar" > /tmp/glue_gen.log 2>&1 || { echo "[glue] 生成失败，见 /tmp/glue_gen.log"; tail -25 /tmp/glue_gen.log; exit 1; }
grep -q "^module YeshenSocGlue" "$ROOT_MSYS/rtl/YeshenSocGlue.v" || { echo "[glue] 产物里没有模块头"; exit 1; }
md5sum "$ROOT_MSYS/rtl/YeshenSocGlue.v"
echo "[glue] ok"
