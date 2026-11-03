#!/usr/bin/env bash
# 代理下的 sbt 包装：本机 sbt 在 Coursier 的 bin 目录（不在 PATH 上），且需走 127.0.0.1:7897 拉依赖。
set -euo pipefail
export JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-17.0.20.8-hotspot"
export PATH="$JAVA_HOME/bin:/c/Users/Ziqi/AppData/Local/Coursier/data/bin:$PATH"
ADDR="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897"
exec sbt.bat $ADDR "$@"
