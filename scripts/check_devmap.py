#!/usr/bin/env python3
# ============================================================================
# check_devmap.py -- Task 14 的 dev_map 判据（**会红**才算判据）
#
# 用法:
#   python scripts/check_devmap.py sim/reglogs/m3_devmap.log ; echo "rc=$?"
#
# 判据（三条**全满足**才 PASS，退出码 0）:
#   1. 日志里出现 `*_DEVMAP_DONE`（脚本跑到底，没在中途 exit/崩）。
#      ⚠️ 本工程是 `YESHENMINI_DEVMAP_DONE`（模板是 `NAXMINI_DEVMAP_DONE`）——这里按
#         `<前缀>_DEVMAP_DONE` 通配，避免改名后判据"恒红"（脚本口径自己也要审）。
#   2. 日志里出现 `has been successfully mapped`（dev_map 真的成功）
#   3. **零 `E:` 行、零 `DRC-` 字样**（任何一条命中就红）
#
# 为什么第 3 条要同时查 `E:` 与 `DRC-`:
#   * PDS 的错误行是 `E: ...`（编译/综合/映射的硬错误，dev_map 会带着它"成功"结束的情况
#     在本仓库出现过：引脚非法球号时既有 `E:` 又有 DRC）；
#   * DRC 违规是 `DRC-xxxx` 形式的规则检查报告 —— 它**不一定**带 `E:` 前缀，
#     例如 `DRC-0002 : ...` 出现在 Device Map Report 里；只看 `E:` 会漏掉 DRC。
#
# ⚠️ 判据的"会红"验证（Task 14 Step 5 实测做过）: 把 fdc 里一个 PAP_IO_LOC 改成非法球号
#    （例如 led[0] 的 A20 → R99），本脚本必须 FAIL 并打印命中行；改回后 PASS。
#    负例日志: sim/reglogs/m3_devmap_negctl.log
# ============================================================================
import re
import sys
import pathlib

# 良性 DRC 白名单（**要放行**；见 memory「PDS 静默常量折叠审查 / 良性白名单」纪律）：
#   * DRC-4010：厂家 eth 栈 `third_party/eth_stack_2_11/source/icmp.v:37` 内部的 tri-state
#     被裁成 GND（报错实例 u_soc/u_eth_mac/u_stack/ip_layer/icmp/icmp_tx_end）。我们只走 UDP，
#     从不用 ICMP，故该 datapath 恒不使能 ⇒ 结构性良性。
#     证据：该行在 eth 集成后的历次 dev_map 都在（eth_devmap4/5/6/7），而据此出的比特流
#     （sim/reglogs/eth_por.sbit）**上板实测可 ping、可收 UDP** ⇒ 实测良性。
#     ⚠️ 只放行 `W:` 严重度；若 PDS 把某 DRC 报成 `E:` 前缀，上面第 1 条照样红。
BENIGN_DRC = {4010}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_devmap.py <pds_devmap_log>")
        return 2
    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print("FAIL: log not found: %s" % path)
        return 2

    log = path.read_text(encoding="utf-8", errors="replace")
    lines = log.splitlines()

    ok_done = re.search(r"\b\w+_DEVMAP_DONE\b", log) is not None
    # PDS 的产物行形如: Design 'yeshen_mini_board_top' has been successfully mapped.
    ok_map = "has been successfully mapped" in log

    hits = []
    for i, l in enumerate(lines, 1):
        if re.search(r"^\s*E:\s", l):
            hits.append((i, l.strip()))
            continue
        m = re.search(r"\bDRC-(\d+)", l)
        if m and int(m.group(1)) not in BENIGN_DRC:
            hits.append((i, l.strip()))

    if ok_done and ok_map and not hits:
        print("PASS: dev_map 0 error（%s）" % path)
        return 0

    print("FAIL: dev_map")
    print("  log=%s" % path)
    print("  done=%s mapped=%s drc_or_error_hits=%d" % (ok_done, ok_map, len(hits)))
    for ln, txt in hits[:40]:
        print("  - L%d: %s" % (ln, txt))
    if len(hits) > 40:
        print("  ... (%d more)" % (len(hits) - 40))
    return 1


if __name__ == "__main__":
    sys.exit(main())
