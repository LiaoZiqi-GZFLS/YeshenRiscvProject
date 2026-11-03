# Y1-C3 · 上板验收（盘古676 200K MINI）—— **板上算出来了，逐字节对上黄金**

**日期**: 2026-10-10
**比特流**: `sim/reglogs/pds_pnr_c3_r4_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`（9,188,552 B，`All Constraints Met`，`cpu_clk` 102.65 MHz）
**装置**: `y1/tools/npu_board_test.py`（端到端 MaxPool）、`y1/tools/npu_copy_probe.py`（DDR 通路判别）
**串口**: COM7 @115200（板载 CP2102）；登录后经 busybox `devmem` 读写寄存器窗

---

## 0) 结论

**五级验收全过**（每级都有原文证据）：

| # | 判据 | 结果 |
|---|---|---|
| ① | 比特流上板、SoC 启动 | ✅ SD 装载 → OpenSBI banner → Linux → LiteEth → dropbear → 用户态 marker → 登录提示符（`flash_and_verify.py` 判据全绿） |
| ② | NPU 寄存器窗**可读** | ✅ `devmem 0xF000C030 32` → **`0x594E5031`**（ID 常数） |
| ③ | 寄存器窗**可写**（RW 往返） | ✅ 写 `0x12345678` → 读回 `0x12345678`；写 `0xDEADBEEF` → 读回 `0xDEADBEEF`（不是焊死的常数） |
| ④ | **NPU↔DDR 通路**（遗留块拷贝） | ✅ `IMG_W=16,IMG_H=1,C_IN=8 ⇒ len=128` 起拷贝，DST **逐字节 == SRC**（`0x01010101/02020202/03030303/04040404`） |
| ⑤ | **调度器端到端 + 数值对账**（MaxPool，无需权重） | ✅ 表在 DDR → 走表 → 输出落 DDR → **`MISMATCH=0`** |
| ⑥ | **带权重的 conv3x3 dense 端到端**（576 B 经信箱灌入） | ✅ `done=1 err=0`，128/128 word，**`MISMATCH=0`**（详见 §5） |

⑤ 的原文：

```
STATUS=0x00000001 (done=1 err=0)
输出 @0x80200000 : 42424242 43434343 46464646 47474747
黄金             : 42424242 43434343 46464646 47474747
MISMATCH=0  FIRST_OFF=-1   RESULT: PASS
```
几何：`C=8, W=32, H=2`（输入 512 B）→ MaxPool 2×2/s2 → `C=8, W=16, H=1`（输出 128 B）；描述符表 = 1 载荷 + 哨兵 = 36 B。

---

## 1) 两条**过程中查出的真事实**（值得记）

### (a) NPU 的地址空间与 DDR 基址的对齐 —— **实测成立**
- 内核的 `System RAM` 是 **`0x80400000-0x8FFFFFFF`**（DTS `memory@80400000`，`reg = <0x80400000 0x0FC00000>`）；DDR 器件是 512 MB。
- 而 NPU 的 `DdrMaster` 是 **28 bit 地址（`0x0000_0000-0x0FFF_FFFF`）且胶合只做零扩展** ⇒ 与 `0x8000_0000` 的 DDR 基址**不重叠**。
- **实测**：CPU 直读 `0x00100000` → **SIGSEGV（`badaddr`）**（低地址无映射）；但把输入写到物理 `0x80100000`、让 NPU 读 `0x00100000`，**拷贝逐字节正确** ⇒ **NPU 的地址 A 落到 DDR 物理 `0x80000000+A`**（桥/DDR IP 只看低位偏移）。
- **安全区**：`0x80000000-0x803FFFFF`（4 MB）**不在内核 RAM 里** ⇒ 板上测试用 `0x00100000/0x00200000/0x00300000`（= 物理 `0x80100000/0x80200000/0x80300000`）**不会碰内核**。
- ⚠ 这条是**接口约定**（不是 bug），但**写死了 28 bit 与"CPU 同域偏移"**：将来若把 DDR 数据放到 `0x80400000` 以上（内核区），NPU 侧地址要相应改成 `0x00400000+`（偏移），**不是**写 `0x8040xxxx`。

### (b) **maxpool 描述符的几何口径是个坑**（我第一次就写错）
- 冻结口径（`run_nputop_sched_ab.sh` 的 `d2`）：**`IMG_W/IMG_H` 填的是"输出"尺寸，`IN_BYTES` 填的是"输入"字节数**（`C*H*W`）。
- 我按输入尺寸填（`IMG_W=32,IMG_H=2`）⇒ `BypassExec` 推出 `inW = 2*IMG_W = 64 ≠ WIDTH(32)` ⇒ **响亮 err、零搬运**（`STATUS=0x02`）。
- 按输出尺寸填（`IMG_W=16,IMG_H=1`）+ `IN_BYTES=512` ⇒ **PASS**。
- ⇒ 这条要写进 **C4 的转换器契约**（旁路算子的 `IMG_W/IMG_H` 语义与 conv **相反**）。

## 2) 过程坑（板内调试口径）

1. **`guest_cmd.py` 一次性写整行 ⇒ 板端 UART `input overrun`**，命令被截断且**留下未闭合引号 ⇒ shell 卡 PS2 `>`**（"找 `#`"的探活会被回显骗）。对策：先 `Ctrl-C ×2 + ^Q` 清场，再**逐字符慢发（10 ms/字符）**。
2. **`errSticky` 只在 `CTRL.soft_reset`(bit1) 清** ⇒ 上一次失败后会一直读到 `err=1`。**每轮起跑前先写 `CTRL=0x2`**，否则把陈旧 err 误读成本轮失败（本档第一版 MaxPool 判据就被这个骗过一次）。
3. 清理（TF 卡那一侧）：`TF-E1 noresp resp=04` → 卡没插实；插好后 `TF-OK r0=01 r8=01AA ocr=C0FF8000 sts=01`。

## 3) 边界（本轮**没有**验的）

- **带权重的 conv 端到端**：要经 AxiLite 信箱逐字节写 576 B 权重（慢），本轮只做了"无需权重"的 MaxPool。conv 的数值在**仿真**里是逐字节对的（`run_nputop_sched_ab.sh` 等 15 个闸门），**板上未做**。
- 未做时序实测（`Performance Summary` 是布局后的静态值）、未做功耗、未做 C5 的 CPU 争用与真实 fps。
- 板上一切观测依赖 UART 控制台；网络（dropbear 已起）未启用。

## 4) 复现

```bash
# 烧写 + 启动判据（R4 带）
python -u scripts/flash_and_verify.py --tag pnr_c3_r4 --com COM7 --secs 180 --no-net
# 登录（口令 yeshen）
python -u scripts/uart_login_pw.py COM7 115200 yeshen
# 板内端到端（MaxPool，无需权重）
python -u y1/tools/npu_board_test.py
# DDR 通路判别（遗留块拷贝）
python -u y1/tools/npu_copy_probe.py
# 板内端到端（conv3x3 dense，576 B 权重经 AxiLite 信箱灌入）
python -u y1/tools/npu_board_conv.py
```

---

## 5) 追加：**带权重的 conv3x3 dense 板上端到端**（`y1/tools/npu_board_conv.py`）

**PASS**（逐字节）：

```
全部完成标记到达（FINW / FINS / FIND / FINO = True）
STATUS=0x00000001 (done=1 err=0)    输出读到 128/128 word
got[:24] = fd03fc03 fffd03fc fc03fc00 02fc03fc fc03fc00 02fc03fc
gol[:24] = fd03fc03 fffd03fc fc03fc00 02fc03fc fc03fc00 02fc03fc
MISMATCH=0  FIRST_OFF=-1   RESULT: PASS
```

- 几何：`C=8, W=32, H=2`（输入 512 B）→ conv3x3 `PAD=1/STRIDE=1` → 输出 512 B；`QUANT_SHIFT=6`（必须 == 网表展开期 `SHIFT`，否则 C3.8 的响亮检查会 err）。
- **权重 576 B** 经 **AxiLite 信箱逐字节**灌进 slice0 的 `WeightStore`：`WGT_ADDR(0x40)` / `WGT_DATA(0x44)` / `WGT_WE(0x48)`，地址 `k = co*72 + ci*9 + ky*3 + kx`（`GroupMask.weightAddr`，GROUP=1 时 `PER_GROUP=8`、`ciLocal=ci`）。
- 权重取 shell 可算的短式 `w(k) = (k%5)-2`（值域 −2..2，落在 int8 内、非平凡），**Python 黄金用同一式子** ⇒ 两侧独立算出同一个张量。
- 黄金口径与 `mac_ref.py` 一致：int32 累加 → 算术右移 6 → clamp 到 `[-128,127]`。
- 与 ⑤（MaxPool）的区别：⑤ 无需权重、只验调度器；本节**验了权重装载通路 + conv 数据通路 + 数值**。

### 5.1 板内串口交互的三条硬经验（本轮又踩到两条）

1. **完成标记不能出现在回显里**。`...; echo WGT_DONE` 会先被 tty **回显**，主机"等 WGT_DONE"当场命中回显 ⇒ 提前走人。正解是 `${B}` 拼标记：命令里写 `B=FINW; echo "X${B}X"`，输出出现 `XFINWX` 而回显里是字面 `X${B}X` ⇒ 不会撞（同 `guest_cmd.py` 的手法）。
2. **长循环必须等完成标记，不能固定 drain**。576×3 次 `devmem`（≈1 分钟）若不等就发下一条，命令会**排在 tty 输入缓冲里**并可能**溢出丢字符** ⇒ 整段会话错位（本轮前两次就是这么翻的：STATUS 读到 `0x01010101`=输入模式值、128 个输出只解析出 15/34 个）。
3. 逐字符 **10 ms** 慢发 + 每轮先 `Ctrl-C ×2 + ^Q`；**`errSticky` 只在 `CTRL.soft_reset(bit1)` 清**，**每轮起跑前先写 `CTRL=0x2`**。

