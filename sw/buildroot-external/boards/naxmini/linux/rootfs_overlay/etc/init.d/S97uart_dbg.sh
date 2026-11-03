#!/bin/sh
#
# 启动期板内观测探针（2026-10-07 E1 收口版）。
#
# 为什么需要它：控制台曾经 RX 不通（"只能读、打不进字"），所以"进不去板子看计数器"是常态，
# 必须让板子**自己说**。现在控制台已经能当命令行用了（见 docs/交付-2026-10-07.md §10/§11），
# 但这条探针仍然值得留：它能一眼给出"中断到底响没响"，且**不依赖登录**。
#
# 观测两类事实：
#   ① /proc/interrupts —— 各 IRQ 的中断**计数**（**整份**打印，不过滤：过滤会把 8250 那行
#      整个丢掉 —— 它在那一列写的名字是 `ttyS0`，不是 uart/serial）。
#   ② UART/PLIC 关键寄存器（busybox devmem）：
#        UARTDBG  IER/IIR/LCR/LSR/MCR  @0xF00010{04,08,0C,14,10}
#        PLICDBG  pri1/pri2/en_ctx1/pend/thr_ctx1/claim_ctx1
#      合起来能把"事件没发生 / 没使能 / 使能但线没拉 / 线拉了核没接"分开。
#
# ★ 2026-10-07 改：**只打 5 轮、每轮隔 1 秒**（原来 60 轮）。原来每轮要起 10 个 `devmem`
#   进程，实测 60 轮要跑 **6.4 分钟**，把串口占着，害得命令行要等它跑完才好用。
#   5 轮足够看"计数有没有在涨"（配合主机侧发 ARP / 敲键盘）。
# ★ 同时**删掉 RXACTY 紧循环**（原第 25 秒读 4000 次 LSR）：那是 irq=0 时代用来分辨
#   "字节没到 UART"还是"到了但 tty 不回声"的，现在已被 `sim/uart16550/` 单元装置与
#   PC 侧的丢字/速率对照（`scripts/uart_rate_dep.py`）取代；它还会把 pBus 打满，得不偿失。
#
# 注意：一律经 /dev/kmsg（printk 的 console 路径逐字节等 THRE），**不要**直写 /dev/console。
M="IRQDBG"
printf '%s start\n' "$M" > /dev/kmsg 2>/dev/null

(
  i=0
  while [ $i -lt 5 ]; do
    # ① 中断计数：整份 /proc/interrupts
    if [ -r /proc/interrupts ]; then
      sed -n '2,12p' /proc/interrupts | tr -s ' ' ' ' | while read -r ln; do
        printf '%s %s\n' "$M" "$ln" > /dev/kmsg 2>/dev/null
      done
    fi
    # ② UART 自己的寄存器（"RX 中断有没有被使能"的直接证据）
    if command -v devmem >/dev/null 2>&1; then
      printf 'UARTDBG IER=%s IIR=%s LCR=%s LSR=%s MCR=%s\n' \
        "$(devmem 0xF0001004 2>/dev/null)" \
        "$(devmem 0xF0001008 2>/dev/null)" \
        "$(devmem 0xF000100C 2>/dev/null)" \
        "$(devmem 0xF0001014 2>/dev/null)" \
        "$(devmem 0xF0001010 2>/dev/null)" > /dev/kmsg 2>/dev/null
    fi
    # ③ PLIC 寄存器快照
    if command -v devmem >/dev/null 2>&1; then
      printf 'PLICDBG pri1=%s pri2=%s en_ctx1=%s pend=%s thr_ctx1=%s claim_ctx1=%s\n' \
        "$(devmem 0xF0C00004 2>/dev/null)" \
        "$(devmem 0xF0C00008 2>/dev/null)" \
        "$(devmem 0xF0C02080 2>/dev/null)" \
        "$(devmem 0xF0C01000 2>/dev/null)" \
        "$(devmem 0xF0C21000 2>/dev/null)" \
        "$(devmem 0xF0C201004 2>/dev/null)" > /dev/kmsg 2>/dev/null
    fi
    i=$((i + 1))
    sleep 1
  done
  printf '%s end\n' "$M" > /dev/kmsg 2>/dev/null
) &
