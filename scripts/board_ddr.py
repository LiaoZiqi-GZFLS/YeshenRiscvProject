#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_ddr.py —— 把大块映像经**网络**投进板内 DDR（Y1 C4b-F1 的 "net/dd" 通路）。

============================ 这条路为什么存在 ============================
C4b-B5 的 `npu_frame_run.py --run` 曾经**无论 `--xfer` 是什么**都走 `devmem` 逐字灌；
1.2 MB 的 input（307200 word）撞上 R5 守卫（`--uart-word-limit`）⇒ 整帧跑不起来。
F1 把它补成真正的网络通路，并且**顺手证伪了"用 dd 就行"**：

  `dd if=X of=/dev/mem bs=4096 seek=$((phys/4096))` 在 phys=0x801F0000 上**内核 oops**：
      Unable to handle kernel paging request at virtual address be1f4000
      status: 00040120 badaddr: be1f4000 cause: 0x0f   Comm: dd
  因为 riscv32 /dev/mem 的 **read/write 系统调用**路径是 `xlate_dev_mem_ptr(p)=__va(p)`
  （线性映射换算），而 H2b 之后内存节点从 phys 0x8200_0000 起 ⇒ 任何 phys < 0x8200_0000
  算出来的 __va 都在 PAGE_OFFSET(0xBE00_0000) **之下、无映射** ⇒ 内核 oops。
  busybox 的 `devmem` 走的是 **mmap**（ioremap 一路）⇒ 同址读写没问题。

所以本文件的"dd" = 板内 `ddmem`（`y1/tools/ddmem.c`，静态 riscv32，mmap /dev/mem）：
    ① 主机侧把映像**分块**经 ssh stdin 送进板内 `ddmem wr <phys> -`
       （不落 /tmp，也不碰 COM7 控制台——ssh 不分配 tty）；
    ② 每块写完 **就地回读逐字节比较**（ddmem 自己打 `RSEG=OK`）；
    ③ 全块写完再整块 `ddmem rd <phys> <len> - | md5sum` **独立回读**（新映射、新进程），
       与主机侧整块 md5 比对 —— 这是验收判据，不是"信任 dd"；
    ④ 回读（12 路输出）同理走 `ddmem rd ... | base64`，8-bit 干净。
       ★ 2026-10-16（S3-2 实测修订）：**ssh 大 stdout 必死**（≳1.5 KB ⇒ rc=255 且输出整丢）
       ⇒ 大块回读改走 **板内落文件 + `busybox tftp -p` 主动推回本机**（`scripts/board_tftp.py`，
       本机 UDP 接收器 + 双侧 md5 对账；见 `read()` 的 `TFTP_MIN` 分档）。

传输助手见 `scripts/board_ssh.py`（WSL + askpass + 压 KEX，全工程唯一入口）。
"""
import hashlib
import os
import re
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import board_ssh as BS  # noqa: E402

DEFAULT_WORKDIR = "/tmp/npu_f1"
DEFAULT_CHUNK = 65536


class BoardDdrError(RuntimeError):
    pass


class BoardDdr(object):
    """板内 DDR 的分块投递 + 独立回读校验。"""

    def __init__(self, workdir=DEFAULT_WORKDIR, chunk=DEFAULT_CHUNK, tries=3,
                 quiet=False, logpath=None, timeout=180):
        self.workdir = workdir
        self.chunk = chunk
        self.tries = tries
        self.quiet = quiet
        self.timeout = timeout
        self.log = open(logpath, "w", encoding="utf-8") if logpath else None
        self.ddmem = workdir + "/ddmem"
        self.stats = {"chunks": 0, "bytes": 0, "retries": 0, "verify_fail": 0}

    # ------------------------------ 基础设施 ------------------------------
    def _say(self, s):
        if not self.quiet:
            print(s, flush=True)
        if self.log:
            self.log.write(s + "\n")
            self.log.flush()

    def prepare(self, tool_local):
        """板内备目录 + 上传 ddmem（按 md5 幂等）。

        ★ 2026-10-16：`mkdir` 一步也重试 `tries` 次 —— 现网下 ssh 会话偶发 rc=255
        （实测 10 次小命令 8 成 2 败），而这一步原来**一手一锤**（失败即整帧做废）。
        """
        if not BS.ensure_askpass():
            raise BoardDdrError("WSL askpass 准备失败")
        ok, last = False, ""
        for t in range(self.tries):
            rc, txt = BS.run_text("mkdir -p %s && echo MDOK" % self.workdir)
            if rc == 0 and "MDOK" in txt:
                ok = True
                break
            last = "rc=%s %s" % (rc, txt.strip()[:120])
            if t + 1 < self.tries:
                self._say("    [net] mkdir 重试 %d/%d：%s" % (t + 1, self.tries, last))
        if not ok:
            raise BoardDdrError("板内 mkdir 失败（%d 试）：%s" % (self.tries, last))
        want = BS.md5_hex(open(tool_local, "rb").read())
        rc, txt = BS.run_text("md5sum %s 2>/dev/null" % self.ddmem)
        have = txt.split()[0] if txt.split() else ""
        if have != want:
            self._say("  [net] 上传 ddmem（本地 md5=%s，板上 %s）" % (want[:12], have[:12] or "无"))
            rc, txt = BS.put(tool_local, self.ddmem, timeout=self.timeout)
            if rc != 0:
                raise BoardDdrError("scp ddmem 失败：%s" % txt.strip()[:300])
            rc, txt = BS.run_text("chmod +x %s && md5sum %s" % (self.ddmem, self.ddmem))
            got = txt.split()[0] if txt.split() else ""
            if got != want:
                raise BoardDdrError("ddmem 上传后 md5 不符：%s != %s" % (got, want))
        else:
            self._say("  [net] 板上 ddmem 已是最新（md5=%s）" % want[:12])
        return self

    # ------------------------------ 写入 ------------------------------
    def write(self, phys, data, label=""):
        """分块写 + 每块**同一条 ssh 里**就地回读 md5 + 最后整块独立 md5 回读。返回 dict。

        ★ 一次 ssh 会话就要 ~3 s（WSL 起进程 + curve25519 握手），所以**块内写与回读合并成
        一条命令**（`ddmem wr <phys> - ; ddmem rd <phys> <len> - | md5sum`）——实测把 1.2 MB
        的总时间从 121 s（19 块 ×2 会话）压到 ~35 s（10 块 ×1 会话）。
        """
        n = len(data)
        md5 = hashlib.md5(data).hexdigest()
        self._say("  [net] wr %-12s phys=0x%08X %8d B  分块 %d（%d 块）"
                  % (label, phys, n, self.chunk, (n + self.chunk - 1) // self.chunk))
        off = 0
        while off < n:
            blk = data[off:off + self.chunk]
            a = phys + off
            want = hashlib.md5(blk).hexdigest()
            last = None
            for t in range(self.tries):
                cmd = ("%s wr 0x%08X - ; %s rd 0x%08X %d - | md5sum"
                       % (self.ddmem, a, self.ddmem, a, len(blk)))
                rc, out, err = BS.run(cmd, timeout=self.timeout, stdin=blk, log=self.log)
                txt = out.decode("utf-8", "replace")
                got = ""
                for w in txt.split():
                    if len(w) == 32 and all(c in "0123456789abcdef" for c in w):
                        got = w
                if "RSEG=OK" in txt and got == want:
                    last = None
                    break
                last = "rc=%s RSEG=%s 回读=%s(期望 %s) %s" % (
                    rc, "OK" if "RSEG=OK" in txt else "MISMATCH/缺失",
                    got[:12] or "?", want[:12], err.strip()[:100])
                self.stats["retries"] += 1
                self._say("    %s 块重试 %d/%d @0x%08X：%s" % (label, t + 1, self.tries, a, last))
            if last is not None:
                raise BoardDdrError("ddmem wr+回读 %s @0x%08X 失败：%s" % (label, a, last))
            self.stats["chunks"] += 1
            self.stats["bytes"] += len(blk)
            off += len(blk)
        # 整块再核一遍（覆盖所有块边界；新进程、新映射）
        whole = self._rd_md5(phys, n)
        if whole != md5:
            raise BoardDdrError("整块回读 md5 不符 %s @0x%08X：板上 %s != 主机 %s"
                                % (label, phys, whole, md5))
        self._say("  [net] wr %-12s OK  整块回读 md5=%s （逐块+整块双重校验）"
                  % (label, md5[:16]))
        return {"phys": phys, "bytes": n, "md5": md5, "chunks": (n + self.chunk - 1) // self.chunk}

    def _rd_md5(self, phys, length):
        """整块独立 md5 回读（新进程、新映射）。

        ★ 2026-10-16 勘误（S3 上板实测，修**工具**不改判据）：现网下
        `ddmem rd | md5sum` 的 ssh 会话偶发 `rc=255`（dropbear 会话收尾掉线），且 stdout
        里可能混入**别的会话**的残行（实测见到 `8c1bd05c…  - RROK … wrote=1228800` 这种
        拼接）。原实现"rc!=0 即抛"会把**已经拿到正确 md5** 的回读误判成失败（实测：板上
        md5 与主机逐字节相等、却因 rc=255 把整帧做废）。修法（不放宽任何判据）：
        重试 `tries` 次；只要 stdout 里出现 32 位十六进制 token 就采纳 —— token 的**判据
        仍是调用方与主机 md5 逐字节相等**（不等照样 raise）。
        """
        last = ""
        for t in range(self.tries):
            cmd = "%s rd 0x%08X %d - | md5sum" % (self.ddmem, phys, length)
            rc, out, err = BS.run(cmd, timeout=self.timeout, log=self.log)
            txt = out.decode("utf-8", "replace")
            got = ""
            for w in txt.split():
                if len(w) == 32 and all(c in "0123456789abcdef" for c in w):
                    got = w
            if got:
                if rc != 0:
                    self._say("    [net] rd 回读 rc=%s 但 md5 token 有效（采纳；err=%s）"
                              % (rc, err.strip()[:60]))
                return got
            last = "rc=%s %s %s" % (rc, txt.strip()[:120], err.strip()[:120])
            if t + 1 < self.tries:
                self._say("    [net] rd 回读重试 %d/%d @0x%08X：%s"
                          % (t + 1, self.tries, phys, last))
        raise BoardDdrError("回读 md5 失败 phys=0x%08X len=%d（%d 试）：%s"
                            % (phys, length, self.tries, last))

    # ------------------------------ 权重信箱成批投递 ------------------------------
    def mailbox(self, regbase, off_addr, off_data, off_we, records, label="mailbox"):
        """一次 ssh 把 `records=[(wgt_addr, data), ...]` 全部打进 HostRegs 信箱。

        为什么必须成批（F1 实测）：UART 老路是每条记录 3 个 `devmem` 命令行，而
        `bias_adj` 一项就是 6912 条 ⇒ 2 万条命令、~900 KB 命令行，按 10 ms/字的串口纪律
        = **2.6 小时**；而且这一批寄存器（0xF000_C000）同样落在 [0x8200_0000, 0x9000_0000)
        之外 ⇒ 也只有 mmap 能碰。板内 `ddmem mb` 就是干这个的。
        """
        import struct
        blob = b"".join(struct.pack("<II", a & 0xFFFFFFFF, d & 0xFFFFFFFF) for a, d in records)
        blob += struct.pack("<II", 0xFFFFFFFF, 0)
        cmd = "%s mb 0x%08X 0x%X 0x%X 0x%X -" % (self.ddmem, regbase, off_addr, off_data, off_we)
        self._say("  [net] mailbox %d 条寄存器写（%d B 记录流，一次会话）" % (len(records), len(blob)))
        last = None
        for t in range(self.tries):
            rc, out, err = BS.run(cmd, timeout=self.timeout, stdin=blob, log=self.log)
            txt = out.decode("utf-8", "replace")
            n = 0
            for w in txt.replace("=", " ").split():
                if w.isdigit():
                    n = max(n, int(w))
            if rc == 0 and "MBOK" in txt and "RREG=OK" in txt and n == len(records):
                self._say("  [net] mailbox OK  n=%d（寄存器就地回读一致）" % n)
                return {"records": len(records), "bytes": len(blob)}
            last = "rc=%s out=%s err=%s" % (rc, txt.strip()[:160], err.strip()[:120])
            self.stats["retries"] += 1
            self._say("    mailbox 重试 %d/%d：%s" % (t + 1, self.tries, last))
        raise BoardDdrError("信箱成批投递失败：%s" % last)

    # ------------------------------ 读出 ------------------------------
    # ★ 2026-10-16（S3-2 上板实测）：ssh 会话的**大 stdout 必死**（stdout ≳1.5 KB ⇒ rc=255 且
    #   输出整丢：`head -c 4096/6000/6400 f | base64` 全灭、小命令 87.5% 成）⇒ 大块回读（12 路
    #   输出 ~131 KB）改用**板内落文件 + busybox tftp 主动推回**（scripts/board_tftp.py；本机
    #   UDP 接收器用防火墙放行的解释器跑独立进程；**两侧 md5 相等**才采纳 —— 与写通路同款判据）。
    TFTP_MIN = 512
    TFTP_CHUNK = 8192       # 板内 tftp 单文件上限（停等+耐心 ∝ 块数：16 KB@4096=4 块也常灭，
                            # 8 KB@4096=2 块实测稳；主机侧切块，逐块 md5）

    def read(self, phys, length):
        """回读一块：`length >= TFTP_MIN` 走 tftp 通路；小片走 ssh base64（原通路）。"""
        if length >= self.TFTP_MIN:
            return self._read_tftp(phys, length)
        cmd = "%s rd 0x%08X %d - | base64" % (self.ddmem, phys, length)
        last = None
        for t in range(self.tries):
            rc, out, err = BS.run(cmd, timeout=self.timeout, log=self.log)
            if rc == 0 or out:                       # rc=255 但 stdout 有净荷 ⇒ 也进完整性判
                import base64
                try:
                    b = base64.b64decode(out)
                except Exception as e:
                    last = "base64 解码失败 %s" % e
                    if rc == 0:
                        continue
                    self.stats["retries"] += 1
                    continue
                if len(b) == length:
                    if rc != 0:
                        self.stats["rc255_tolerated"] = self.stats.get("rc255_tolerated", 0) + 1
                    return b
                last = "长度不符 %d != %d（rc=%s）" % (len(b), length, rc)
            else:
                last = "rc=%s %s" % (rc, err.strip()[:120])
            self.stats["retries"] += 1
            self._say("    read 重试 %d/%d @0x%08X：%s" % (t + 1, self.tries, phys, last))
        raise BoardDdrError("回读失败 phys=0x%08X len=%d：%s" % (phys, length, last))

    def _read_tftp(self, phys, length):
        """大块回读：板内 `ddmem rd <phys> <len> <file>` 落文件 → tftp 推回本机 → 双侧 md5 对账。

        ★ 分块：板内 busybox tftp 是**停等**且**总耐心有限**（64000 B 单文件实测在 4096/2048/1024/512
        四档全灭 —— 块数一多，任意一次丢包重传就把客户端的耐心耗尽）；≤ `TFTP_CHUNK`（16 KB）的
        文件实测在丢包链路上可重试成功 ⇒ 大块在**主机侧**切 16 KB 子块，逐块走完整 ddmem→tftp→md5。
        """
        out = bytearray()
        off = 0
        while off < length:
            n = min(self.TFTP_CHUNK, length - off)
            out += self._read_tftp1(phys + off, n)
            off += n
        return bytes(out)

    def _read_tftp1(self, phys, length):
        """单块（≤ TFTP_CHUNK）的 ddmem→文件→tftp→md5 闭环。

        ★ 本地块缓存：**先从 DDR 新鲜重读**（`ddmem rd` 就地覆盖 rfile + `md5sum`，一条 ssh、
        无 tftp），本地缓存与这枚**新鲜** md5 相等才复用 —— 判据里不含任何"上一轮留下的板上
        文件"（否则 DDR 内容变过时会把陈旧缓存当命中）。丢包链路上一块可能要试十几轮，
        重跑别从头再来；这条保证"重跑复用"只在**内容真的没变**时发生。
        """
        import board_tftp as BT
        rfile = "%s/rd_%08x_%d.bin" % (self.workdir, phys, length)
        local = os.path.join(tempfile.gettempdir(), "board_rd_%08x_%d.bin" % (phys, length))
        last = None
        for t in range(self.tries):
            rc, out, err = BS.run(
                "%s rd 0x%08X %d %s; echo RDRC=$?; md5sum %s" % (self.ddmem, phys, length, rfile, rfile),
                timeout=self.timeout, log=self.log)
            m = re.search(rb"([0-9a-f]{32})", out)
            if not m:
                last = "板内 ddmem rd 未产出 md5（rc=%s out=%r）" % (rc, out[:80])
                self.stats["retries"] += 1
                self._say("    read(tftp) 重试 %d/%d @0x%08X：%s" % (t + 1, self.tries, phys, last))
                continue
            md5_fresh = m.group(1).decode()
            if os.path.isfile(local) and os.path.getsize(local) == length:
                md5_have = hashlib.md5(open(local, "rb").read()).hexdigest()
                if md5_have == md5_fresh:
                    self.stats["chunk_cache_hits"] = self.stats.get("chunk_cache_hits", 0) + 1
                    self._say("    read(tftp) 本地块缓存命中 @0x%08X len=%d（与新鲜 DDR 重读的 md5 相等）"
                              % (phys, length))
                    return open(local, "rb").read()
            ok, md5, n, detail = BT.pull_board_file(rfile, local, quiet=True, md5_want=md5_fresh)
            if ok and n == length:
                self.stats["tftp_reads"] = self.stats.get("tftp_reads", 0) + 1
                return open(local, "rb").read()
            last = "tftp 拉取：ok=%s n=%d 期望=%d；%s" % (ok, n, length, detail)
            self.stats["retries"] += 1
            self._say("    read(tftp) 重试 %d/%d @0x%08X：%s" % (t + 1, self.tries, phys, last))
        raise BoardDdrError("回读失败（tftp 通路）phys=0x%08X len=%d：%s" % (phys, length, last))

    def close(self):
        if self.log:
            self.log.close()
            self.log = None
