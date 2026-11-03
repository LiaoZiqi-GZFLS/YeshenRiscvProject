// ===================== NaxYeshenLinux Task 8 控制台探针装置 =====================
// 判据（**只看串口线**，不看任何 tb 内部记账）：
//   sim/probe_console.S 往 ns16550a(0xF000_1000) 的 THR 写 "NAXMINI\n"，
//   本 tb 用 sim/uart_decode.h（从 YeshenCore/sim/uart_decode.h 逐字复制，82 行）从
//   **顶层 uart_txd 的波形**里把字节解回来 ⇒ `text == "NAXMINI\n"` 即 PASS。
//   ⇔ 这条绿同时证明：pBus 外设窗口可达（V1）→ 胶合块解码正确 → 16550 的 LSR 读与 THR 写
//     都通 → TX 移位器按 8N1 真把 8 个字节推到了线上。
//
// ★ Task 9 起的扩展（默认行为**不变**，T8 的命令原样重跑仍然逐字同义）：
//   · `SOC_PROG` 支持**多镜像**：`<文件>@<地址>[, ...]`，地址可用台账名字（FW_TEXT_START/
//     Image/FDT/INITRD）或 0x 字面量（见 NAMED_ADDR / scripts/check_addr_map.py）。
//   · `SOC_EXPECT=<子串>` ⇒ 判据改成"线上解出的文本**包含**该子串"。Task 9 用它跑
//     `SOC_EXPECT='OpenSBI v'`：整条判据仍然是**同一个 16550 解码器从 uart_txd 波形里解出来的**，
//     与 OpenSBI 自称"我打印了"无关。
//   · 内存窗口 4MiB → 32MiB → **64MiB**（H2b 后覆盖台账最远的 INITRD 末址 0x8380_0000）。
//
// ⚠️ **实测状态（2026-09-29，Task 8）：判据仍红，但 V1 已由"线上真解出字节"关闭** ——
//   `sim/probe_console.S` 解出 1 帧（'N'，逐位正确）后核卡在紧跟 `sb THR` 的 D$ 读上；
//   `sim/probe_console_imm.S` 解出 4 帧逐字节正确（NAXM，1760 笔 LSR 读返回值全对）后
//   核走进异常：`exceptionPort code=0`(INSTRUCTION_ADDRESS_MISALIGNED) `epc=0x8000_0096`
//   （非指令边界）⇒ 跳 `mtvec`(=0，从未设置) ⇒ 死在取 0 号地址的陷阱循环里。
//   **卡点在核侧取指/异常路径，不在 16550/pBus/region**；详见 docs/探针记录.md「Task 8 收口」。
//
// 装置拓扑（Task 8 组装后的完整 SoC）：
//   nax_mini_soc = NaxSocMini(fabric/核) + NaxMiniGlue(pBus 外设解码 + 装载链 + 内存汇聚)
//   本 tb 扮演的角色：① **内存**（NaxMiniGlue.io_mem 的下游，AXI4 32bit/id 4bit）；
//                     ② 常量输入（load_mode=0、uart_rxd 空闲高、sd_miso=1、gpio_in=0）；
//                     ③ 观测者（uart_txd 解码器 + AXI 台账 + CsrTracer 计数）。
//   pBus 侧 tb **完全不参与**（胶合块内部消化）—— 这是与 tb_memmark.cpp 最大的结构差异：
//   M0-b 时 tb 还要在顶层 pBus 上当从方，现在那一段落进胶合块的 `isConsR/isGpioR` 解码里。
//
// 原型来源：sim/tb_memmark.cpp（同一套 AXI4 从方逻辑，逐字沿用两条纪律）：
//   ① **响应路由在握手拍锁存**（AR 的 arid 入队时存下，发 R 时用存的值）；
//   ② **多笔在飞**：AR/AW 各自入队、绝不丢弃（关掉 ready 就会静默丢请求 ⇒ 死锁）。
//   beat 宽度处理沿用 M0-b 的 H1 修复版：beat_bytes = 1<<arsize/awsize，车道偏移 = addr % BUS_BYTES
//   （Task 14 起 BUS_BYTES 可由宏覆盖，默认 4；见文件头与下面的定义）。
//
// ★ Task 17（V2 闸门，2026-09-30）：**从方纪律两处修正**（装置不修，64bit 原生通路的一切结论无效）：
//   (1) **组合采样纪律（根因）**：本核 Axi4Bridge 的 `rready`/`bready` 是**组合依赖 `rvalid`/`bvalid`**
//       的（`io_down_r_ready = d_arbiter_io_inputs_1_ready`）。旧版读的是"上一拍 `eval()` 出来的
//       rready"（那时 rvalid 还是 0）⇒ 把"**已经握手**"记成"停顿"，同一拍数据被 DUT 收两次：
//       实测签名 = 每条 64B 取指行的 I$ 填充**整体旋转 +1**（`refill_wordIndex` 每条线多走一格）
//       ⇒ 第 2 条行取出的字全错 ⇒ `mcause=2 @ epc=0x80000040`（与 T14 直连装置同一签名）。
//       修法：摆上 `rvalid/rdata`（或 `bvalid`）后先 `dut->eval()` 推进组合网，**再**采样 ready 判握手。
//       （32bit 装置的 rready 走 `WidthAdapter`+32bit Axi4Bridge 的**寄存器**路径，与 rvalid 无关 ⇒
//         旧版在那个装置上恰好是对的，所以这条缺陷只在原生 64bit 通路上暴露。）
//   (2) **AR 接受纪律**：`arready` 只在"手上没有读突发且队列空"时抬高（**单笔在飞**，与 T13 已实证
//       可用的 `sim/axi64to32.v` 的 `u_arready = ~ar_live` 同构），且**直接按握手拍捕获**、不再用
//       上升沿（主方连抬两拍递交两笔 AR 时，上升沿判定会静默漏一笔 ⇒ 挂死）。
//   回归口径（`docs/探针记录.md`「Task 17」）：修正后 pack 探针在**原生 64bit 交付栈**上 8 帧 PASS
//   （`cyc=82918`）；同一份 tb 跑 **32bit 归档栈**仍 8 帧 PASS，与 T11 归档日志的差异**只**在
//   `[AXI-R]` 首拍 `rdy`（0→1，即握手拍记录正确）与由此产生的总拍数（82281 → 82711），判据一字未变。
//
// 环境变量：
//   SOC_MAX_CYC   拍数上限（默认 2000000）
//   SOC_PROG      要装载的镜像。**支持多镜像**：`<文件>@<地址>[,<文件>@<地址>...]`
//                 · 地址可以是 `0x...`/十进制，也可以是**台账里的名字**（FW_TEXT_START /
//                   Image / FDT / INITRD，见下面的 NAMED_ADDR）⇒ 与 check_addr_map.py 对账。
//                 · 不给 `@` ⇒ 落在 BASE（= 0x8000_0000），与 Task 8 的单镜像写法完全兼容。
//                 例：SOC_PROG='sw/images/fw_jump.bin@0x80000000'（Task 9）
//                     SOC_PROG='sw/images/fw_jump.bin@FW_TEXT_START,sw/images/Image@Image'（Task 12）
//   SOC_EXPECT    判据改成"**线上解出的文本包含该子串**"。不设 = Task 8 的精确匹配 "NAXMINI\n"。
//                 Task 9 用 SOC_EXPECT='OpenSBI v'（banner）。
//   SOC_LOAD_MODE =1 ⇒ load_mode 拉高（CPU 被扣复位）⇒ **负对照**：必须 `FAIL: timeout` + `frames=0`
//   SOC_BAUD_DIV  探针实际写入 DLL 的分频（默认 54）⇒ 解码器位周期 P = 16*bdiv（默认 864）
//   SOC_TRACE_UNTIL / SOC_NO_EARLY_EXIT / SOC_VERBOSE   与 M0-b 同义（取证用）
//   TB_PEEK=1     打印装置内视（console 的 LSR 读回值/TX 状态、核的 fetch/exec PC、异常、
//                 I$ 内部 RAM）。**必须**用 `-CFLAGS "-DTB_PEEK_CODE=1"` 重新 build 才编得进来
//                 （见下面的 #ifdef 说明）；不开时默认 build 与"任务书原样命令"逐字一致。
//   SOC_AXI_WATCH 任何非空值 = 打开 AXI 内存口**逐拍电平观测**（`[AXI-WLVL]`/`[AXI-LVL]`/
//                 `[AXI-STALL]`）。默认关 ⇒ 一行不打印。配套 `SOC_AXI_WIN_FROM/TO` 限定逐拍窗口。
//                 ★ Task 14 新增：用来给"静默停摆"定性（是核没抬 wvalid，还是 tb 没给 wready）。
//   ⚠️ 内存口数据宽：源码里 `BUS_BYTES` **默认 4**（= 交付的 32bit 内存口），可用 C++ 宏覆盖成 8
//      （**必须** `-CFLAGS -DBUS_BYTES=8`；裸 `-D` 是给 Verilog 的）。Task 14 用它让 tb **直接**建模
//      64bit 内存（不再经手写降位宽桥）。不带宏时行为与旧版逐字节相同（见 docs Task 14 的 diff 回归）。
//   SOC_R_LATENCY / SOC_R_BEAT_GAP  ★ Task 14 诊断旋钮（**默认 0/0 = 旧版节奏**）：给内存从方的
//      R 通道加"首拍前空拍 / beat 间空拍"。只变**节奏**、不变数据，用来判定核侧 I$ 填充是否对
//      R 到达节奏敏感（T13 的桥给核的节奏与 tb 直连不同）。
//   SOC_R_ZERO_LAT ★ Task 14 诊断旋钮（默认关）：只在**核已经 ready 的拍**才摆 beat（⚠️ 非 AXI 合规，
//      仅为判别"核侧是否对 rvalid 早于 rready 敏感"）。
//   ⚠️ pBus 逐笔探针（TB_PEEK 里的 [PBUS] 段）还需要 Verilog 侧打开 `-DNAXMINI_DBG_PBUS`
//      （board/nax_mini_soc.v 的 19 根 dbg_pbus_* 观测端口；Task 9 Step 0 起默认关闭）。

#include "verilated.h"
#include "Vnax_mini_soc.h"
// ⚠️ 装置内视（装置内部层次名）只在显式打开 `-CFLAGS "-DTB_PEEK_CODE=1"` 时编译进来：
//    Verilator 会**优化掉**本任务用不到的逻辑（例如把 pBus 读地址线断掉后，console 的整条
//    读通路连同 rData/rValid/threPending 都会被删）⇒ 无条件引用它会**编不过**，
//    而那正是 Step 4「先红」要跑的那种变体。判据本身**从不**依赖这些内视。
#ifdef TB_PEEK_CODE
#include "Vnax_mini_soc___024root.h"
#include "Vnax_mini_soc_nax_mini_soc.h"
#include "Vnax_mini_soc_NaxSocMini.h"
#include "Vnax_mini_soc_NaxRiscv.h"
// ★ M2-b Gate 2 第五轮：提交 PC 直方图探针（TB_PCHIST=1）用的容器。
//   只随内视装置编译 ⇒ 判据装置（不带 -DTB_PEEK_CODE）的头文件集一字未改。
#include <map>
#include <algorithm>
#endif
#include "uart_decode.h"
#include <cstdio>
#include <cstdarg>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// mem 口数据宽（字节）：**默认 4 = 交付的 32bit 内存口**（与 T8..T13 的判据装置逐字节同义）。
// ★ Task 14：改成**可由编译宏覆盖**，以便在 tb 内部直接建模 64bit 内存口（不再经手写降位宽桥）。
//   ⚠️ 传法必须是 **`-CFLAGS -DBUS_BYTES=8`**（C++ 侧宏）；裸 `-D` 是给 Verilog 的（Task 13 踩过这个坑）。
//   不带该宏时，下面所有取模/车道/打印格式都退化成与旧版**逐字节相同**（Step 3 的 diff 回归证明）。
#ifndef BUS_BYTES
#define BUS_BYTES 4
#endif
// 一个总线字（= 一次 beat 可落在的字节车道总数）。只在**打印/端口赋值**处用来随位宽切换，
// 不参与任何判据：判据只看 uart_txd 波形（见文件头）。
#if BUS_BYTES == 8
typedef uint64_t bus_word_t;
#define BUS_WORD_HEX "%016llX"                           // 64bit 端口：整字打印
#else
typedef uint32_t bus_word_t;
#define BUS_WORD_HEX "%08llX"                            // 32bit 端口：与旧版 `%08X` 输出**同文本**
#endif
// 内存窗口：Task 8 是 4MiB（0x8000_0000..0x803F_FFFF，只够放探针）。
// Task 9 起放大到 32MiB（0x8000_0000..0x81FF_FFFF）；★ Y1-C4b H2b（2026-10-12）再放大到
//   **64MiB（0x8000_0000..0x83FF_FFFF）**，理由：H2 把 NPU arena [0x8040_0000, 0x8200_0000)
//   标成保留区、配套把 Image/FDT/initrd 抬到 0x8200_0000 之上 ⇒ 台账最远一项变成
//   INITRD = 0x8300_0000（末址 0x8380_0000 = 窗口内 +56MiB）。窗口不够 ⇒ `load_image` 会
//   **报错退出**（不静默丢镜像），所以窗口必须真覆盖台账。
// 对 Task 8 的探针完全中性（它们只碰 0x8000_0000..0x8000_1010）。
// ★ Gate 2（M2-b）新增：**运行期** `SOC_MEM_MIB=<MiB>` 可放大（默认 64MiB ⇒ 覆盖现行台账）。
//   为什么必须有：`sw/.../linux_raw.dts` 的 memory 节点是 `0x8040_0000 + 0x0F_C0_0000`
//   （= 内核声明 252MiB，末址 0x8FFF_FFFF），**远在窗口之外** ⇒ 内核一跑起来就会
//   "读到 0 / 写入被丢"（`addr_in_range` 为假的写入被静默丢弃）。这是跑内核之前必须先开的闸。
static uint32_t MEM_WORDS = 1u << 24;                    // 64MiB（默认；见 main 里的 SOC_MEM_MIB）
static uint32_t MEM_BYTES = MEM_WORDS * 4u;
static const uint32_t BASE = 0x80000000u;
static std::vector<uint32_t> mem_store, orig_store;       // 运行期按 SOC_MEM_MIB 分配
static uint32_t* mem = nullptr;
static uint32_t* orig = nullptr;
static uint64_t cyc = 0;
static uint64_t MAX_CYC = 2000000;

// ===================== 地址台账（与 scripts/check_addr_map.py 逐字对账）=====================
// 这里是"装载表"消费方，**不是**台账本身；台账在 scripts/check_addr_map.py 的 EXPECT。
// ⚠️ 常量写法（`{"Image", 0x82000000u},`）被 check_addr_map.py 用正则直接抓，改格式要同步改脚本。
struct NamedAddr { const char* name; uint32_t addr; };
static const NamedAddr NAMED_ADDR[] = {
    {"FW_TEXT_START", 0x80000000u},   // = 复位 PC = OpenSBI 入口（fw_jump.bin 落这里）
    {"Image",         0x82000000u},   // Linux Image（★ H2b：抬到 NPU arena 保留区之上）
    {"FDT",           0x82F80000u},   // DTB（= OpenSBI FW_JUMP_FDT_ADDR）
    {"INITRD",        0x83000000u},   // initramfs / cpio（initrd-end = 0x8380_0000）
};

static bool VERBOSE = true;
static uint64_t TRACE_UNTIL = 0;

// 判据：线上必须解出这一串（7 字母 + LF = **8 帧**）
static const char* CONSOLE_EXPECT = "NAXMINI\n";

static uint8_t* mem_u8() { return reinterpret_cast<uint8_t*>(mem); }

static bool addr_in_range(uint32_t a, uint32_t n) {
    return (uint32_t)(a - BASE) + n <= MEM_BYTES && a >= BASE;
}

static uint64_t mem_read_le(uint32_t a, uint32_t bytes) {
    uint64_t v = 0;
    for (uint32_t b = 0; b < bytes; b++) {
        uint32_t idx = a - BASE + b;
        if (idx < MEM_BYTES) v |= (uint64_t)mem_u8()[idx] << (8 * b);
    }
    return v;
}
// 宽度通用的 beat 读：地址对应的车道偏移 = a % BUS_BYTES
static uint64_t beat_read(uint32_t a, uint32_t beat_bytes) {
    uint32_t off = a % BUS_BYTES;
    if (off + beat_bytes > BUS_BYTES) return 0;
    return mem_read_le(a, beat_bytes) << (8 * off);
}
static void beat_write(uint32_t a, uint64_t data, uint32_t strb) {
    for (uint32_t b = 0; b < BUS_BYTES; b++) {
        if (((strb >> b) & 1u) == 0) continue;
        uint32_t idx = a - BASE + b;
        if (idx < MEM_BYTES) mem_u8()[idx] = (uint8_t)(data >> (8 * b));
    }
}
static uint32_t size_to_bytes(uint32_t size) { return (size < 7) ? (1u << size) : 128u; }

// 地址字段：先查台账名字（FW_TEXT_START/Image/FDT/INITRD），再当数字解析（0x... 或十进制）
static bool parse_addr(const char* s, uint32_t* out) {
    for (const NamedAddr& n : NAMED_ADDR)
        if (strcmp(s, n.name) == 0) { *out = n.addr; return true; }
    char* end = nullptr;
    unsigned long v = strtoul(s, &end, 0);
    if (end == s || *end != '\0' || v > 0xFFFFFFFFul) return false;
    *out = (uint32_t)v;
    return true;
}

// 单件镜像：**越界必须报错退出**（不许静默丢镜像 —— 那会变成"跑不通但看不出为什么"）
static void load_image(const char* path, uint32_t addr) {
    if (addr < BASE || (uint64_t)(addr - BASE) >= MEM_BYTES) {
        printf("FAIL: load address 0x%08X outside tb memory window 0x%08X..0x%08X\n",
               addr, BASE, BASE + MEM_BYTES - 1);
        exit(1);
    }
    FILE* f = fopen(path, "rb");
    if (!f) { printf("FAIL: cannot open %s\n", path); exit(1); }
    uint32_t room = MEM_BYTES - (addr - BASE);
    size_t n = fread(mem_u8() + (addr - BASE), 1, room, f);
    int extra = fgetc(f);                    // 还有数据 ⇒ 装不下
    fclose(f);
    if (extra != EOF) {
        printf("FAIL: image %s does not fit at 0x%08X (window ends 0x%08X)\n",
               path, addr, BASE + MEM_BYTES - 1);
        exit(1);
    }
    printf("loaded %s -> %zu bytes at 0x%08X\n", path, n, addr);
}

// SOC_PROG 的多镜像语法：`<文件>@<地址>[,<文件>@<地址>...]`；省 `@` ⇒ BASE（Task 8 兼容）
static void load_progs(const char* spec) {
    std::string s(spec);
    size_t pos = 0;
    for (;;) {
        size_t comma = s.find(',', pos);
        std::string item = s.substr(pos, (comma == std::string::npos) ? std::string::npos : comma - pos);
        if (!item.empty()) {
            size_t at = item.rfind('@');
            std::string file = (at == std::string::npos) ? item : item.substr(0, at);
            uint32_t addr = BASE;
            if (at != std::string::npos) {
                std::string a = item.substr(at + 1);
                if (!parse_addr(a.c_str(), &addr)) {
                    printf("FAIL: SOC_PROG 里地址无法解析（既不是台账名字也不是数字）：%s\n",
                           item.c_str());
                    exit(1);
                }
            }
            if (file.empty()) { printf("FAIL: SOC_PROG 条目缺文件名：%s\n", item.c_str()); exit(1); }
            load_image(file.c_str(), addr);
        }
        if (comma == std::string::npos) break;
        pos = comma + 1;
    }
    memcpy(orig, mem, MEM_BYTES);
    printf("first words: mem[0]=0x%08X mem[1]=0x%08X mem[2]=0x%08X mem[3]=0x%08X\n",
           mem[0], mem[1], mem[2], mem[3]);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* prog = getenv("SOC_PROG") ? getenv("SOC_PROG") : "sim/probe_console.bin";
    const char* expect_sub = getenv("SOC_EXPECT");    // 非空 ⇒ 判据改成"线上文本包含该子串"
    if (getenv("SOC_MAX_CYC"))   MAX_CYC = strtoull(getenv("SOC_MAX_CYC"), nullptr, 0);
    if (getenv("SOC_TRACE_UNTIL")) TRACE_UNTIL = strtoull(getenv("SOC_TRACE_UNTIL"), nullptr, 0);
    int load_mode = getenv("SOC_LOAD_MODE") ? atoi(getenv("SOC_LOAD_MODE")) : 0;
    long bdiv = getenv("SOC_BAUD_DIV") ? strtol(getenv("SOC_BAUD_DIV"), nullptr, 0) : 54;
    if (getenv("SOC_NO_EARLY_EXIT")) { /* 与 M0-b 同名开关，本装置总是跑到判据或超时 */ }
    // ★ Gate 2：内存窗口可在运行期放大（`SOC_MEM_MIB=<MiB>`，4..1024）。
    //   **默认不设 ⇒ MEM_WORDS/MEM_BYTES 与历史装置一字不差**（只需把静态数组换成等长 vector）。
    if (getenv("SOC_MEM_MIB")) {
        unsigned long mib = strtoul(getenv("SOC_MEM_MIB"), nullptr, 0);
        if (mib < 4 || mib > 1024) {
            printf("FAIL: SOC_MEM_MIB=%lu 越界（允许 4..1024 MiB）\n", mib);
            return 1;
        }
        MEM_WORDS = (uint32_t)(mib * 1024 * 1024 / 4);
        MEM_BYTES = MEM_WORDS * 4u;
    }
    mem_store.assign(MEM_WORDS, 0);
    orig_store.assign(MEM_WORDS, 0);
    mem = mem_store.data();
    orig = orig_store.data();
    memset(mem, 0, MEM_BYTES);
    load_progs(prog);

    // 线上解码器：位周期 P = 16*bdiv（`Uart16550.scala`：rxTick 周期 = 4*bdiv 拍，
    // 而 `UARTTx` 内部再 4 分频 ⇒ 一个位 = 16*bdiv 拍）。与探针写入的 DLL 同源。
    // ⚠️ OpenSBI v0.8 的 `uart8250_init` 是 `bdiv = in_freq/(16*baud)`（整除）= 54
    //    ⇒ 与默认 54 逐位一致（新版 opensbi 用四舍五入公式，结果同为 54）。
    UartDecoder dec;
    dec.P = 16 * bdiv;

    printf("=== tb mode: nax_mini_soc console | MAX_CYC=%llu | load_mode=%d | decoder P=%ld (=16*%ld) ===\n",
           (unsigned long long)MAX_CYC, load_mode, (long)dec.P, bdiv);
    printf("tb memory window: 0x%08X..0x%08X (%u MiB)\n", BASE, BASE + MEM_BYTES - 1, MEM_BYTES >> 20);
    if (expect_sub)
        printf("criterion: decoded uart text must CONTAIN \"%s\" (substring, on the wire)\n", expect_sub);
    else
        printf("criterion: decode \"NAXMINI\\n\" (8 frames) from uart_txd waveform\n");

    Vnax_mini_soc* dut = new Vnax_mini_soc;

    // ===================== 全部输入绑常量 =====================
    dut->soc_clk = 0;
    dut->async_reset = 1;                       // 异步复位、高有效：先按住
    dut->uart_rxd = 1;                          // 串口空闲高（否则 16550 的 RX 会收到假起始位）
    dut->gpio_in = 0;
    dut->sd_miso = 1;                           // SD 卡不在 ⇒ 全 1 是"无卡"的安全常值
    dut->load_mode = load_mode ? 1 : 0;         // 0 = 正常启动（不在装载模式）
    // 内存从方（本 tb 是内存）
    dut->mem_aw_awready = 1;
    dut->mem_w_wready = 1;
    dut->mem_b_bvalid = 0; dut->mem_b_bid = 0; dut->mem_b_bresp = 0;
    dut->mem_ar_arready = 1;
    dut->mem_r_rvalid = 0; dut->mem_r_rdata = 0; dut->mem_r_rid = 0;
    dut->mem_r_rresp = 0; dut->mem_r_rlast = 0;

    // ===================== AXI4 从方状态 =====================
    struct ArReq { uint32_t addr; int beats; uint32_t id; uint32_t size; };
    std::vector<ArReq> ar_queue;
    bool ar_hs_prev = false;

    int r_state = 0;
    uint32_t r_cur = 0, r_id = 0;
    int r_beats = 0, r_beats_total = 0, r_idx = 0;
    uint32_t r_size = 0;
    bool r_last_sent = false;
    uint64_t n_r_stall = 0;
    // ★ Task 19：B 通道**默认回带 AW id** —— 这是一次**有意的行为修正**（见 docs/探针记录.md「Task 19」）。
    //   根因（T18 取证）：旧 tb 恒 `mem_b_bid = 0`（R 通道的 `mem_r_rid = r_id` 是对的，只有 B 漏了）。
    //   本核 D$ 的双写回槽用 AXI **write id** 区分（`io_mem_write_rsp_payload_id`），
    //   id=1 的 B 若被回成 0 就会被投到 slot0 ⇒ slot1 永不清 ⇒ writebackBusy 恒 1 ⇒ 前端被 halt。
    //   ⇒ 从方**必须**把 awid 回带到 bid。旧默认（恒 0）**本身就是错的**，不是"默认语义"，
    //     因此本轮**不再**以旧日志当"默认不变"的基线（新基线见 sim/reglogs/t19_baseline_pack8.log）。
    //   反开关 `SOC_BID_ZERO=1` 复现旧缺陷行为 —— 它同时是负对照钩子：
    //     文件末的 `[BID-CHK]` 直方图断言（AW id 直方图 == B id 直方图）必须因此翻红。
    //   T18 的开关键 `SOC_BID_MIRROR` 现已**失效（no-op）**——默认就是回带，旧复现命令照跑不报错。
    const bool BID_ZERO = getenv("SOC_BID_ZERO") != nullptr;
    // ★ Gate 2（M2-b）：从方的 "W 早于 AW" 处置开关（`SOC_W_STALL=1`；**默认关 = 旧行为逐字节相同**）
    //   背景见下方 W 通道处的详细注释与 docs/冻结调查-2026-09-30.md §1.3 / §6 未定性 #2。
    // ★ T36：**默认开**——从方只在有 pending AW 时收 W beat。旧默认（不收就丢）整跑实测
    //   `orphan_w=17`（17 拍 W 被静默吞掉 ⇒ 17 次写丢失 ⇒ 堆/链表被写坏）。
    //   `SOC_NO_W_STALL=1` 回旧（会丢 beat 的）行为做对照；`SOC_W_STALL=1` 仍可显式打开。
    const bool W_STALL = getenv("SOC_NO_W_STALL") == nullptr;
    // ★ Gate 2（M2-b）第三轮：`SOC_AW_GATE=1` —— 从方只在"本拍真看到 awvalid"时才抬 awready。
    //   取证目标（见 docs/M2-Gate2-2026-09-30.md §14）：`rtl/NaxMiniGlue.v:3239`
    //     `io_mem_aw_awvalid = loadActive ? loadAwValid : io_cpuMem_awvalid & ~memRdBusy`
    //     `io_cpuMem_awready = io_mem_aw_awready`                     ← **恒 1 的直通**
    //   ⇒ 当 `memRdBusy=1`（一次读突发在飞）时，胶合块**吞掉** AW，却仍告诉核"成交了"
    //     （`Axi4Bridge` 的 `a_cmdFork_fire = a_cmd_forked_valid && aw_ready`）⇒ 核**不再重发**这笔 AW。
    //   本开关让从方把 `awready` 跟着 `awvalid` 走 ⇒ "被吞掉的 AW"变成可退让 ⇒ 若因此**解冻**，
    //   即证实"写回槽不清 = 那笔写回的 AW 永远到不了从方 ⇒ 永远等不到 B"。
    //   AXI 合规（从方允许"先见 valid 再抬 ready"；主方在本核里是 fork 保持 valid 直到 fire）。
    //   默认关 ⇒ `mem_aw_awready` 保持初值 1（从不重写）⇒ 与旧行为逐字节相同。
    const bool AW_GATE = getenv("SOC_AW_GATE") != nullptr;
    uint32_t b_id = 0;
    // ★ Task 19：AW / B 两个方向的 id 直方图（按 4bit id 分桶）—— 常驻断言的原始数据。
    uint32_t aw_hist[16] = {0}, b_hist[16] = {0};
    printf("tb B channel id: %s | 常驻断言 [BID-CHK] AW id 直方图 == B id 直方图\n",
           BID_ZERO ? "FORCED-0（SOC_BID_ZERO=1：复现 T18 的旧缺陷行为，断言应翻红）"
                    : "mirror AW id（默认；Task 19 设计契约：从方必须回带 awid）");
    printf("tb W channel 从方: %s\n",
           W_STALL ? "SOC_W_STALL=1（aw_q 空时压住 wready ⇒ 不丢先到的 W 拍；AXI 合规停顿）"
                   : "默认（aw_q 空时丢弃先到的 W 拍 ⇒ aw_orphan_w++，与旧版逐字节相同）");
    printf("tb AW channel 从方: %s\n",
           AW_GATE ? "SOC_AW_GATE=1（awready 跟随 awvalid ⇒ 胶合块吞掉的 AW 可退让）"
                   : "默认（awready 恒 1）");
    // ★ Task 14：R 通道**时序形态**诊断旋钮（默认 0/0 ⇒ 行为与本装置旧版逐拍同义，见 Step 3 的 diff 回归）。
    //   用途：把"内存从方的 R 节奏"当自变量，判定核侧 I$ 填充是否对 R 到达节奏敏感
    //   （T14 实测：本装置的默认节奏 = 首拍 1 拍延迟 + beat 之间无空隙；T13 的 64→32 桥给核的节奏
    //    是"每 2 拍 1 个上游 beat"，两者只差节奏，数据一字不差）。
    //   SOC_R_LATENCY  = 每个 burst 首拍前的额外空拍数（默认 0）
    //   SOC_R_BEAT_GAP = 相邻 beat 之间插入的空拍数（默认 0）
    const int R_LATENCY  = getenv("SOC_R_LATENCY")  ? atoi(getenv("SOC_R_LATENCY"))  : 0;
    const int R_BEAT_GAP = getenv("SOC_R_BEAT_GAP") ? atoi(getenv("SOC_R_BEAT_GAP")) : 0;
    const bool R_ZERO_LAT = getenv("SOC_R_ZERO_LAT") != nullptr;   // 见下面的诊断支（非 AXI 合规）
    int r_lat_remain = 0, r_gap_remain = 0;

    struct AwTxn { uint32_t addr; int len; int beat; uint32_t size; uint32_t id; };
    std::vector<AwTxn> aw_q;
    bool b_valid = false, b_acked = false;
    int aw_orphan_w = 0;
    uint64_t n_wlast_mismatch = 0;
    uint32_t w_addr_err = 0;
    // ★ Gate 2（M2-b）：从方的 "W 早于 AW" 处置 —— **运行期开关，默认关 ⇒ 行为与旧版逐字节相同**。
    //   背景（docs/冻结调查-2026-09-30.md §1.3 / §6 未定性 #2）：本核的 D$ 写回会**先抬 wvalid、后发 AW**
    //   （AXI 明确允许），而本装置旧版在 `aw_q.empty()` 时把该拍 W **直接丢弃**（`aw_orphan_w++`）。
    //   OpenSBI 1.6 镜像实测 `orphan_w=8/16`（= 1~2 个 8 拍突发被丢），而 0.8 时代的镜像与 pack 探针全 0。
    //   `SOC_W_STALL=1` ⇒ 从方在"手上没有未决 AW"时**把 wready 压 0**（AXI 合规的从方停顿），
    //   让主方按 AXI 规矩 hold 住 W 拍直到 AW 到达，从而**不丢任何一拍**。
    //   默认（不设该 env）⇒ `mem_w_wready` 恒 1、`aw_orphan_w` 照旧累加 ⇒ 判据装置一行不差。
    uint64_t n_w_stall_cyc = 0;          // W 被从方停顿的拍数（仅在 W_STALL 时累加）
    uint64_t n_w_stall_first = 0;
    // 被丢弃/被停住的 W 拍现场（只给 [AXI-WARN] 打印用；默认路径下这几个值是"刚握手那拍"的原值）
    uint64_t wdata_dbg = 0;
    uint32_t wstrb_dbg = 0;
    unsigned wlast_dbg = 0;
    bool w_orphan_now = false;      // 本拍是否真的丢了一拍 W（只用来门控 [AXI-WARN] 打印）

    uint64_t n_ar = 0, n_aw = 0, n_w = 0, n_r_beats = 0, n_b_hs = 0;
    // ★ T36：**只看线上电平沿**（与解码成功与否无关）—— 用来区分"核真停发" vs "装置解码器卡住"。
    //   判据：`n_txd_edges` 在收尾时还在涨、且 `last_txd_edge_cyc` 贴近最大拍 ⇒ 核仍在发 ⇒ 问题在解码/判据侧。
    uint64_t n_txd_edges = 0, last_txd_edge_cyc = 0;
    int prev_txd_lvl = -1;
    uint64_t n_drop_oob_r = 0, n_drop_oob_w = 0;
    // ★ T31（spec 2026-10-01-dcache-state-probe-design.md §2）：逐笔台账改成**可窗口**。
    //   默认（不设下面三个 env）⇒ 与既有行为**逐字节相同**：计数上限 400、不过滤窗口。
    //   设了窗口 ⇒ **以窗口为准**（计数上限不再生效），用来打"冲刷启动前后"那一段。
    const uint64_t LOG_LIMIT  = getenv("SOC_LOG_LIMIT")    ? strtoull(getenv("SOC_LOG_LIMIT"), nullptr, 0) : 400ull;
    const long     LOG_WIN_FROM = getenv("SOC_LOG_WIN_FROM") ? strtol(getenv("SOC_LOG_WIN_FROM"), nullptr, 0) : -1;
    const long     LOG_WIN_TO   = getenv("SOC_LOG_WIN_TO")   ? strtol(getenv("SOC_LOG_WIN_TO"),   nullptr, 0) : -1;
    const bool     LOG_WIN_ON   = (LOG_WIN_FROM >= 0 || LOG_WIN_TO >= 0);
    auto win_ok = [&]() -> bool {
        if (LOG_WIN_FROM >= 0 && (long)cyc < LOG_WIN_FROM) return false;
        if (LOG_WIN_TO   >= 0 && (long)cyc > LOG_WIN_TO)   return false;
        return true;
    };
    auto log_le = [&](uint64_t n) -> bool { return LOG_WIN_ON ? win_ok() : (n <= LOG_LIMIT); };
    auto log_lt = [&](uint64_t n) -> bool { return LOG_WIN_ON ? win_ok() : (n <  LOG_LIMIT); };

    // ---- 串口解码器 + CsrTracer 观测 ----
    uint64_t n_tracer = 0;
    uint64_t n_frames_prev = 0;
    const char* pass_reason = "";

    // ===== 判据（唯一定义）=====
    auto criterion_ok = [&]() -> bool {
        if (dec.stop_errors != 0) return false;
        if (expect_sub) return dec.text.find(expect_sub) != std::string::npos;
        return strcmp(dec.text.c_str(), CONSOLE_EXPECT) == 0;
    };

#ifdef TB_PEEK_CODE
    // ---- 装置内视（Verilator 内部层次名；只在 TB_PEEK=1 时打印）-------------------
    // 用途：分辨"CPU 卡在等 THRE"还是"console 收了 8 笔却只发 4 帧"这类故障。
    // 访问的是 rtl/NaxMiniGlue.v 里 `u_glue/console` 的**实际**寄存器名（生成产物成员名）。
    const bool PEEK = getenv("TB_PEEK") != nullptr;
    auto& C_TXDATA = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__txDataReg;
    auto& C_PEND   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__txPend;
    auto& C_BUSY   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__txPend;  // 占位，见下
    auto& C_TXST   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__tx__DOT__state;
    auto& C_TXDN   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__tx__DOT__dataReg;
    auto& C_TXPND  = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__tx__DOT__pend;
    auto& C_THRE   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__threPending;
    auto& C_AWR    = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__awReady;
    auto& C_WWR    = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__wReady;
    auto& C_RV     = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__rValid;
    auto& C_RD     = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__rData;
    auto& C_RXHAVE = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__rxHaveReg;
    auto& G_RSEL   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__rSel;
    auto& G_WSEL   = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__wSel;
    uint64_t n_con_wr = 0, n_con_rd = 0, n_rd_thre1 = 0, n_rd_thre0 = 0, n_rd_ack = 0;
    // 前端取指 PC + ALU0 执行 PC（环形缓冲，收尾时打最后 48 条 ⇒ 定位卡在哪条指令）
    auto& F_PC = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_serialized_PC_0;
    auto& A_PC = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__ALU0_ExecutionUnitBase_pipeline_fetch_1_PC;
    auto& A_V  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__ALU0_ExecutionUnitBase_pipeline_fetch_1_valid;
    auto& EX_V = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__DecoderPlugin_setup_exceptionPort_valid;
    auto& EX_EPC = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__DecoderPlugin_setup_exceptionPort_payload_epc;
    auto& EX_CODE = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_exception_code;
    // ★ Task 9 补：**上面那根 EX_CODE 不是 mcause**！`rtl/NaxSocMini.v:52584` 显示
    //   `PrivilegedPlugin_logic_exception_code = PrivilegedPlugin_logic_reschedule_payload_cause`
    //   （随特权态 FSM 状态机切换语义），在冲刷路径上它就是 0 ⇒ **不能**把 "code=0" 读成
    //   "INSTRUCTION_ADDRESS_MISALIGNED"（T8 记录里的那个等式存疑）。
    //   真正能读到的 mcause 走这条**上游明文路径**（`rtl/NaxSocMini.v:38652-38655`）：
    //     `PrivilegedPlugin_logic_rescheduleUnbuffered_payload_cause = commit 的 reschedule cause;
    //      if (<decoder 有异常>) 它 = DecoderPlugin_setup_exceptionPort_payload_cause;`
    //   ⇒ 后者只赋 0b1100(12=取指页错) / 0b0001(1=取指访问错) / 0b0010(2=非法指令)，**从不赋 0**。
    //   （直接引 `DecoderPlugin_..._payload_cause` 编不过：那根线在 Verilator 里被优化掉了；
    //     `--public-flat-rw` 会把整个层次名方案改掉 ⇒ 本文件所有内视路径全废，不采用。）
    auto& EX_MCAUSE = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_rescheduleUnbuffered_payload_cause;

    // ★ M2-b Gate 2 第六轮（有界采集）：**真 mtval** + 「被特权态 FSM 接受的那一次 trap」的
    //   **注册副本**三元组（cause/epc/tval）。走的是**同一条明文路径**（`rtl/NaxSocMini.v:38589-38603`
    //   + `:58486-58487`）：
    //     组合：`PrivilegedPlugin_logic_rescheduleUnbuffered_payload_{cause,epc,tval}`
    //       ——(rValid 有效，打一拍)——> `…_rescheduleUnbuffered_rData_{cause,epc,tval}`
    //       ——> `PrivilegedPlugin_logic_reschedule_payload_{cause,epc,tval}` ——> CSR RAM
    //            （`rl:25013` 把 tval 喂给 `PrivilegedPlugin_setup_ramWrite_data`；即 mtval 的真值）。
    //   ⇒ **`rValid` 抬升那一拍**的 rData 三元组 = 这次真正要写进 (mcause, mepc, mtval) 的值。
    //   （比 `_payload_*` 更贴"落进 CSR 的那一次"；`_payload_tval` 也一并抓，便于交叉校验。）
    auto& EX_PTVAL  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_rescheduleUnbuffered_payload_tval;
    auto& EX_RVALID = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_rescheduleUnbuffered_rValid;
    auto& EX_RCAUSE = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_rescheduleUnbuffered_rData_cause;
    auto& EX_REPC   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_rescheduleUnbuffered_rData_epc;
    auto& EX_RTVAL  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__PrivilegedPlugin_logic_rescheduleUnbuffered_rData_tval;

    // ---- ★ Task 12：AlignerPlugin（取指行 → 指令装配）逐拍观测 ----------------------
    // 目的：把"**送给译码器的那个 32bit 窗口 + 它的 PC + slice 边界**"在失败前后逐拍打出来，
    //   与 ELF 逐字节对账，指认"哪一拍开始不一致"。
    //   上游源码：NaxRiscv/src/main/scala/naxriscv/fetch/AlignerPlugin.scala（只读）。
    //   * s2m  = aligner 的输入阶段（= fetch pipeline 最后一拍，带新取指行 WORD + FETCH_PC）
    //   * buf  = aligner 内部的"跨行半字携带"寄存器（buffer.data/mask/pc）
    //   * extr = extractors(0/1) → FrontendPlugin.aligned 阶段的 (PC, 32bit 窗口)
    // 全部只在 TB_PEEK_CODE 打开时编译 ⇒ 判据装置（不带该宏）逐字节不变。
    //   注意：有几个上游信号被 Verilator 优化掉了（`AlignerPlugin_setup_s2m_valid/_isFlushingRoot`、
    //   `AlignerPlugin_logic_slices_carry`、`FrontendPlugin_aligned_valid/PC_0`），所以这里取的是
    //   **等价且确实存在**的那一组：s2m 的有效性用 `AlignerPlugin_logic_isInputValid`、carry 用
    //   `{isInputValid ? MASK_FRONT : 0, buffer_mask}` 现场拼、窗口 PC 用**下一级（decompressed）**
    //   的 PC 寄存器（= aligned 阶段 PC 打一拍，逐拍可对齐）。`grep` 出来的成员名清单见
    //   sim/reglogs/t12_peek_members.txt。
    auto& AL_WORD  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_Fetch_WORD;
    auto& AL_PC    = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_Fetch_FETCH_PC;
    auto& AL_SRDY  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_ready;
    auto& AL_MFRT  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_MASK_FRONT;
    auto& AL_MBCK  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_MASK_BACK;
    auto& AL_BRVAL = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_Prediction_WORD_BRANCH_VALID;
    auto& AL_BRSL  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_Prediction_WORD_BRANCH_SLICE;
    auto& AL_BRPN  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_setup_s2m_Prediction_WORD_BRANCH_PC_NEXT;
    auto& AL_BMASK = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_buffer_mask;
    auto& AL_BPC   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_buffer_pc;
    auto& AL_BDATA = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_buffer_data;
    auto& AL_BRVL  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_buffer_branchValid;
    auto& AL_BRSL2 = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_buffer_branchSlice;
    auto& AL_IVAL  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_isInputValid;
    auto& AL_FIN   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_fireInput;
    auto& AL_FOUT  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_fireOutput;
    auto& AL_REM   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_slices_remains_2;
    auto& AL_CORR  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__AlignerPlugin_logic_correctionSent;
    // 送译码器的东西：aligned 阶段（组合，本拍）+ decompressed 阶段（寄存器，下一拍）
    auto& AL_ORDY  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_ready_output;
    auto& AL_OIN0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_Frontend_INSTRUCTION_ALIGNED_0;
    auto& AL_OIN1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_Frontend_INSTRUCTION_ALIGNED_1;
    auto& AL_OMK0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_Frontend_MASK_ALIGNED_0;
    auto& AL_OMK1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_Frontend_MASK_ALIGNED_1;
    auto& AL_OSL0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_Fetch_INSTRUCTION_SLICE_COUNT_0;
    auto& AL_OSL1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_aligned_Fetch_INSTRUCTION_SLICE_COUNT_1;
    auto& AL_DVAL  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decompressed_valid;
    auto& AL_DPC0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decompressed_PC_0;
    auto& AL_DPC1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decompressed_PC_1;
    auto& AL_DIN0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decompressed_Frontend_INSTRUCTION_ALIGNED_0;
    auto& AL_DIN1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decompressed_Frontend_INSTRUCTION_ALIGNED_1;
    auto& AL_ILL0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decoded_Frontend_INSTRUCTION_ILLEGAL_0;
    auto& AL_ILL1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decoded_Frontend_INSTRUCTION_ILLEGAL_1;
    auto& AL_MOP0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decoded_Frontend_MICRO_OP_0;
    auto& AL_MOP1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FrontendPlugin_decoded_Frontend_MICRO_OP_1;

    // ---- ★ Task 18：核内部"谁占着不放"逐拍观测（TB_CORE=1 + SOC_WIN_FROM/TO 限定窗口）----
    // 目的：把帧 0x8000_0760 的冻结现场拆成 (a) 前端不取指 / (b) 有取指但不提交，并逐项回答
    //   "ROB 头尾 / 发射队列 / LSU(store queue) / MMU refill / wfi / CSR 未决"里是谁在占。
    //   全部只读 DUT 内部信号，且只在 TB_PEEK_CODE + 运行期 TB_CORE 打开时打印
    //   ⇒ 判据装置（不带 -DTB_PEEK_CODE）逐字节不变。
    #define NX(sig) dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__##sig
    auto& N_FR_V      = NX(FrontendPlugin_serialized_valid);
    auto& N_FR_PC     = NX(FrontendPlugin_serialized_PC_0);
    auto& N_FR_INC    = NX(FrontendPlugin_serialized_PC_INC_0);
    auto& N_FR_TGT    = NX(FrontendPlugin_serialized_PC_TARGET_0);
    auto& N_FR_FLU    = NX(FrontendPlugin_serialized_isFlushed);
    auto& N_S0_RDY    = NX(FetchPlugin_stages_0_ready_output);
    auto& N_DIS_V     = NX(FrontendPlugin_dispatch_valid);
    auto& N_DIS_RDY   = NX(FrontendPlugin_dispatch_ready);
    auto& N_ALG_RDY   = NX(FrontendPlugin_aligned_ready_output);
    auto& N_ALC_RDY   = NX(FrontendPlugin_allocated_ready_output);
    auto& N_DEC_RDY   = NX(FrontendPlugin_decoded_ready_output);
    auto& N_DEC_FLR   = NX(FrontendPlugin_decoded_isFlushingRoot);
    // 提交 / ROB 指针
    auto& N_ROB_EMPTY = NX(CommitPlugin_logic_ptr_empty);
    auto& N_ROB_ALLOC = NX(CommitPlugin_logic_ptr_alloc);
    auto& N_ROB_COMMIT= NX(CommitPlugin_logic_ptr_commit);
    auto& N_ROB_FREE  = NX(CommitPlugin_logic_ptr_free);
    auto& N_ROB_CANFR = NX(CommitPlugin_logic_ptr_canFree);
    auto& N_CM_MASK   = NX(CommitPlugin_logic_commit_mask);
    auto& N_CM_HEAD   = NX(CommitPlugin_logic_commit_head);
    auto& N_CM_LINE   = NX(CommitPlugin_logic_commit_lineCommited);
    // 重定向（flush / reschedule / trap）
    auto& N_RS_V      = NX(CommitPlugin_logic_reschedule_valid);
    auto& N_RS_CAUSE  = NX(CommitPlugin_logic_reschedule_cause);
    auto& N_RS_ROBID  = NX(CommitPlugin_logic_reschedule_robId);
    auto& N_RS_TRAP   = NX(CommitPlugin_logic_reschedule_trap);
    auto& N_RS_SKIP   = NX(CommitPlugin_logic_reschedule_skipCommit);
    auto& N_RS_REASON = NX(CommitPlugin_logic_reschedule_reason);
    auto& N_RS_TGT    = NX(CommitPlugin_logic_reschedule_pcTarget);
    // LSU：store queue / 仲裁 / flush 通路 / fence
    auto& N_SQ_ALLOC  = NX(Lsu2Plugin_logic_sq_ptr_alloc);
    auto& N_SQ_COMMIT = NX(Lsu2Plugin_logic_sq_ptr_commit);
    auto& N_SQ_FREE   = NX(Lsu2Plugin_logic_sq_ptr_free);
    auto& N_SQ_WBACK  = NX(Lsu2Plugin_logic_sq_ptr_writeBack);
    auto& N_S1_V      = NX(Lsu2Plugin_logic_lqSqArbitration_s1_valid);
    auto& N_S1_LQF    = NX(Lsu2Plugin_logic_lqSqArbitration_s1_LQ_ROB_FULL);
    auto& N_S1_SQF    = NX(Lsu2Plugin_logic_lqSqArbitration_s1_SQ_ROB_FULL);
    auto& N_LSU_FLB   = NX(Lsu2Plugin_logic_flush_busy);
    auto& N_LSU_FLD   = NX(Lsu2Plugin_logic_flush_doit);
    auto& N_LSU_CACHE = NX(Lsu2Plugin_setup_cacheStore_cmd_valid);
    auto& N_FEN_DONE  = NX(Lsu2Plugin_logic_fencer_done);
    auto& N_FEN_TRIG  = NX(Lsu2Plugin_logic_fencer_trigger);
    auto& N_FEN_LW    = NX(Lsu2Plugin_logic_fencer_loadsWait);
    auto& N_FEN_SW    = NX(Lsu2Plugin_logic_fencer_storesWait);
    auto& N_DC_FLSH   = NX(DataCachePlugin_logic_cache__DOT__store_ctrl_needFlushSel);
    // MMU：refill 状态机 / 失效
    auto& N_MMU_WS    = NX(MmuPlugin_logic_refill_wantStart);
    auto& N_MMU_ST    = NX(MmuPlugin_logic_refill_stateReg);
    auto& N_MMU_STN   = NX(MmuPlugin_logic_refill_stateNext);
    auto& N_MMU_VIRT  = NX(MmuPlugin_logic_refill_virtual);
    auto& N_MMU_INVR  = NX(MmuPlugin_logic_invalidate_requested);
    auto& N_MMU_INVD  = NX(MmuPlugin_logic_invalidate_done);
    auto& N_MMU_SATP  = NX(MmuPlugin_logic_satp_mode);
    // wfi / 特权态 FSM / 异常
    auto& N_WFI_F1    = NX(EU0_ExecutionUnitBase_pipeline_fetch_1_EnvCallPlugin_WFI);
    auto& N_WFI_E1    = NX(EU0_ExecutionUnitBase_pipeline_execute_1_EnvCallPlugin_WFI);
    auto& N_WFI_E2    = NX(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_WFI);
    auto& N_PRIV_FSM  = NX(PrivilegedPlugin_logic_fsm_stateReg);
    auto& N_RS_UNB_C  = NX(PrivilegedPlugin_logic_rescheduleUnbuffered_payload_cause);
    auto& N_RS_UNB_E  = NX(PrivilegedPlugin_logic_rescheduleUnbuffered_payload_epc);
    // store queue 前 4 项的 valid / committed / dataValid / 等待 MMU refill
    auto& N_SQ0_V     = NX(Lsu2Plugin_logic_sq_regs_0_valid);
    auto& N_SQ0_C     = NX(Lsu2Plugin_logic_sq_regs_0_commited);
    auto& N_SQ0_DV    = NX(Lsu2Plugin_logic_sq_regs_0_dataValid);
    auto& N_SQ0_MR    = NX(Lsu2Plugin_logic_sq_regs_0_waitOn_mmuRefillAny);
    auto& N_SQ1_V     = NX(Lsu2Plugin_logic_sq_regs_1_valid);
    auto& N_SQ1_C     = NX(Lsu2Plugin_logic_sq_regs_1_commited);
    auto& N_SQ1_DV    = NX(Lsu2Plugin_logic_sq_regs_1_dataValid);
    auto& N_SQ2_V     = NX(Lsu2Plugin_logic_sq_regs_2_valid);
    auto& N_SQ2_DV    = NX(Lsu2Plugin_logic_sq_regs_2_dataValid);
    auto& N_SQ3_V     = NX(Lsu2Plugin_logic_sq_regs_3_valid);
    auto& N_SQ3_DV    = NX(Lsu2Plugin_logic_sq_regs_3_dataValid);
    // ---- ★ Task 18 第二轮：真正的取指 PC / 重定向源 / fence.i 通路 / I$ 失效 ----
    #define NX2(sig) dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__##sig
    auto& N_FETCHPC   = NX2(PcPlugin_logic_fetchPc_pc);              // ★ 真·取指 PC 寄存器
    auto& N_FETCHFIR  = NX2(PcPlugin_logic_fetchPc_output_fire);     // 取指请求是否发生
    auto& N_JUMPV     = NX2(PcPlugin_logic_jump_pcLoad_valid);       // 有人要求装 PC
    auto& N_JUMPTGT   = NX2(PcPlugin_logic_jump_target_1);           // 装进去的目标
    auto& N_FETCHCORR = NX2(PcPlugin_logic_fetchPc_correction);
    auto& N_S1PC      = NX2(FetchPlugin_stages_1_Fetch_FETCH_PC);    // I$ 查表级 PC
    auto& N_PR_JMPV   = NX2(PrivilegedPlugin_setup_jump_valid);
    auto& N_PR_JMPPC  = NX2(PrivilegedPlugin_setup_jump_payload_pc);
    auto& N_PR_READED = NX2(PrivilegedPlugin_logic_readed);          // CSR 读回值（FLUSH_JUMP 的跳转源）
    auto& N_EC_V      = NX2(EnvCallPlugin_setup_reschedule_valid);
    auto& N_EC_CAUSE  = NX2(EnvCallPlugin_setup_reschedule_payload_cause);
    auto& N_EC_REASON = NX2(EnvCallPlugin_setup_reschedule_payload_reason);
    auto& N_EC_FSM    = NX2(EnvCallPlugin_logic_flushes_stateReg);
    auto& N_EC_FSMN   = NX2(EnvCallPlugin_logic_flushes_stateNext);
    auto& N_EC_FENCEI = NX2(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_FENCE_I);
    auto& N_EC_FENCEV = NX2(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_FENCE_VMA);
    auto& N_EC_FLUSHD = NX2(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_FLUSH_DATA);
    auto& N_EC_ECALL  = NX2(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_ECALL);
    auto& N_EC_XRET   = NX2(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_XRET);
    auto& N_EC_EBRK   = NX2(EU0_ExecutionUnitBase_pipeline_execute_2_EnvCallPlugin_EBREAK);
    auto& N_HITS      = NX2(CommitPlugin_logic_reschedule_portsLogic_hits);
    auto& N_RS_FRESH  = NX2(CommitPlugin_logic_reschedule_fresh);
    auto& N_IC_INVR   = NX2(FetchCachePlugin_logic_invalidate_requested);
    auto& N_IC_INVD   = NX2(FetchCachePlugin_logic_invalidate_done);
    auto& N_IC_CNT    = NX2(FetchCachePlugin_logic_invalidate_counter);
    auto& N_IC_IVP    = NX2(FetchCachePlugin_setup_invalidatePort_cmd_valid);
    auto& N_IC_IVR    = NX2(FetchCachePlugin_setup_invalidatePort_rsp_valid);
    auto& N_IC_RSV    = NX2(FetchCachePlugin_logic_refill_start_valid);
    auto& N_IC_RV     = NX2(FetchCachePlugin_logic_refill_valid);
    auto& N_IC_RCS    = NX2(FetchCachePlugin_logic_refill_cmdSent);
    auto& N_IC_REDO   = NX2(FetchCachePlugin_logic_read_ctrl_redoIt);
    auto& N_IC_RJMP   = NX2(FetchCachePlugin_setup_redoJump_valid);
    auto& N_LSU_FPC   = NX2(Lsu2Plugin_setup_flushPort_cmd_valid);
    // ★ Task 18 第三轮：LSU flush 的推进指针 + D$ 写回忙 + D$ refill
    auto& N_WBBUSY    = NX2(DataCachePlugin_logic_cache_io_writebackBusy);
    auto& N_FL_CPTR   = NX2(Lsu2Plugin_logic_flush_cmdPtr);
    auto& N_FL_RPTR   = NX2(Lsu2Plugin_logic_flush_rspPtr);
    auto& N_FL_BUSY   = NX2(Lsu2Plugin_logic_flush_busy);
    auto& N_FL_DOIT   = NX2(Lsu2Plugin_logic_flush_doit);
    auto& N_CS_ADDR   = NX2(Lsu2Plugin_setup_cacheStore_cmd_payload_address);
    auto& N_REF_FULL  = NX2(DataCachePlugin_logic_cache__DOT__refill_full);
    auto& N_REF_PUSH  = NX2(DataCachePlugin_logic_cache__DOT__refill_push_valid);
    auto& N_ST2_V     = NX2(DataCachePlugin_logic_cache__DOT__store_pipeline_stages_2_valid);
    // ★ Task 18 第四轮：D$ writeback 槽（io_writebackBusy = slot0|slot1|snoopTagUpdate）
    #define NXD(sig) dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__DataCachePlugin_logic_cache__DOT__##sig
    auto& N_WB0_V   = NXD(writeback_slots_0_valid);
    auto& N_WB1_V   = NXD(writeback_slots_1_valid);
    auto& N_WB0_RD  = NXD(writeback_slots_0_readCmdDone);
    auto& N_WB0_VB  = NXD(writeback_slots_0_victimBufferReady);
    auto& N_WB0_WR  = NXD(writeback_slots_0_writeCmdDone);
    auto& N_WB0_A   = NXD(writeback_slots_0_address);
    auto& N_WB0_F   = NXD(writeback_slots_0_fire);
    auto& N_SNOOPTU = NXD(store_ctrl_snoop_didTagUpdate);
    auto& N_RFS0_V  = NXD(refill_slots_0_valid);
    // ================= ★ M2-b Gate 2 第二轮：writeback_slots_N_fire 的**命令通路** =========
    // 目标：把 rtl/NaxSocMini.v:68311-68360 的完整条件搬到线上逐拍可读。
    //
    //   writeback_slots_N_valid <= 0  ⟺  writeback_slots_N_fire
    //   writeback_slots_N_fire = (when_DataCache_l1271 && writeback_write_cmd_payload_id==N)   // 通路①: 命令
    //                         || (io_mem_write_rsp_valid   && io_mem_write_rsp_payload_id==N)  // 通路②: 应答
    //   when_DataCache_l1271 = writeback_write_cmd_fire && writeback_write_cmd_payload_last
    //                                                     && !writeback_write_cmd_payload_coherency_release
    //   writeback_write_cmd_* ≡ writeback_write_bufferRead_rData_*（同一拍寄存）
    //   writeback_push_payload_release = 1 for load_ctrl_startRefill / store_ctrl_start(Refill|Flush)
    //                                  = 0 only for snoop askWriteback
    //   ⇒ **通路① 对 release=1 的写回在结构上永不成立**（`!release` 项为 0），只剩通路②。
    // 这就是"命令通路用 D$ 内部缓冲 id + 依赖相干应答"这一假说真正落地的地方。
    auto& N_WB0_REL  = NXD(writeback_slots_0_coherency_release);
    auto& N_WB1_REL  = NXD(writeback_slots_1_coherency_release);
    auto& N_WB0_DIRT = NXD(writeback_slots_0_coherency_dirty);
    auto& N_WB1_DIRT = NXD(writeback_slots_1_coherency_dirty);
    auto& N_WB0_PRID = NXD(writeback_slots_0_coherency_probeId);
    auto& N_WB1_PRID = NXD(writeback_slots_1_coherency_probeId);
    auto& N_WB0_RDD  = NXD(writeback_slots_0_readCmdDone);
    auto& N_WB0_WRD  = NXD(writeback_slots_0_writeCmdDone);
    auto& N_WB1_WRD  = NXD(writeback_slots_1_writeCmdDone);
    auto& N_WB1_A    = NXD(writeback_slots_1_address);
    auto& N_WB1_F    = NXD(writeback_slots_1_fire);
    auto& N_WB1_VB   = NXD(writeback_slots_1_victimBufferReady);
    auto& N_WB1_RDD  = NXD(writeback_slots_1_readCmdDone);
    auto& N_WB_FREE  = NXD(writeback_free);
    // 写命令出口（io_mem_write_cmd_*）的寄存形态
    auto& N_WBC_V    = NXD(writeback_write_bufferRead_rValid);
    auto& N_WBC_R    = NXD(writeback_write_bufferRead_ready);
    auto& N_WBC_F    = NXD(writeback_write_bufferRead_fire);
    auto& N_WBC_ID   = NXD(writeback_write_bufferRead_rData_id);
    auto& N_WBC_LAST = NXD(writeback_write_bufferRead_rData_last);
    auto& N_WBC_REL  = NXD(writeback_write_bufferRead_rData_coherency_release);
    auto& N_WBC_DIRT = NXD(writeback_write_bufferRead_rData_coherency_dirty);
    auto& N_WBC_PRID = NXD(writeback_write_bufferRead_rData_coherency_probeId);
    auto& N_WBC_ADDR = NXD(writeback_write_bufferRead_rData_address);
    // 通路①的合成条件（RTL 原文那根 wire；本窗口内 verilator 保留了它）
    auto& N_L1271    = NXD(when_DataCache_l1271);
    auto& N_L1253    = NXD(when_DataCache_l1253);     // 写命令末拍被 arbiter 收下 ⇒ writeCmdDone
    auto& N_WB_WLAST = NXD(writeback_write_last);
    auto& N_WB_WIDX  = NXD(writeback_write_wordIndex);
    // 槽是谁压进来的
    auto& N_PUSH_V   = NXD(writeback_push_valid);
    auto& N_PUSH_REL = NXD(writeback_push_payload_release);
    auto& N_PUSH_DIRT= NXD(writeback_push_payload_dirty);
    auto& N_PUSH_PRID= NXD(writeback_push_payload_probeId);
    auto& N_PUSH_ADDR= NXD(writeback_push_payload_address);
    // `store_ctrl_startFlush/startRefill`/`load_ctrl_startRefill` 被 verilator 内联掉
    // ⇒ 按 rtl/NaxSocMini.v:69206 的 assign 原文取其**等价底层信号**（tb 的老习惯，同 [COREH]）：
    //   when_DataCache_l1733 = store_ctrl_startRefill || store_ctrl_startFlush
    //   load_ctrl_startRefill = load_pipeline_stages_2_valid && load_ctrl_askRefill
    auto& N_ST_FLUSH = NXD(store_pipeline_stages_2_FLUSH);          // flush 行的标记
    auto& N_ST_RFILL = NXD(_zz_store_ctrl_replacedWayNeedWriteback);// store 侧换出脏行
    auto& N_LD_RFILL = NXD(_zz_load_ctrl_refillWayNeedWriteback);   // load 侧换出脏行
    auto& N_CTRL_ASK = NXD(store_ctrl_askRefill);
    auto& N_SNOOP_ASK= NXD(store_ctrl_snoop_askSomething);
    auto& N_SNOOP_SUC= NXD(store_ctrl_snoop_success);
    #undef NXD
    // 通路②的入口：TL D 通道应答 → DataCache 的 `io_mem_write_rsp_valid`
    // （= `bus_d_valid && !onD_sel`，只可能是 D_RELEASE_ACK；见 rtl/NaxSocMini.v:5828）。
    // DataCache 被 verilator 摊平进 NaxRiscv，`io_mem_write_rsp_valid` 在 NaxRiscv 里被内联掉，
    // 但 **NaxSocMini 那一层**的互联线还在 ⇒ 从 u_soc 取它。
    auto& N_WRSP_V   = dut->rootp->nax_mini_soc->u_soc->__PVT__naxes_0_thread_core_DataCachePlugin_mem_write_rsp_valid;
    // 全跑累计计数（只累加，不推理；§6 手法）
    uint64_t c_wb0_fire = 0, c_wb1_fire = 0, c_l1271 = 0, c_wrsp = 0, c_push = 0;
    uint64_t c_push_rel1 = 0, c_push_rel0 = 0, c_wb0_rise = 0, c_wb1_rise = 0;
    uint64_t c_slot0_stuck = 0, c_slot1_stuck = 0;   // valid && writeCmdDone && !fire 的拍数
    uint64_t first_wb0_fire = 0, last_wb0_fire = 0, last_wrsp = 0, last_wb0_rise = 0;
    int prev_wb0_f = 0, prev_wb1_f = 0, prev_l1271 = 0, prev_wrsp = 0, prev_push = 0;
    int prev_wb0_v = 0, prev_wb1_v = 0;
    const bool WB_DBG = getenv("SOC_WB_DBG") != nullptr;
    // ================= ★ M2-b Gate 2 第二轮：**相干应答那一段**（TL 侧的 Hub）=============
    // 为什么看这里：D$ 的写回走 **C 通道**（`DataCache.mem_write_cmd → naxes_0_dBus C`），
    // `coherent_release=1` ⇒ opcode = `C_RELEASE_DATA/DATA`（脏）或 `C_RELEASE_1`（干净）。
    // 在 Hub（`rtl/NaxSocMini.v:9154`）里：
    //   probe_rsp_hitUpD     = (C opcode == C_RELEASE_1)        ⇒ **本地**直接回 D_RELEASE_ACK
    //   probe_rsp_hitBackend = !(C_RELEASE_1 || C_PROBE_ACK)    ⇒ 脏释放走 **backend**
    // 而 backend 的应答在 `:9453`：下游 D（AXI B）回来且 `downD_toUp_ctx_fromC` 时
    //   才合成 `D_RELEASE_ACK`，`source = downD_toUp_ctx_c_source`。
    // ⇒ 脏写回要清槽，**必须** backend 真的把 A 通道的 PUT 发下去、并拿回 B。
    //   `probe_rsp_toUpD_*` 就是这枚上行 ReleaseAck；`backend_stages_0/1/2` 是它的前置流水。
    #define NXH(sig) dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_logic_hub__DOT__##sig
    auto& H_UPD_V    = NXH(probe_rsp_toUpD_rValid);
    auto& H_UPD_OP   = NXH(probe_rsp_toUpD_rData_opcode);
    auto& H_UPD_SRC  = NXH(probe_rsp_toUpD_rData_source);
    auto& H_UPD_SINK = NXH(probe_rsp_toUpD_rData_sink);
    auto& H_RSP_INV  = NXH(probe_rsp_input_valid);
    auto& H_RSP_HITB = NXH(probe_rsp_hitBackend);
    auto& H_RSP_LOST = NXH(probe_rsp_lostIt);
    auto& H_RSP_BYP  = NXH(probe_rsp_bypass_valid);
    auto& H_RSP_PEND = NXH(_zz_probe_rsp_pending);
    auto& H_B0_V     = NXH(backend_stages_0_valid);
    auto& H_B0_FROMC = NXH(backend_stages_0_FROM_C);
    auto& H_B0_WD    = NXH(backend_stages_0_WRITE_DATA);
    auto& H_B0_ALLO  = NXH(backend_stages_0_SLOT_ALLOCATE);
    auto& H_B0_LAST  = NXH(backend_stages_0_LAST);
    auto& H_B0_SLOT  = NXH(backend_stages_0_SLOT_ID);
    auto& H_B0_A     = NXH(backend_stages_0_ADDRESS);
    auto& H_B1_V     = NXH(backend_stages_1_valid);
    auto& H_B1_WD    = NXH(backend_stages_1_WRITE_DATA);
    auto& H_B1_TOWN  = NXH(backend_stages_1_TO_DOWN);
    auto& H_B1_SLOT  = NXH(backend_stages_1_SLOT_ID);
    auto& H_B1_A     = NXH(backend_stages_1_ADDRESS);
    auto& H_B1_RDYO  = NXH(backend_stages_1_ready_output);
    auto& H_B2_V     = NXH(backend_stages_2_valid);
    auto& H_B2_WD    = NXH(backend_stages_2_WRITE_DATA);
    auto& H_B2_TOWN  = NXH(backend_stages_2_TO_DOWN);
    auto& H_B2_SLOT  = NXH(backend_stages_2_SLOT_ID);
    auto& H_B2_A     = NXH(backend_stages_2_ADDRESS);
    auto& H_SETBUSY  = NXH(setsBusy_hit_downD_valid);
    auto& H_SLOTLOCK = NXH(backend_allocateSlot_slotLock);
    auto& H_PS0_V    = NXH(probe_slots_0_valid);
    auto& H_PS0_P    = NXH(probe_slots_0_pending);
    auto& H_PS0_ACK  = NXH(probe_slots_0_probeAckDataCompleted);
    auto& H_PS1_V    = NXH(probe_slots_1_valid);
    auto& H_PS1_P    = NXH(probe_slots_1_pending);
    auto& H_PS2_V    = NXH(probe_slots_2_valid);
    auto& H_PS3_V    = NXH(probe_slots_3_valid);
    // ★ T32（docs/冻结调查 §14.5 的预登记判据）：脏释放那一枚上行 RELEASE_ACK 到底造没造出来。
    //   `downD_toUp_*` = Hub.scala `downD.toUp`（:772-797）：`hit` 来自 `decodeCtx`，
    //   `upD_valid=1` 才是"要往核发应答"。`hub_io_up_d_valid` 是**过仲裁之后**的 Hub 输出。
    auto& G_ACK_V    = NXH(downD_toUp_upD_valid);
    auto& G_ACK_HIT  = NXH(downD_toUp_hit);
    auto& G_ACK_FIRED= NXH(downD_toUp_fired);
    auto& G_ACK_OP   = NXH(downD_toUp_upD_payload_opcode);
    auto& G_CTXW_V   = NXH(slots_ctxWrite_valid);
    auto& G_CTXW_D   = NXH(slots_ctxWrite_payload_data);
    auto& G_CTXR1    = NXH(slots_ctx_spinal_port1);       // 读端口（rtl:8383，同步读 1 拍）
    auto& G_FREEID   = NXH(slots_freeId);
    auto& G_FREEOH   = NXH(_zz_slots_freeOh_4);           // 4 bit：哪些槽空
    auto& G_VALIDS   = NXH(slots_valids);                 // 4 bit：槽占用（rtl:9683 的公式本体）
    // slots_release_* 未导出，但按 rtl:9400/9401 用这三个分量**逐字重建**：
    //   slots_release_valid = downD_stages_1_valid && !downD_slotRelease_fired && downD_stages_1_LAST
    //   slots_release_payload = downD_stages_1_D_PAYLOAD_source
    auto& G_D1V      = NXH(downD_stages_1_valid);
    auto& G_D1L      = NXH(downD_stages_1_LAST);
    auto& G_D1FIRED  = NXH(downD_slotRelease_fired);
    auto& G_D1SRC    = NXH(downD_stages_1_D_PAYLOAD_source);
    // slots_allocate = isFireing && SLOT_ALLOCATE && FIRST（rtl:9349）；FIRST 未导出 ⇒ 在 tb 里按 RTL 原式镜像：
    //   first := RegNextWhen(LAST, isFireing) init(True)
    auto& G_B0FIRE   = NXH(backend_stages_0_isFireing);
    auto& G_B0LAST   = NXH(backend_stages_0_LAST);
    auto& G_B0SAL    = NXH(backend_stages_0_SLOT_ALLOCATE);
    auto& G_B0WD     = NXH(backend_stages_0_WRITE_DATA);
    auto& G_B0FRC    = NXH(backend_stages_0_FROM_C);
    #undef NXH
    auto& G_HUBIO_DV = dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_logic_hub_io_up_d_valid;
    // ctx 表本体（4 项 × 14bit，bit0 = FROM_C；rtl:8360/8377）
    SData* G_CTX = &dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_logic_hub__DOT__slots_ctx[0];
    // 下游 A 通道（Hub → toAxi4 桥）：这是"有没有把脏写回的 PUT 发下去"的唯一线上口子
    auto& H_DOWNA0_V = dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_down_decoder_core_io_downs_0_a_valid;
    auto& H_DOWNA0_OP= dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_down_decoder_core_io_downs_0_a_payload_opcode;
    auto& H_UPDD_V   = dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_down_decoder_core_io_up_d_valid;
    auto& H_UPDD_OP  = dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_down_decoder_core_io_up_d_payload_opcode;
    auto& H_UPDD_SRC = dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_down_decoder_core_io_up_d_payload_source;
    uint64_t c_hub_upd = 0, c_hub_ain0 = 0, c_hub_inv = 0, c_hub_hitb = 0, c_setbusy = 0;
    uint64_t c_hub_rsp_lost = 0;
    // ★ T32：脏释放上行应答链路的三道口（造没造/有没有 hit/有没有过仲裁）
    uint64_t c_ack_v = 0, c_ack_stuckbeforeio = 0, c_ack_nohit = 0, c_ack_fire = 0, c_ack_ra = 0;
    uint64_t last_ack_v = 0, last_ack_stuck = 0;
    uint64_t c_rel_v = 0, c_rel_spur = 0, last_rel_v = 0, last_rel_spur = 0;   // ★T32：释放/多余释放
    // ★T32 跳二：分配到底有没有"落地"（镜像 FIRST）
    int  g_first = 1, g_prevAlloc = 0, g_prevAllocId = 0;
    uint64_t c_alloc = 0, c_alloc_stickfail = 0, last_alloc = 0, last_stickfail = 0;
    uint64_t c_alloc_w = 0, c_alloc_r = 0, c_alloc_c = 0;
    uint64_t c_b0_occ = 0, c_b1_occ = 0, c_b2_occ = 0;
    uint64_t c_ps0_ack = 0, c_ps1_ack = 0;
    uint64_t last_hub_upd = 0, last_hub_ain0 = 0;
    int prev_hub_upd = 0, prev_hub_ain0 = 0, prev_ps0ack = 0, prev_ps1ack = 0;
    // ================= ★ M2-b Gate 2 第二轮：**mBus（胶合块之前）**的 AXI 台账 ============
    // 目的：把"这一笔写到底丢在哪一层"钉死。tb 原来的台账在 `mem_*`（= 胶合块**之后**），
    //   而 `mBus_*` 是 NaxSocMini 的 AXI 主口（= 胶合块 cpuMem 从口之前）。
    //   `mBus_aw hs 数 == mem_aw hs 数` ⇒ 丢在胶合块；`mBus` 侧压根没有 ⇒ 丢在 NaxSocMini 里
    //   （Hub 下游 A → Axi4Bridge，`a_ctxFull` 是那条路的拥塞指示）。
    //   !! 实测：`NaxSocMini.mBus_*` 这些**端口成员**在 verilator 的类里读出来恒 0
    //   （`VL_OUT8(__PVT__mBus_awvalid,0,0)` —— 端口被内联进父层后成了死成员，编译得过但值不动）。
    //   所以改看**桥内部**：`Axi4Bridge`(实例 `toAxi4_logic_bridge`) 被摊平进 NaxSocMini，
    //   `io_up_a_fire` = A 通道握手、`a_cmd_filtred_rData_address/opcode` = 正在处理的 A 命令
    //   ⇒ 能直接回答"A_PUT_FULL_DATA 有没有进桥、进桥后有没有变成 AW"。
    #define NXT(sig) dut->rootp->nax_mini_soc->u_soc->__PVT__toAxi4_logic_bridge__DOT__##sig
    auto& T_UP_A_FIRE = NXT(io_up_a_fire);
    auto& T_UP_A_BEAT = NXT(io_up_a_tracker_beat);
    auto& T_UP_A_LAST = NXT(io_up_a_tracker_last);
    auto& T_UP_D_FIRE = NXT(io_up_d_fire);
    auto& T_ACMD_V    = NXT(a_cmd_filtred_valid);
    auto& T_ACMD_V2   = NXT(a_cmd_filtred_rValid);
    auto& T_ACMD_A    = NXT(a_cmd_filtred_rData_address);
    auto& T_ACMD_OP   = NXT(a_cmd_filtred_rData_opcode);
    auto& T_ACMD_SRC  = NXT(a_cmd_filtred_rData_source);
    auto& T_ACMD_BUFF = NXT(a_cmd_buffered_fire);
    auto& T_FORK_FIRE = NXT(a_cmdFork_fire);
    auto& T_FORK_RDY  = NXT(a_cmdFork_ready);
    auto& T_ADATA_V   = NXT(a_dataFork_valid);
    auto& T_ADATA_R   = NXT(a_dataFork_ready);
    auto& T_HALT_RDY  = NXT(a_halted_ready);
    #undef NXT
    auto& T_CTXFULL   = dut->rootp->nax_mini_soc->u_soc->__PVT__toAxi4_logic_bridge__DOT__a_ctxFull;
    // 专门盯住那两笔"丢了 AW"的地址是否真的进过桥 / 出过桥
    const uint64_t WB_WATCH0 = 0x800270C0ull, WB_WATCH1 = 0x80025040ull;
    uint64_t c_m_aw = 0, c_m_w = 0, c_m_b = 0, c_m_ar = 0, c_ctxfull = 0;
    uint64_t last_m_aw = 0, last_m_aw_a = 0, last_m_b = 0, last_m_ctxfull = 0;
    uint64_t c_t_uaput = 0, last_t_uaput = 0, last_t_uaput_a = 0;
    uint64_t c_t_acmd_put = 0, last_t_acmd_put = 0, c_t_watch = 0;
    bool m_dbg_aw = false;
    // ---- ★ Task 23：[COREH] 冻结是"被 halt 住"还是"被重定向刷死"（TB_CORE_HALT=1）----
    //   ① FetchPlugin stage-0 的 8 路 haltRequest 全部逐位可读（见下），加和 ⇒ haltOr
    //      另给一条与 8 路无关的旁证：Pipeline 里 halt ⇒ stages_0_ready 被强拉 0
    //      （ready_output=1 而 ready=0 只可能是 halt）⇒ haltGene。
    //   ② PcPlugin 的 6 路 jump 来源 + 装进去的 target，用来判"重定向到自身"的来源。
    auto& N_S0_RDYOUT = NX2(FetchPlugin_stages_0_ready_output);
    auto& N_S0_RDYN   = NX2(FetchPlugin_stages_0_ready);
    // haltRequest 逐路（名字里 _l389/_l552/... 是该路在 NaxRiscv 源码里的行号）
    //   l389 与 l583 的中间信号被 verilator 内联掉了 ⇒ 按 NaxSocMini.v 的 assign 原文
    //   用等价的底层信号重算（下方 haltOr 的每一项都注释了对应 assign）。
    auto& N_H_FCDONE  = NX2(FetchCachePlugin_logic_invalidate_done);
    auto& N_H_FCREQ   = NX2(FetchCachePlugin_logic_invalidate_requested);
    auto& N_H_FC476   = NX2(FetchCachePlugin_logic_refill_valid);
    auto& N_H_FC552   = NX2(_zz_FetchPlugin_stages_0_haltRequest_FetchCachePlugin_l552);
    auto& N_H_MMUST   = NX2(MmuPlugin_logic_refill_stateReg);
    auto& N_H_LSU1548 = NX2(_zz_FetchPlugin_stages_0_haltRequest_Lsu2Plugin_l1548);
    auto& N_H_MMU512  = NX2(MmuPlugin_logic_invalidate_done);
    auto& N_H_MMUREQ  = NX2(MmuPlugin_logic_invalidate_requested);
    auto& N_H_PRIV986 = NX2(PrivilegedPlugin_logic_fsm_stateReg);
    auto& N_H_ENV140  = NX2(EnvCallPlugin_logic_flushes_stateReg);
    // PcPlugin 的 6 路 jump 来源（PcPlugin_logic_jump_oh 的一热源；verilator 只留了下面几条线）
    auto& N_J_BTB     = NX2(BtbPlugin_setup_btbJump_valid);
    auto& N_J_REDO    = NX2(FetchCachePlugin_setup_redoJump_valid);
    auto& N_J_NEEDC0  = NX2(FrontendPlugin_serialized_NEED_CORRECTION_0);
    auto& N_J_NEEDC1  = NX2(FrontendPlugin_serialized_NEED_CORRECTION_1);
    auto& N_J_ABVAL1  = NX2(_zz_FrontendPlugin_aligned_Prediction_ALIGNED_BRANCH_VALID_1);
    auto& N_J_ALCORR  = NX2(AlignerPlugin_logic_correctionSent);
    const bool TB_CORE_HALT = getenv("TB_CORE_HALT") != nullptr;
    const bool TB_CORE = getenv("TB_CORE") != nullptr;
    // ---- ★ Task 24 ③：BTB 学习口 / BTB 数组 / RAS 观测（TB_BTB=1；默认关 ⇒ 一行不打）------
    //   问题：冻结现场那条"自指 entry"（fetch pc=0x800000BA → pcTarget=0x800000BA）**是谁**教出来的？
    //   可读的口子（其余中间 wire 被 verilator 内联掉、header 里没有）：
    //     ① `BtbPlugin_logic_onLearn_port_valid` = `BranchContextPlugin_setup_learnValid`（学习脉冲）
    //     ② `BranchContextPlugin_logic_mem_finalBranch__DOT___zz_io_read_0_rsp`（81bit 读响应寄存器）
    //        = {taken[80], pcTarget[79:40], pcOnLastSlice[39:0]}，正是 learn 端口的载荷
    //        （rtl/NaxSocMini.v:54678-54681 逐字对应）⇒ 能说出"哪一个 pc 被训成了什么 tgt"
    //     ③ `BtbPlugin_logic_mem[512]`（59bit = {isBranch[58], pcTarget[57:18], slice[17:16],
    //        hash[15:0]}）：逐拍与快照比对 ⇒ "哪个 entry 何时被写成 0x800000BA"
    //     ④ `BtbPlugin_logic_mem_spinal_port1`：本拍 fetch 读出来的 entry（正在被"发射"的预测）
    //     ⑤ `DecoderPredictionPlugin_logic_ras_read`：RAS 栈顶（ret 的预测返回目标）
    auto& N_LN_V   = NX2(BtbPlugin_logic_onLearn_port_valid);
    auto& N_NB_RSP = NX2(BranchContextPlugin_logic_mem_finalBranch__DOT___zz_io_read_0_rsp);
    auto& N_BTB_MEM= NX2(BtbPlugin_logic_mem);
    auto& N_BTB_RD = NX2(BtbPlugin_logic_mem_spinal_port1);
    auto& N_RA_RD  = NX2(DecoderPredictionPlugin_logic_ras_read);
    const bool TB_BTB = getenv("TB_BTB") != nullptr;
    const uint64_t BTB_WATCH = getenv("TB_BTB_WATCH")
        ? strtoull(getenv("TB_BTB_WATCH"), nullptr, 0) : 0x800000BAull;
    const long TB_BTB_CAP = getenv("TB_BTB_CAP") ? strtol(getenv("TB_BTB_CAP"), nullptr, 0) : 20000;
    std::vector<uint64_t> btb_snap(512, 0);
    bool btb_armed = false, prev_ln_v = false;
    uint64_t prev_ln_pc = 0, prev_ln_tgt = 0;
    int prev_ln_tk = 0;
    uint64_t n_ln_all = 0, n_btb_wr = 0, n_btb_wr_watch = 0, n_self_btb = 0, first_self_btb = 0;
    uint64_t self_run = 0, self_run_first = 0, n_long_runs = 0;
    int prev_self_btb = 0, prev_fpc_watch = 0, prev_ras_watch = 0;
    #undef NX2
    // I$ 填充（refill）与命中：分辨"给到前端的那 64bit word 是 I$ 写错/读错，还是对齐器吃错了"
    auto& FC_RV    = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_refill_valid;
    auto& FC_RA    = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_refill_address;
    auto& FC_WIDX  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_refill_wordIndex;
    auto& FC_WAY   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_refill_wayToAllocate;
    auto& FC_WRA   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_banks_0_write_payload_address;
    auto& FC_RDV   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_banks_0_read_cmd_valid;
    auto& FC_HIT   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchPlugin_stages_2_FetchCachePlugin_logic_WAYS_HIT;
    auto& FC_H0    = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchPlugin_stages_2_FetchCachePlugin_logic_WAYS_HITS_0;
    auto& FC_H1    = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchPlugin_stages_2_FetchCachePlugin_logic_WAYS_HITS_1;
    auto& FC_S2PC  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchPlugin_stages_2_Fetch_FETCH_PC;
    auto& FC_S2W   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchPlugin_stages_2_Fetch_WORD;
    const char* TB_ALIGN_ENV = getenv("TB_ALIGN");
    const bool  TB_ALIGN = TB_ALIGN_ENV != nullptr;   // 任何非空值 = 打开逐拍 aligner 打印
    int prev_exv = 0;
    uint64_t n_ex = 0;
    struct PcSamp { uint64_t cyc; uint64_t fpc; uint64_t apc; int av; };
    std::vector<PcSamp> pc_ring;
    uint64_t prev_fpc = ~0ull, prev_apc = ~0ull;
    uint64_t n_thr_wr = 0, last_rd_cyc = 0, last_wr_cyc = 0;
    int prev_txdata = -1, prev_cawr_cwwr = 0, prev_rv = 0;
    uint8_t last_thr_byte = 0;

    // ---- ★ Step A：pBus 事务级探针（纯观测；顶层 dbg_pbus_* 端口组）-------------------
    // 目的：pBus（NaxSocMini↔NaxMiniGlue）在模块内部 ⇒ 顶层看不见任何一笔 MMIO 事务。
    //   这里逐笔打印 AW/W/B/AR/R 的握手（含 addr/data/strb/resp/拍数），并维护一个
    //   最近 96 笔事件的环形缓冲（收尾时整段打出 ⇒ 一定有"最后 5 笔"的原文）。
    //   另外有一个静默看门狗：pBus 连续 1000 拍无任何握手就打印一次**当前各通道电平快照**，
    //   用来判定"卡在哪个通道"（bvalid? rvalid? 还是 master 根本没发）。
    const char* PBUS_TRACE_ENV = getenv("TB_PBUS_TRACE");   // 任何非空值 = 每笔都实时打印
    const bool PBUS_TRACE = PBUS_TRACE_ENV != nullptr;
    uint64_t n_pbus_ev = 0, last_pbus_cyc = 0;
    struct PbusEv { uint64_t cyc; char txt[160]; };
    std::vector<PbusEv> pbus_ring;
    auto pbus_rec = [&](const char* fmt, ...) {
        PbusEv e{}; e.cyc = cyc;
        va_list ap; va_start(ap, fmt);
        vsnprintf(e.txt, sizeof(e.txt), fmt, ap);
        va_end(ap);
        n_pbus_ev++; last_pbus_cyc = cyc;
        if (PBUS_TRACE && n_pbus_ev <= 20000)
            printf("[PBUS] cyc=%llu %s\n", (unsigned long long)cyc, e.txt);
        pbus_ring.push_back(e);
        if (pbus_ring.size() > 96) pbus_ring.erase(pbus_ring.begin());
    };
    uint64_t n_pbus_stall_report = 0;
    bool prev_aw_hs = false, prev_w_hs = false, prev_b_hs = false;
    bool prev_ar_hs = false, prev_r_hs = false;

    // ---- ★ Task 23 补充：装置侧控制台（Uart16550）内部 + 全部 pBus 写事件 / LSR 取值变化 ----
    //   目的：A/B 两个变体都没冻在 ret 上，而是卡在"putc 轮询 LSR"。
    //   这一组读数回答：是**装置**不再给 THRE（txReady=0），还是核读到了错值。
    //   全部只在 TB_PEEK_CODE + 运行期 TB_CORE_HALT 下打印 ⇒ 默认行为不变。
    auto& C_LCR    = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__lcrReg;
    auto& C_DLL    = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__dllReg;
    auto& C_DLM    = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__dlmReg;
    auto& C_TXP    = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__txPend;
    auto& C_TXBUSY = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT___tx_io_busy;
    auto& C_RXCNT  = dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__console__DOT__rxCounter;
    int      last_lsr = -1;
    uint64_t n_lsr_chg = 0;

    // ---- ★ Step A 第二层：核侧 uncache 请求（core pBus a 通道）与 I$ 读出数据 ----------
    // 用途：分辨"核自己算出了垃圾地址" vs "fabric 把地址搞坏了"，以及"I$ 吐出的指令是否被污染"。
    auto& A_FIRE = dut->rootp->nax_mini_soc->u_soc->__PVT__naxes_0_pBus_bus_a_halfPipe_fire;
    auto& A_ADDR = dut->rootp->nax_mini_soc->u_soc->__PVT__naxes_0_pBus_bus_a_rData_address;
    auto& A_OP   = dut->rootp->nax_mini_soc->u_soc->__PVT__naxes_0_pBus_bus_a_rData_opcode;
    auto& I_RD   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core
                       ->__PVT__FetchCachePlugin_logic_ways_0_mem_rd_data;
    auto& I_WR   = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core
                       ->__PVT__FetchCachePlugin_logic_ways_0_mem_wr_data;
    // 核侧 uncache 请求流水（环形，收尾打印最后 40 笔）
    struct CoreReq { uint64_t cyc; uint64_t addr; uint32_t op; };
    std::vector<CoreReq> core_ring;
    uint64_t n_corereq = 0;
    // 逐拍窗口追踪（SOC_WIN_FROM / SOC_WIN_TO 都设置时生效）
    long win_from = getenv("SOC_WIN_FROM") ? strtol(getenv("SOC_WIN_FROM"), nullptr, 0) : -1;
    long win_to   = getenv("SOC_WIN_TO")   ? strtol(getenv("SOC_WIN_TO"),   nullptr, 0) : -1;

    // ================= ★ M2-b Gate 2 第五轮：**提交 PC / 取指 PC 直方图**（TB_PCHIST=1；默认关）=====
    // 目的（**有界取证**，不做根因）：把 cyc≈5.98M 停点那个窗口里"核到底在跑哪段代码"用
    //   **核自己提交的 PC** 说清楚 —— 尤其是"到底有没有进过内核（≥0x8200_0000）"。
    // 观测面（全部是 RTL 里**既有**的 `/* verilator public */` 导出；不改 RTL、不改任何驱动值）：
    //   · `commit_mask`   = `CommitPlugin_logic_commit_event_mask`：**本拍提交哪些槽**（2 bit，bit i = 第 i 槽）
    //   · `commit_pc_0/1` = `RobPlugin` 的 PC 存储按 `robId>>1` 读出的**同一行的两个槽**
    //                       （`commit_pc_0` = 列 0 / `commit_pc_1` = 列 1；与 mask 的 bit 一一对应）
    //   · `FrontendPlugin_serialized_PC_0`（+ `_valid`）：前端下一拍要取指的 PC 流（**独立**交叉校验）
    //   · `CommitPlugin_logic_ptr_commit/Next`：只用来数"这一拍提交了几条"（独立于 mask 的旁证）
    // 运行期开关：`TB_PCHIST` 非空 = 打开（**默认关 ⇒ 一行不打、一次累加都不做**）；
    //   `TB_PCHIST_FROM` / `TB_PCHIST_TO` 限定窗口（默认 5900000 .. 6200000）。
    const bool PC_HIST = getenv("TB_PCHIST") != nullptr;
    const long pc_from = getenv("TB_PCHIST_FROM") ? strtol(getenv("TB_PCHIST_FROM"), nullptr, 0) : 5900000L;
    const long pc_to   = getenv("TB_PCHIST_TO")   ? strtol(getenv("TB_PCHIST_TO"),   nullptr, 0) : 6200000L;
    const uint32_t KERNEL_BASE = 0x82000000u;
    auto& P_CM_MASK = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->commit_mask;
    auto& P_CM_ROB  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->commit_robId;
    auto& P_CM_PC0  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->commit_pc_0;
    auto& P_CM_PC1  = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->commit_pc_1;
    auto& N_ROB_COMMITN = NX(CommitPlugin_logic_ptr_commitNext);
    std::map<uint32_t, uint64_t> h_commit, h_fetch;
    std::vector<uint32_t> commit_seq;            // 窗口内提交 PC 序列（上界 200 万条）
    uint64_t n_commit_win = 0, n_fetch_win = 0;
    uint64_t cm_hist[4] = {0, 0, 0, 0};          // 窗口内 commit_mask 取值直方图（00/01/10/11）
    uint64_t n_commit_all = 0;                   // 全程提交条数（按 mask 计）
    uint64_t n_kern_commit = 0, first_kern_commit_cyc = 0;
    uint32_t first_kern_commit_pc = 0;
    uint64_t n_kern_fetch = 0, first_kern_fetch_cyc = 0;
    uint32_t first_kern_fetch_pc = 0;
    uint32_t max_commit_pc = 0, max_fetch_pc = 0;
    uint64_t first_commit_cyc = 0, last_commit_cyc = 0;
    uint32_t first_commit_pc = 0, last_commit_pc = 0;
    uint64_t n_rob_delta[3] = {0, 0, 0};         // 窗口内 ptr_commit 推进量 0/1/2 的拍数（旁证）
    uint64_t rob_delta_other = 0;
    uint32_t first_commit_rob = 0, last_commit_rob = 0;   // 提交头行的 robId（与 PC 一起看，便于对账）

    // ================= ★ M2-b Gate 2 第六轮（有界采集）：真 trap 现场 + 串口原始字节 ============
    // 两个**运行期开关，默认关**（判据装置更是不带 -DTB_PEEK_CODE ⇒ 一个字节都不多编）：
    //   `TB_TRAP=1`   在窗口 [TB_TRAP_FROM, TB_TRAP_TO]（默认 5900000..6200000）里抓每一"次" trap：
    //                 观测面 = 上面那五根**既有** `/* verilator public */` 级信号的明文路径
    //                 （`rescheduleUnbuffered_rValid` + `rData_{cause,epc,tval}`）——**真 mcause/mepc/mtval**，
    //                 不是 `PrivilegedPlugin_logic_exception_code`（它是随特权态 FSM 切语义的中间量）。
    //                 打：逐次明细（前 TB_TRAP_LINES 条，默认 200）+ cause 直方图 + 三元组去重 top。
    //   `TB_CONRAW=1` 记录**线上(UART TXD)解出的每一个字节**与**写进 THR 的每一个字节**（含不可打印），
    //                 收尾时按 hex + 文本 dump 最后 TB_CONRAW_KEEP 个（默认 512）。
    //                 ——用于判断 16550 既有的丢字发生在"写入侧"还是"线上/解码侧"。
    const bool TRAP_OBS = getenv("TB_TRAP") != nullptr;
    const long trap_from = getenv("TB_TRAP_FROM") ? strtol(getenv("TB_TRAP_FROM"), nullptr, 0) : 5900000L;
    const long trap_to   = getenv("TB_TRAP_TO")   ? strtol(getenv("TB_TRAP_TO"),   nullptr, 0) : 6200000L;
    const long trap_lines = getenv("TB_TRAP_LINES") ? strtol(getenv("TB_TRAP_LINES"), nullptr, 0) : 200;
    // T31 / spec 2026-10-01 sec.4: dcache snapshot sample cycle (0 = never)
    const long DCD_AT = getenv("TB_DCACHE_DUMP") ? strtol(getenv("TB_DCACHE_DUMP"), nullptr, 0) : 0;
    // T31 / spec: D$ residency time-series: TB_DCACHE_SWEEP=from,to,step（默认不设 = 一行不打）
    long SW_FROM = 0, SW_TO = -1, SW_STEP = 0; bool SWEEP_ON = false;
    if (getenv("TB_DCACHE_SWEEP")) {
        long a=0,b=0,c=0;
        if (sscanf(getenv("TB_DCACHE_SWEEP"), "%ld,%ld,%ld", &a, &b, &c) == 3 && c > 0) {
            SW_FROM=a; SW_TO=b; SW_STEP=c; SWEEP_ON=true;
        }
    }
    uint64_t n_trap_rvalid_rise = 0, n_trap_evt = 0, n_trap_win = 0;
    uint64_t h_trap_cause[16] = {0};
    uint64_t h_trap_tup[4][16] = {{0}};   // [tval!=0][cause]：看一眼 tval 是否带信息
    std::map<std::string, uint64_t> h_trap_triple;
    struct TrapEvt { uint64_t cyc; uint32_t cause; uint64_t epc, tval; };
    std::vector<TrapEvt> trap_evts;
    // 兜底（与窗口无关）：全程去重直方图 + 全程**最后 32 次**事件。
    //   目的：万一 [TRAP_FROM, TRAP_TO] 窗口里一次都没 fire，仍有"反复的 trap"的读数可用。
    std::map<std::string, uint64_t> h_trap_triple_all;
    uint64_t h_trap_cause_all[16] = {0};
    std::vector<TrapEvt> trap_last;
    uint64_t first_trap_cyc = 0;
    bool prev_exrvalid = false;
    uint32_t last_tr_c = 0; uint64_t last_tr_e = 0, last_tr_t = 0;
    uint32_t ex_tval_nonzero = 0;
    // 串口原始字节
    const bool CONRAW = getenv("TB_CONRAW") != nullptr;
    const size_t CONRAW_KEEP = getenv("TB_CONRAW_KEEP")
        ? (size_t)strtoul(getenv("TB_CONRAW_KEEP"), nullptr, 0) : (size_t)512;
    std::vector<uint8_t> raw_wire, raw_thr;
    uint64_t n_raw_wire = 0, n_raw_thr = 0;
    long last_uart_cyc = 0;
#endif  // TB_PEEK_CODE

    // ================= ★ Task 14：AXI 内存口逐拍电平观测（**运行期开关；默认关**）=================
    // 目的：给"静默停摆"定性 —— 回答三个问题：
    //   ① 卡住那一笔 AW 之后，W 通道是 **wvalid 从没抬起** 还是 **wready 恒低**（谁在等谁）；
    //   ② 卡住时 aw_q 里还压着几笔、队首 AW 的 (addr/len/size) 是什么；
    //   ③ 与 T13 的"只有 AW、0 个 W 拍"是否同一现象。
    // 纪律：判据装置**不带** SOC_AXI_WATCH ⇒ 一行也不打印（Step 3 的 diff 回归证明默认行为未变）；
    //   本段只读 DUT 端口电平，不驱动任何东西。
    const bool AXI_WATCH = getenv("SOC_AXI_WATCH") != nullptr;   // 任何非空值 = 打开
    // ★ T35：AXI4 从方**必须**用 `WLAST` 判 burst 结束。旧模型按 `awlen` 计数收尾，而本核的
    //   TL→AXI4 桥会在 **AW 握手的同一拍**就把 beat0 摆上 W 通道（`[AXCMD]/[AXDAT]` 同拍实测）
    //   ⇒ 旧模型整体错配一拍：64B 脏行写回的 8 个 W beat 落成 `[w1..w7,w0]`，页表 word0 被写到
    //   DRAM 的 +0x38 ⇒ 内核开分页后 IPF 自环。改按 wlast 收尾后 `wlast_mismatch` 157→1、
    //   `[MEMDIFF] 0x809FC000 = 0x201000CF` 归位、内核一路跑到 Linux banner。
    //   默认=开；`SOC_NO_WLAST_POP=1` 可回到旧（错的）行为做对照。
    const bool WLAST_POP = getenv("SOC_NO_WLAST_POP") == nullptr;
    // ★ T36：D$ refill 打点目标行地址（`TB_REF=<hex>`；0 = 关）
    const uint32_t TB_REF_TGT = getenv("TB_REF") ? (uint32_t)strtoul(getenv("TB_REF"), nullptr, 0) : 0u;
    // ★ T36：D$ load 流水线打点目标**页基址**（`TB_LDW=<hex>`；0 = 关）
    const uint32_t TB_LDW_TGT = getenv("TB_LDW") ? (uint32_t)strtoul(getenv("TB_LDW"), nullptr, 0) : 0u;
    // ★ T36：D$ 写口按数据值过滤（`TB_WTGT=<hex>`；0 = 关）
    const unsigned long long TB_WTGT_V = getenv("TB_WTGT") ? strtoull(getenv("TB_WTGT"), nullptr, 0) : 0ull;
    // ★ T36：D$ load 命中路 + 各路 tag 地址 的打点页（`TB_TAG=<hex>`；0 = 关）
    const uint32_t TB_TAG_TGT = getenv("TB_TAG") ? (uint32_t)strtoul(getenv("TB_TAG"), nullptr, 0) : 0u;
    long axi_win_from = getenv("SOC_AXI_WIN_FROM") ? strtol(getenv("SOC_AXI_WIN_FROM"), nullptr, 0) : -1;
    long axi_win_to   = getenv("SOC_AXI_WIN_TO")   ? strtol(getenv("SOC_AXI_WIN_TO"),   nullptr, 0) : -1;
    uint64_t last_w_hs_cyc = 0;          // 最近一次 W 握手（= W 通道推进）的拍
    uint64_t last_aw_hs_cyc = 0;         // 最近一次 AW 握手的拍
    uint64_t n_axi_stall_report = 0;
    bool prev_w_wvalid = false;          // wvalid 上升沿（"核侧到底有没有抬过 wvalid"）
    // ★ Gate 2 第三轮：`SOC_AW_GATE=1` 期间 "从方压住 awready 而核侧无 AW 可见" 的拍数（只计数）
    uint64_t n_aw_hold = 0;
    // ★ Gate 2 第三轮：胶合块 AW 门 `memRdBusy`（`rtl/NaxMiniGlue.v:3106` 的寄存）——
    //   只在 TB_PEEK_CODE 的取证装置里累加（判据装置不带该宏 ⇒ 保持 0，不进任何打印）。
    uint64_t c_rdbusy = 0, c_aw_suppressed = 0;
    uint32_t first_aw_suppressed = 0;

    for (cyc = 0; cyc <= MAX_CYC; cyc++) {
        if (cyc == 20) {
            dut->async_reset = 0;               // 释放（glue 侧由本模块内的复位同步器同步释放）
            printf("=== reset released at cyc=%llu ===\n", (unsigned long long)cyc);
        }

        // ★ Gate 2：从方的 W 通道停顿（`SOC_W_STALL=1`；默认关 ⇒ 这一行不改变任何驱动值）
        //   判据是**上一拍末**的 aw_q（本拍 AW 握手要等下一拍才被 W 看到，只多停 1 拍，语义不变）。
        if (W_STALL) {
            bool hold = aw_q.empty();
            dut->mem_w_wready = hold ? 0 : 1;
            if (hold && dut->mem_w_wvalid) {
                if (!n_w_stall_cyc) n_w_stall_first = cyc;
                n_w_stall_cyc++;
            }
        }

        // ===== clk=0 相位：组合稳定 → 观察主方、驱动从方、**采样串口线** =====
        dut->soc_clk = 0;
        dut->eval();

        // ★ Gate 2 第三轮：`SOC_AW_GATE=1` —— **同拍**把 awready 绑到胶合块真正吐出来的 awvalid 上。
        //   必须在 `eval()` 之后（`mem_aw_awvalid = ~memRdBusy & (op!=GET) & bufValid`，
        //   不依赖 awready ⇒ 先读它就拿到本拍终值），再 `eval()` 一次把 awready 灌回核的组合网
        //   （与下面 B 通道的"先摆 bvalid 再 eval 再采 bready"同一套纪律）。
        //   效果：胶合块吞掉 AW 的那一拍 `mem_aw_awvalid=0` ⇒ awready=0 ⇒ `Axi4Bridge` 的
        //   `a_cmdFork_fire` 不发生 ⇒ 这笔 A 命令留在 fork 里，等 `memRdBusy` 退掉后重发 ⇒ AW 不再丢。
        //   默认关 ⇒ `mem_aw_awready` 保持初值 1（从不重写）⇒ 与旧行为逐字节相同。
        if (AW_GATE) {
            bool seen = dut->mem_aw_awvalid != 0;
            dut->mem_aw_awready = seen ? 1 : 0;
            if (!seen && aw_q.empty()) n_aw_hold++;
            dut->eval();
        }

        // --- 串口线解码（**判据的唯一来源**）---
        {
            uint8_t byte = 0;
            const bool got = dec.step(dut->uart_txd, cyc, byte);
            // ★ T36：线上电平沿计数（不解码，只数沿）—— 见 n_txd_edges 的注释
            {
                const int _lv = dut->uart_txd ? 1 : 0;
                if (prev_txd_lvl >= 0 && _lv != prev_txd_lvl) { n_txd_edges++; last_txd_edge_cyc = cyc; }
                prev_txd_lvl = _lv;
            }
            // ★ T36：**长跑心跳**（`TB_HB=1`；默认关 ⇒ 判据装置一行不多）。
            //   为什么需要：控制台在 Linux 引导里会有很长的"不打印段"，只盯日志会误判成卡死
            //   （§19.2/19.3 的教训）。心跳每 2M 拍一行，能在**不看控制台**的情况下报"仿真到哪了"。
            if (getenv("TB_HB") && (cyc % 2000000ull) == 0) {
                printf("[HB] cyc=%llu frames=%d txd_edges=%llu last_edge_cyc=%llu\n",
                       (unsigned long long)cyc, dec.frames,
                       (unsigned long long)n_txd_edges, (unsigned long long)last_txd_edge_cyc);
                // UART internals only exist in the peek build (their declarations are inside
                // #ifdef TB_PEEK_CODE, which closes well above this block).
#ifdef TB_PEEK_CODE
                printf("[HB-UART] lcr=%02X dll=%02X dlm=%02X txPend=%d txBusy=%d rxCnt=%08X\n",
                       (unsigned)(uint32_t)C_LCR, (unsigned)(uint32_t)C_DLL, (unsigned)(uint32_t)C_DLM,
                       (int)C_TXP, (int)C_TXBUSY, (unsigned)(uint32_t)C_RXCNT);
#endif
            }
#ifdef TB_PEEK_CODE
            // ★ 第六轮：线上(UART TXD)解出的**原始字节**（含不可打印）——TB_CONRAW=1 时记录
            if (got && CONRAW) {
                n_raw_wire++;
                if (raw_wire.size() < 200000u) raw_wire.push_back(byte);
                last_uart_cyc = (long)cyc;
            }
#endif
            if (got && dec.frames != (int)n_frames_prev) {
                n_frames_prev = dec.frames;
                if (VERBOSE)
                    printf("[UART] cyc=%llu frame=%d byte=0x%02X '%c'\n",
                           (unsigned long long)cyc, dec.frames, byte,
                           (byte >= 0x20 && byte < 0x7F) ? (char)byte : '.');
            }
        }

        // --- AR 捕获 ---
        // ★ Task 17：**AR 接受纪律** —— ①`arready` 只在"本装置手上没有读突发（r_state==0）且队列空"
        //   时抬高 = **单笔在飞**，与 T13 已实证可用的 `sim/axi64to32.v` 同构（`u_arready = ~ar_live`）；
        //   ②握手拍就是 `arvalid && arready` 同拍，**不再靠上升沿**捕获。
        //   为什么：旧版 `arready` 恒 1 + 上升沿判定，在"主方把 arvalid 连着抬两拍递交两笔 AR"
        //   （AXI 允许：握手后一拍即可换 payload，主方内部是 StreamFifo 时 valid 不会掉）时会**漏拍**
        //   ⇒ 静默丢一笔 AR ⇒ 该笔的 R 永不来 ⇒ 挂死。门控 arready 后，"同一笔被记两次 / 两笔漏一笔"
        //   两种错都不可能发生（T13 的桥用同一形态跑了 64bit 核到 8 帧探针 + OpenSBI 取指）。
        {
            dut->mem_ar_arready = (r_state == 0 && ar_queue.empty()) ? 1 : 0;
            bool hs = dut->mem_ar_arvalid != 0 && dut->mem_ar_arready != 0;
            if (hs) {
                ArReq q{(uint32_t)dut->mem_ar_araddr, (int)dut->mem_ar_arlen + 1,
                        (uint32_t)dut->mem_ar_arid, (uint32_t)dut->mem_ar_arsize};
                ar_queue.push_back(q);
                n_ar++;
                if (VERBOSE && (TRACE_UNTIL == 0 || cyc <= TRACE_UNTIL) && log_le(n_ar))
                    printf("[AXI-AR] cyc=%llu addr=0x%08X beats=%d id=%u size=%u (%u B/beat) burst=%u depth=%zu\n",
                           (unsigned long long)cyc, q.addr, q.beats, q.id, q.size,
                           size_to_bytes(q.size), (uint32_t)dut->mem_ar_arburst, ar_queue.size());
            }
            (void)ar_hs_prev;   // 单笔在飞 + 直接按握手拍捕获 ⇒ 上升沿标志不再需要（保留变量仅为对照）
        }

        // --- 空闲时取出下一笔 AR（响应路由用入队时锁存的 id）---
        if (r_state == 0 && !ar_queue.empty()) {
            ArReq q = ar_queue.front();
            ar_queue.erase(ar_queue.begin());
            r_cur = q.addr; r_beats = q.beats; r_id = q.id; r_size = q.size;
            r_beats_total = q.beats; r_idx = 0;
            r_state = 1;
            r_last_sent = false;
            r_lat_remain = R_LATENCY;      // ★ Task 14：首拍前的额外空拍（默认 0 ⇒ 与旧版逐拍同义）
        }

        // --- R 通道状态机 ---
        if (r_state == 1) {
            if (r_lat_remain > 0) {        // 额外 R 延迟（SOC_R_LATENCY；默认 0 时这一支不进入）
                r_lat_remain--;
                dut->mem_r_rvalid = 0;
            } else {
                r_state = 2;
            }
        } else if (r_state == 2) {
            if (r_last_sent) {
                r_state = 0; r_last_sent = false;
                dut->mem_r_rvalid = 0;
            } else if (r_gap_remain > 0) { // beat 间空隙（SOC_R_BEAT_GAP；默认 0 时这一支不进入）
                r_gap_remain--;
                dut->mem_r_rvalid = 0;
            } else if (R_ZERO_LAT && !dut->mem_r_rready) {
                // ★ Task 14 诊断支（`SOC_R_ZERO_LAT=1`；默认关 ⇒ 不进入）：
                //   只在**核已经 ready 的拍**才把 beat 摆上总线 ⇒ rvalid 永远不会"提前摆在一个
                //   不 ready 的核面前"。⚠️ 这**不是** AXI 合规行为（从方不得等 rready 才抬 rvalid），
                //   纯粹是判别旋钮：用来判定核侧 I$ 填充是否对"rvalid 早于 rready"敏感。
                dut->mem_r_rvalid = 0;
            } else {
                uint32_t beat_bytes = size_to_bytes(r_size);
                dut->mem_r_rvalid = 1;
                // 位宽通用：beat 落在整字的哪个字节车道由 addr % BUS_BYTES 决定（beat_read 内部做）；
                // 赋值按**端口宽度**（= BUS_BYTES 字节）收敛 ⇒ 32bit 装置与旧版逐字节同义。
                dut->mem_r_rdata = addr_in_range(r_cur, beat_bytes)
                                   ? (bus_word_t)beat_read(r_cur, beat_bytes) : (bus_word_t)0;
                dut->mem_r_rid = r_id;
                dut->mem_r_rlast = (r_beats == 1);
                // ★★★ Task 17（V2 的关键修复）：**组合采样纪律** ★★★
                //   必须先把自己这一拍摆上的 `rvalid/rdata` 用 `eval()` 推进组合网，**再**采样
                //   `rready` 判握手。判据：本核 Axi4Bridge 的 `rready` 是**组合依赖 rvalid** 的
                //   （`io_down_r_ready = d_arbiter_io_inputs_1_ready`，而该 ready 只在 rvalid 已经
                //    抬起的那一拍才为 1）⇒ 若像旧版那样读"上一拍 eval 出来的 rready"（那时 rvalid
                //    还是 0），就会把"**已经握手**"误判成"停顿"，同一拍数据被 DUT 收两次：
                //      · 实测签名（T14/T17 V2）：每条 64B 取指行的 I$ 填充**整体旋转 +1**
                //        （refill_wordIndex 每条线多走一格：0,1,..,7,**0** → 下一条线从 1 开始）
                //        ⇒ 第 2 条行取出的字全错 ⇒ `mcause=2 @ epc=0x80000040`（T14 与 T17 同一签名）。
                //      · 32bit 装置为什么没暴露：那一代 rready 走 `WidthAdapter`+32bit Axi4Bridge 的
                //        **寄存器**路径（`ar_live && !ar_pend && !rd_out_valid && rd_left!=0`），与
                //        rvalid 无关 ⇒ 旧版的"上一拍采样"恰好是对的（所以 32bit 行为逐字节不变，
                //        见 Step「默认行为未变」的 diff 回归）。
                //      · 反证：T14 的 `SOC_R_ZERO_LAT=1`（只在核已 ready 时摆 beat）死锁
                //        ⇒ 核的 rready 确实要有 rvalid 才抬 ⇒ 这不是从方能靠"等 ready"绕开的。
                dut->eval();                       // ← 组合稳定：让 rvalid 传播到核的 rready
                if (VERBOSE && (TRACE_UNTIL == 0 || cyc <= TRACE_UNTIL) && log_lt(n_r_beats))
                    printf("[AXI-R] cyc=%llu beat=%d/%d addr=0x%08X data=0x" BUS_WORD_HEX " last=%u rdy=%u\n",
                           (unsigned long long)cyc, r_idx + 1, r_beats_total, r_cur,
                           (unsigned long long)(bus_word_t)dut->mem_r_rdata, (unsigned)dut->mem_r_rlast,
                           (unsigned)dut->mem_r_rready);
                if (dut->mem_r_rready) {
                    if (!addr_in_range(r_cur, beat_bytes)) n_drop_oob_r++;
                    n_r_beats++;
                    r_cur += beat_bytes;
                    r_beats--; r_idx++;
                    if (r_beats == 0) r_last_sent = true;
                    else r_gap_remain = R_BEAT_GAP;   // ★ Task 14：下一拍前的空隙（默认 0）
                } else {
                    n_r_stall++;
                }
            }
        } else {
            dut->mem_r_rvalid = 0; dut->mem_r_rlast = 0;
        }

        // --- AW 入队 ---
        if (dut->mem_aw_awvalid && dut->mem_aw_awready) {
            AwTxn t{(uint32_t)dut->mem_aw_awaddr, (int)dut->mem_aw_awlen, 0, (uint32_t)dut->mem_aw_awsize,
                    (uint32_t)dut->mem_aw_awid};
            aw_q.push_back(t);
            n_aw++;
            aw_hist[t.id & 0xF]++;                       // ★ Task 19：AW 侧 id 直方图
            if (VERBOSE && (TRACE_UNTIL == 0 || cyc <= TRACE_UNTIL) && log_le(n_aw))
                printf("[AXI-AW] cyc=%llu addr=0x%08X beats=%d id=%u size=%u burst=%u depth=%zu\n",
                       (unsigned long long)cyc, t.addr, t.len + 1, (uint32_t)dut->mem_aw_awid,
                       t.size, (uint32_t)dut->mem_aw_awburst, aw_q.size());
        }

        // --- W 通道 ---
        if (dut->mem_w_wvalid && dut->mem_w_wready) {
            uint64_t wdata = (uint64_t)dut->mem_w_wdata;
            uint32_t wstrb = (uint32_t)dut->mem_w_wstrb;
            wdata_dbg = wdata; wstrb_dbg = wstrb;
            wlast_dbg = (unsigned)(dut->mem_w_wlast != 0);
            n_w++;
            if (aw_q.empty()) {
                aw_orphan_w++;
                w_orphan_now = true;      // ★ 只在**本拍真的丢了**才打印（否则会每拍刷屏）
            } else {
                AwTxn& t = aw_q.front();
                uint32_t beat_bytes = size_to_bytes(t.size);
                uint32_t a = t.addr + beat_bytes * (uint32_t)t.beat;
                if (a % BUS_BYTES + beat_bytes > BUS_BYTES) w_addr_err++;
                if (addr_in_range(a, beat_bytes)) beat_write(a, wdata, wstrb);
                else n_drop_oob_w++;
                // ★ T35：把**页表页**（0x809F0000..0x80A00000）的每一笔写回 beat 都钉住
                if (getenv("TB_WWIN") && cyc >= (getenv("TB_WWIN_FROM")?strtoul(getenv("TB_WWIN_FROM"),nullptr,0):27201950ull)
                                     && cyc <= (getenv("TB_WWIN_TO")?strtoul(getenv("TB_WWIN_TO"),nullptr,0):27202250ull))
                    printf("[PTW] cyc=%llu AWaddr=0x%08X beatAddr=0x%08X data=0x%016llX strb=0x%X beat=%d/%d size=%u awid=%u wid=%u\n",
                           (unsigned long long)cyc, t.addr, a, (unsigned long long)wdata,
                           (unsigned)wstrb, t.beat, t.len, t.size, (unsigned)t.id,
                           (unsigned)dut->mem_w_wid);
                if (VERBOSE && (TRACE_UNTIL == 0 || cyc <= TRACE_UNTIL) && log_le(n_w))
                    printf("[AXI-W] cyc=%llu addr=0x%08X data=0x" BUS_WORD_HEX " strb=0x%X beat=%d/%d last=%u\n",
                           (unsigned long long)cyc, a, (unsigned long long)wdata, wstrb,
                           t.beat, t.len, (unsigned)dut->mem_w_wlast);
                if ((t.beat == t.len) != (dut->mem_w_wlast != 0)) n_wlast_mismatch++;
                t.beat++;
                // ★ T35：AXI4 里 **WLAST 才是 burst 结束的权威标记**；本核的桥实测在 **AW 握手的同一拍**
                //   就把 beat0 摆上 W 通道（[AXCMD]/[AXDAT] 同拍），若从方只按 awlen 计数会整体错配一拍。
                //   开关 `SOC_WLAST_POP=1` ⇒ 改用 wlast 收尾（默认关，判据装置行为不变）。
                if (t.beat > t.len || (WLAST_POP && dut->mem_w_wlast != 0)) {
                    b_id = t.id;                 // ★ Task 18：B 必须回带这笔 AW 的 id（否则会话错投）
                    aw_q.erase(aw_q.begin());
                    b_valid = true; b_acked = false;
                }
            }
        }
        // --- B 通道 ---
        // ★ Task 17：与 R 通道同一条**组合采样纪律** —— 先把 bvalid 摆上、`eval()` 推进组合网，
        //   再采样 `bready` 判握手（本核 Axi4Bridge 的 bready 同样是**组合依赖 bvalid** 的：
        //   `io_down_b_ready = d_arbiter_io_inputs_0_ready`，它与 R 在同一个 d_arbiter 的 mask 里
        //   同拍竞争）。旧版读的是"上一拍 eval 出来的 bready"⇒ 一次 B 握手会被记成两次
        //   （DUT 侧多收一个 B）。驱动位置**不变**（紧跟 W 通道之后）⇒ bvalid 的高电平宽度与旧版
        //   逐拍相同（`b_valid` 由 W 末拍置起、下拍被本段清掉）。
        // ★ Task 19：**默认**回带这笔 AW 的 id（`SOC_BID_ZERO=1` 才回到旧的缺陷行为）。
        dut->mem_b_bid = (BID_ZERO ? 0u : b_id);
        dut->mem_b_bvalid = b_valid ? 1 : 0;
        dut->eval();
        if (b_valid) {
            if (b_acked) { b_valid = false; b_acked = false; }
            else if (dut->mem_b_bready) {
                b_acked = true;
                n_b_hs++;
                b_hist[(uint32_t)dut->mem_b_bid & 0xF]++;   // ★ Task 19：只记**线上真正握手**的 B id
            }
        }
        if (w_orphan_now && aw_orphan_w <= 24)
            printf("[AXI-WARN] cyc=%llu W beat arrived with no pending AW (dropped) data=0x" BUS_WORD_HEX
                   " strb=0x%X last=%u (第 %d 拍)\n",
                   (unsigned long long)cyc, (unsigned long long)wdata_dbg, wstrb_dbg, wlast_dbg,
                   aw_orphan_w);
        w_orphan_now = false;

        // ---- ★ Task 14 观测：AW/W 逐拍电平 + 停摆看门狗（`SOC_AXI_WATCH` 未设 ⇒ 整段不执行）----
        if (AXI_WATCH) {
            bool aw_v = dut->mem_aw_awvalid != 0, aw_r = dut->mem_aw_awready != 0;
            bool w_v  = dut->mem_w_wvalid   != 0, w_r  = dut->mem_w_wready   != 0;
            bool b_v  = dut->mem_b_bvalid   != 0, b_r  = dut->mem_b_bready   != 0;
            if (aw_v && aw_r) last_aw_hs_cyc = cyc;
            if (w_v && w_r)   last_w_hs_cyc  = cyc;
            if (w_v && !prev_w_wvalid)      // 核侧"抬过 wvalid"的直接证据（配合 wready 恒 1）
                printf("[AXI-WLVL] cyc=%llu wvalid RISING (wready=%d wlast=%d) aw_q=%zu\n",
                       (unsigned long long)cyc, (int)w_r,
                       (int)(dut->mem_w_wlast != 0), aw_q.size());
            prev_w_wvalid = w_v;
#ifdef TB_PEEK_CODE
            // ★ Gate 2 第三轮：胶合块 AW 门 `memRdBusy` 的逐拍电平（只在取证装置里可读）
            {
                const int rd_busy = (int)dut->rootp->nax_mini_soc->__PVT__u_glue__DOT__memRdBusy;
                if (rd_busy) c_rdbusy++;
                if (rd_busy && !aw_v) {
                    if (!c_aw_suppressed) first_aw_suppressed = (uint32_t)cyc;
                    c_aw_suppressed++;
                }
                if (axi_win_from >= 0 && (long)cyc >= axi_win_from && (long)cyc <= axi_win_to)
                    printf("[GLUE] cyc=%llu memRdBusy=%d | mem_aw_awvalid=%d mem_aw_awready=%d | "
                           "mem_w_wvalid=%d mem_w_wready=%d | aw_q=%zu (核侧 AW 被吞时从方看不到 AW)\n",
                           (unsigned long long)cyc, rd_busy, aw_v, aw_r, w_v, w_r, aw_q.size());
            }
#endif
            if (axi_win_from >= 0 && (long)cyc >= axi_win_from && (long)cyc <= axi_win_to)
                printf("[AXI-LVL] cyc=%llu | AW v=%d r=%d | W v=%d r=%d last=%d | B v=%d r=%d | "
                       "AR v=%d r=%d | R v=%d r=%d last=%d | aw_q=%zu r_state=%d rid=%u cur=0x%08X | "
                       "last_aw_hs=%llu last_w_hs=%llu\n",
                       (unsigned long long)cyc, aw_v, aw_r, w_v, w_r,
                       (int)(dut->mem_w_wlast != 0), b_v, b_r,
                       (int)(dut->mem_ar_arvalid != 0), (int)(dut->mem_ar_arready != 0),
                       (int)(dut->mem_r_rvalid != 0), (int)(dut->mem_r_rready != 0),
                       (int)(dut->mem_r_rlast != 0), aw_q.size(), r_state, r_id, r_cur,
                       (unsigned long long)last_aw_hs_cyc, (unsigned long long)last_w_hs_cyc);
            // 停摆看门狗：aw_q 里还压着未收完的 AW，而 W 通道已 1000 拍没有推进
            if (!aw_q.empty() && cyc > last_w_hs_cyc && ((cyc - last_w_hs_cyc) % 1000) == 0) {
                n_axi_stall_report++;
                if (n_axi_stall_report <= 6 || (n_axi_stall_report % 200) == 0) {
                    const AwTxn& h = aw_q.front();
                    printf("[AXI-STALL] cyc=%llu 第 %llu 次：aw_q=%zu 笔未收完，W 通道已 %llu 拍无推进 | "
                           "AW v=%d r=%d | W v=%d r=%d | B v=%d r=%d | 队首 AW addr=0x%08X len=%d size=%u "
                           "beat=%d | last_aw_hs=%llu\n",
                           (unsigned long long)cyc, (unsigned long long)n_axi_stall_report,
                           aw_q.size(), (unsigned long long)(cyc - last_w_hs_cyc),
                           (int)(dut->mem_aw_awvalid != 0), (int)(dut->mem_aw_awready != 0),
                           (int)(dut->mem_w_wvalid != 0), (int)(dut->mem_w_wready != 0),
                           (int)(dut->mem_b_bvalid != 0), (int)(dut->mem_b_bready != 0),
                           h.addr, h.len + 1, h.size, h.beat,
                           (unsigned long long)last_aw_hs_cyc);
                }
            }
        }

        if (dut->tracer_valid) n_tracer++;

#ifdef TB_PEEK_CODE
        // ================= ★ Step A：pBus 事务级探针 =================
        {
            bool aw_v = dut->dbg_pbus_awvalid, aw_r = dut->dbg_pbus_awready;
            bool w_v  = dut->dbg_pbus_wvalid,  w_r  = dut->dbg_pbus_wready;
            bool b_v  = dut->dbg_pbus_bvalid,  b_r  = dut->dbg_pbus_bready;
            bool ar_v = dut->dbg_pbus_arvalid, ar_r = dut->dbg_pbus_arready;
            bool r_v  = dut->dbg_pbus_rvalid,  r_r  = dut->dbg_pbus_rready;
            // 握手 = valid&ready 同拍（AXI 语义）；用沿检测避免同一笔重复打印
            bool aw_hs = aw_v && aw_r, w_hs = w_v && w_r, b_hs = b_v && b_r;
            bool ar_hs = ar_v && ar_r, r_hs = r_v && r_r;
            if (aw_hs && !prev_aw_hs)
                pbus_rec("AW  addr=0x%08X prot=%u", (uint32_t)dut->dbg_pbus_awaddr,
                         (uint32_t)dut->dbg_pbus_awprot);
            if (w_hs && !prev_w_hs)
                pbus_rec("W   data=0x%08X strb=0x%X", (uint32_t)dut->dbg_pbus_wdata,
                         (uint32_t)dut->dbg_pbus_wstrb);
            if (b_hs && !prev_b_hs)
                pbus_rec("B   resp=%u", (uint32_t)dut->dbg_pbus_bresp);
            if (ar_hs && !prev_ar_hs)
                pbus_rec("AR  addr=0x%08X prot=%u", (uint32_t)dut->dbg_pbus_araddr,
                         (uint32_t)dut->dbg_pbus_arprot);
            if (r_hs && !prev_r_hs)
                pbus_rec("R   data=0x%08X resp=%u", (uint32_t)dut->dbg_pbus_rdata,
                         (uint32_t)dut->dbg_pbus_rresp);
            // ★ Task 23 补充：**每一笔写**都打（写很少，约 60 笔/次），不受窗口限制
            if (TB_CORE_HALT && aw_hs && !prev_aw_hs)
                printf("[CONSW] %llu AW addr=%08X prot=%u\n", (unsigned long long)cyc,
                       (uint32_t)dut->dbg_pbus_awaddr, (uint32_t)dut->dbg_pbus_awprot);
            if (TB_CORE_HALT && w_hs && !prev_w_hs)
                printf("[CONSW] %llu W  data=%08X strb=%X\n", (unsigned long long)cyc,
                       (uint32_t)dut->dbg_pbus_wdata, (uint32_t)dut->dbg_pbus_wstrb);
            // ★ Task 23 补充：LSR(0xF0001014) 读回值**每次变化**都打（THRE/TEMT 何时掉、会不会回来）
            if (TB_CORE_HALT && r_hs && !prev_r_hs
                && ((uint32_t)dut->dbg_pbus_araddr & 0xFFFFFFFCu) == 0xF0001014u) {
                int v = (int)((uint32_t)dut->dbg_pbus_rdata & 0xFF);
                if (v != last_lsr) {
                    last_lsr = v;
                    if (n_lsr_chg < 4000)
                        printf("[CONSL] %llu LSR=%02X (THRE=%d TEMT=%d DR=%d) | ctl lcr=%02X dll=%02X dlm=%02X"
                               " txPend=%d txBusy=%d rxCnt=%08X\n",
                               (unsigned long long)cyc, v, (v >> 5) & 1, (v >> 6) & 1, v & 1,
                               (unsigned)(uint32_t)C_LCR, (unsigned)(uint32_t)C_DLL,
                               (unsigned)(uint32_t)C_DLM, (int)C_TXP, (int)C_TXBUSY,
                               (unsigned)(uint32_t)C_RXCNT);
                    n_lsr_chg++;
                }
            }
            prev_aw_hs = aw_hs; prev_w_hs = w_hs; prev_b_hs = b_hs;
            prev_ar_hs = ar_hs; prev_r_hs = r_hs;

            // 静默看门狗：连续 1000 拍无握手 ⇒ 打一次"各通道电平快照"（判"卡在哪根通道"）
            if (n_pbus_ev > 0 && (cyc - last_pbus_cyc) == 1000) {
                n_pbus_stall_report++;
                if (n_pbus_stall_report <= 6 || (n_pbus_stall_report % 200) == 0)
                    printf("[PBUS-STALL] cyc=%llu 静默 1000 拍（第 %llu 次）："
                           "AW v=%d r=%d | W v=%d r=%d | B v=%d r=%d | "
                           "AR v=%d r=%d | R v=%d r=%d || 最后一次事务 cyc=%llu\n",
                           (unsigned long long)cyc, (unsigned long long)n_pbus_stall_report,
                           aw_v, aw_r, w_v, w_r, b_v, b_r, ar_v, ar_r, r_v, r_r,
                           (unsigned long long)last_pbus_cyc);
            }

            // 核侧 uncache 请求（core pBus a 通道）
            if (A_FIRE) {
                CoreReq r{cyc, (uint64_t)A_ADDR, (uint32_t)A_OP};
                core_ring.push_back(r);
                if (core_ring.size() > 40) core_ring.erase(core_ring.begin());
                n_corereq++;
                if (PBUS_TRACE && n_corereq <= 20000)
                    printf("[CORE-PBUS-A] cyc=%llu op=0x%X addr=0x%08llX\n",
                           (unsigned long long)cyc, (unsigned)A_OP,
                           (unsigned long long)A_ADDR & 0xFFFFFFFFull);
            }

            // 逐拍窗口追踪
            if (win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
                printf("[CYC] %llu fPC=%08llX apc=%08llX av=%d | coreA fire=%d addr=%08llX | "
                       "pbus arv=%d ar=%08X rv=%d rd=%08X | i$_rd=%X i$_wr=%X | rSel=%u wSel=%u | exc=%d epc=%08llX\n",
                       (unsigned long long)cyc,
                       (unsigned long long)F_PC & 0xFFFFFFFFull,
                       (unsigned long long)A_PC & 0xFFFFFFFFull, (int)A_V,
                       (int)A_FIRE, (unsigned long long)A_ADDR & 0xFFFFFFFFull,
                       (int)ar_v, (uint32_t)dut->dbg_pbus_araddr, (int)r_v,
                       (uint32_t)dut->dbg_pbus_rdata,
                       (unsigned)(uint32_t)I_RD, (unsigned)(uint32_t)I_WR,
                       (unsigned)G_RSEL, (unsigned)G_WSEL,
                       (int)EX_V, (unsigned long long)EX_EPC & 0xFFFFFFFFull);
        }
#endif  // TB_PEEK_CODE

#ifdef TB_PEEK_CODE
        // ★ Task 18：核内部"谁占着不放"逐拍打印（TB_CORE=1；窗口 SOC_WIN_FROM/TO）
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
            printf("[CORE] %llu | FR v=%d pc=%08llX inc=%08llX tgt=%08llX flu=%d s0rdy=%d"
                   " || FE dis(v=%d,rdy=%d) alg=%d alc=%d dec=%d(flr=%d)"
                   " || ROB empty=%d alloc=%02X commit=%02X free=%02X canFree=%d mask=%02X head=%u line=%d"
                   " || RS(v=%d cause=%02X robId=%02X trap=%d skip=%d reason=%02X tgt=%08llX)"
                   " || LSU sq(a=%02X c=%02X f=%02X wb=%02X) s1(v=%d LQF=%d SQF=%d) fl(b=%d d=%d cache=%d dcfl=%d)"
                   " fen(d=%d tr=%d lw=%d sw=%d)"
                   " || MMU(ws=%d st=%d->%d virt=%d inv(r=%d,d=%d) satp=%d)"
                   " || WFI f1=%d e1=%d e2=%d privFSM=%d rsUnb(c=%02X epc=%08llX)"
                   " || SQ0(v=%d c=%d dv=%d mr=%d) SQ1(v=%d c=%d dv=%d) SQ2(v=%d dv=%d) SQ3(v=%d dv=%d)\n",
                   (unsigned long long)cyc,
                   (int)N_FR_V, (unsigned long long)N_FR_PC & 0xFFFFFFFFull,
                   (unsigned long long)N_FR_INC & 0xFFFFFFFFull,
                   (unsigned long long)N_FR_TGT & 0xFFFFFFFFull,
                   (int)N_FR_FLU, (int)N_S0_RDY,
                   (int)N_DIS_V, (int)N_DIS_RDY, (int)N_ALG_RDY, (int)N_ALC_RDY,
                   (int)N_DEC_RDY, (int)N_DEC_FLR,
                   (int)N_ROB_EMPTY, (unsigned)(uint32_t)N_ROB_ALLOC, (unsigned)(uint32_t)N_ROB_COMMIT,
                   (unsigned)(uint32_t)N_ROB_FREE, (int)N_ROB_CANFR,
                   (unsigned)(uint32_t)N_CM_MASK, (unsigned)(uint32_t)N_CM_HEAD, (int)N_CM_LINE,
                   (int)N_RS_V, (unsigned)(uint32_t)N_RS_CAUSE, (unsigned)(uint32_t)N_RS_ROBID,
                   (int)N_RS_TRAP, (int)N_RS_SKIP, (unsigned)(uint32_t)N_RS_REASON,
                   (unsigned long long)N_RS_TGT & 0xFFFFFFFFull,
                   (unsigned)(uint32_t)N_SQ_ALLOC, (unsigned)(uint32_t)N_SQ_COMMIT,
                   (unsigned)(uint32_t)N_SQ_FREE, (unsigned)(uint32_t)N_SQ_WBACK,
                   (int)N_S1_V, (int)N_S1_LQF, (int)N_S1_SQF,
                   (int)N_LSU_FLB, (int)N_LSU_FLD, (int)N_LSU_CACHE, (int)N_DC_FLSH,
                   (int)N_FEN_DONE, (int)N_FEN_TRIG, (int)N_FEN_LW, (int)N_FEN_SW,
                   (int)N_MMU_WS, (unsigned)(uint32_t)N_MMU_ST, (unsigned)(uint32_t)N_MMU_STN,
                   (int)N_MMU_VIRT, (int)N_MMU_INVR, (int)N_MMU_INVD, (int)N_MMU_SATP,
                   (int)N_WFI_F1, (int)N_WFI_E1, (int)N_WFI_E2, (unsigned)(uint32_t)N_PRIV_FSM,
                   (unsigned)(uint32_t)N_RS_UNB_C,
                   (unsigned long long)N_RS_UNB_E & 0xFFFFFFFFull,
                   (int)N_SQ0_V, (int)N_SQ0_C, (int)N_SQ0_DV, (int)N_SQ0_MR,
                   (int)N_SQ1_V, (int)N_SQ1_C, (int)N_SQ1_DV,
                   (int)N_SQ2_V, (int)N_SQ2_DV,
                   (int)N_SQ3_V, (int)N_SQ3_DV);
        // ★ T35：D$ 的 **bank 写命令**逐笔（地址/掩码/数据）—— 查"这笔 store 落到该行的哪一格"
        //   位置：DataCache 的 4 个数据 bank 写口（`banks_N_write_payload_*`），只在窗口内、只在 valid 时打。
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to) {
            auto* _dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            const unsigned _wv[4] = {
                (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_valid,
                (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_valid,
                (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_valid,
                (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_valid };
            for (int b = 0; b < 4; b++) {
                if (!_wv[b]) continue;
                unsigned addr = 0, mask = 0;
                unsigned long long data = 0;
                if (b == 0) { addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_payload_mask;
                              data = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_payload_data; }
                else if (b == 1) { addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_payload_mask;
                              data = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_payload_data; }
                else if (b == 2) { addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_payload_mask;
                              data = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_payload_data; }
                else { addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_payload_mask;
                              data = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_payload_data; }
                printf("[DCW] %llu bank=%d addr=%03X mask=%02X data=%016llX\n",
                       (unsigned long long)cyc, b, addr, mask, data);
            }
        }
        // ★ T35：MMU 走表（walk）逐拍 —— satp 装好后取指仍 cause=12，看**走表拿到了什么 PTE**
        //   底座事实：MmuPlugin_setup_cacheLoad_rsp_valid = D$ 的 io_load_rsp_valid && load_ohHistory_2[0]
        //   ⇒ 走表是**穿 D$ 的 load 通路**（rtl:38300）。
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to) {
            auto* _c = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            printf("[WALK] %llu satp(m=%X ppn=%010llX) inv(r=%d d=%d)"
                   " | refill(ws=%d st=%u->%u virt=%09llX pa=%08X load=%08X)"
                   " rsp(v=%d data=%016llX fault=%d redo=%d leaf=%d exc=%d)\n",
                   (unsigned long long)cyc,
                   (unsigned)(uint32_t)_c->__PVT__MmuPlugin_logic_satp_mode,
                   (unsigned long long)_c->__PVT__MmuPlugin_logic_satp_ppn,
                   (int)_c->__PVT__MmuPlugin_logic_invalidate_requested,
                   (int)_c->__PVT__MmuPlugin_logic_invalidate_done,
                   (int)_c->__PVT__MmuPlugin_logic_refill_wantStart,
                   (unsigned)(uint32_t)_c->__PVT__MmuPlugin_logic_refill_stateReg,
                   (unsigned)(uint32_t)_c->__PVT__MmuPlugin_logic_refill_stateNext,
                   (unsigned long long)_c->__PVT__MmuPlugin_logic_refill_virtual & 0xFFFFFFFFFFull,
                   (unsigned)(uint32_t)_c->__PVT__MmuPlugin_logic_refill_portsAddress,
                   (unsigned)(uint32_t)_c->__PVT__MmuPlugin_logic_refill_load_address,
                   (int)_c->__PVT__MmuPlugin_logic_refill_load_rsp_valid,
                   (unsigned long long)_c->__PVT__MmuPlugin_logic_refill_load_rsp_payload_data,
                   (int)_c->__PVT__MmuPlugin_logic_refill_load_rsp_payload_fault,
                   (int)_c->__PVT__MmuPlugin_logic_refill_load_rsp_payload_redo,
                   (int)_c->__PVT__MmuPlugin_logic_refill_load_leaf,
                   (int)_c->__PVT__MmuPlugin_logic_refill_load_exception);
        }
        // ★ T35：在指定拍扫描 D$ 全部 (bank,set,word) 找某个 64bit 值（默认 0x201000CF = 那句 PMD PTE）
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to) {
            static const char* _fv = getenv("TB_FINDV");
            if (_fv) {
                static std::string _lastsig;
                unsigned long long target = strtoull(_fv, nullptr, 0);
                auto* _dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
                std::string sig; char _b[512];
                for (int b = 0; b < 4; b++)
                    for (int set = 0; set < 64; set++) {
                        unsigned long long ln[8]; int wi = -1;
                        for (int i = 0; i < 8; i++) {
                            unsigned idx = (unsigned)(set * 8 + i);
                            unsigned long long v;
                            if (b == 0)      v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_mem__DOT__ram_block[idx];
                            else if (b == 1) v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_mem__DOT__ram_block[idx];
                            else if (b == 2) v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_mem__DOT__ram_block[idx];
                            else             v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_mem__DOT__ram_block[idx];
                            ln[i] = v; if (v == target) wi = i;
                        }
                        if (wi < 0) continue;
                        snprintf(_b, sizeof(_b), "b%d/s%02d/w%d", b, set, wi);
                        sig += _b;
                    }
                if (sig != _lastsig) {
                    _lastsig = sig;
                    printf("[FIND] cyc=%llu hits=%s\n", (unsigned long long)cyc, sig.c_str());
                    for (int b = 0; b < 4; b++)
                        for (int set = 0; set < 64; set++) {
                            unsigned long long ln[8]; int wi = -1;
                            for (int i = 0; i < 8; i++) {
                                unsigned idx = (unsigned)(set * 8 + i);
                                unsigned long long v;
                                if (b == 0)      v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_mem__DOT__ram_block[idx];
                                else if (b == 1) v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_mem__DOT__ram_block[idx];
                                else if (b == 2) v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_mem__DOT__ram_block[idx];
                                else             v = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_mem__DOT__ram_block[idx];
                                ln[i] = v; if (v == target) wi = i;
                            }
                            if (wi < 0) continue;
                            printf("[FINDL] b=%d set=%02d line=", b, set);
                            for (int i = 0; i < 8; i++) printf(" %016llx", ln[i]);
                            printf("\n");
                        }
                }
            }
        }
        // ★ T35：hub 的 backend 逐笔（C 通道进 hub 的 data/addr/last）—— 与 AXI W beat 对账，
        //   定位"左旋一个字"是在 **D$→hub 之内** 还是 **hub→TLToAXI4→A** 之后
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to) {
            #define NXH2(sig) dut->rootp->nax_mini_soc->u_soc->__PVT__noL2_hub_logic_hub__DOT__##sig
            if (NXH2(backend_stages_0_valid))
                printf("[HUB0] %llu addr=%08X last=%d fromC=%d slot=%u wdata=%016llX fire=%d\n",
                       (unsigned long long)cyc,
                       (unsigned)(uint32_t)NXH2(backend_stages_0_ADDRESS),
                       (int)NXH2(backend_stages_0_LAST),
                       (int)NXH2(backend_stages_0_FROM_C),
                       (unsigned)(uint32_t)NXH2(backend_stages_0_SLOT_ID),
                       (unsigned long long)NXH2(backend_stages_0_WRITE_DATA),
                       (int)NXH2(backend_stages_0_isFireing));
            if (NXH2(backend_stages_1_valid))
                printf("[HUBC] %llu C_data=%016llX C_mask=%02X addr=%08X size=%u slot=%u writeData=%016llX\n",
                       (unsigned long long)cyc,
                       (unsigned long long)NXH2(backend_stages_1_PAYLOAD_C_data),
                       (unsigned)(uint32_t)NXH2(backend_stages_1_PAYLOAD_C_mask),
                       (unsigned)(uint32_t)NXH2(backend_stages_1_ADDRESS),
                       (unsigned)(uint32_t)NXH2(backend_stages_1_SIZE),
                       (unsigned)(uint32_t)NXH2(backend_stages_1_SLOT_ID),
                       (unsigned long long)NXH2(backend_stages_1_WRITE_DATA));
            if (NXH2(backend_stages_2_valid))
                printf("[HUBA] %llu PAY_data=%016llX mask=%02X addr=%08X size=%u slot=%u toDown=%d writeData=%016llX\n",
                       (unsigned long long)cyc,
                       (unsigned long long)NXH2(backend_stages_2_PAYLOAD_data),
                       (unsigned)(uint32_t)NXH2(backend_stages_2_PAYLOAD_mask),
                       (unsigned)(uint32_t)NXH2(backend_stages_2_ADDRESS),
                       (unsigned)(uint32_t)NXH2(backend_stages_2_SIZE),
                       (unsigned)(uint32_t)NXH2(backend_stages_2_SLOT_ID),
                       (int)NXH2(backend_stages_2_TO_DOWN),
                       (unsigned long long)NXH2(backend_stages_2_WRITE_DATA));
            #undef NXH2
        }
        // ★ T35：TL→AXI4 桥（`toAxi4_logic_bridge`）的 A 通道 —— 左旋到底发生在桥的哪一侧
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to) {
            #define NXAX(sig) dut->rootp->nax_mini_soc->u_soc->__PVT__toAxi4_logic_bridge__DOT__##sig
            if (NXAX(a_cmd_buffered_fire))
                printf("[AXCMD] %llu addr=%08X size=%u opcode=%u\n",
                       (unsigned long long)cyc,
                       (unsigned)(uint32_t)NXAX(a_cmd_filtred_rData_address),
                       (unsigned)(uint32_t)NXAX(a_cmd_filtred_rData_size),
                       (unsigned)(uint32_t)NXAX(a_cmd_filtred_rData_opcode));
            if (NXAX(a_data_filtred_valid) && NXAX(a_data_filtred_ready))
                printf("[AXDAT] %llu data=%016llX mask=%02X beat=%u\n",
                       (unsigned long long)cyc,
                       (unsigned long long)NXAX(a_data_filtred_rData_data),
                       (unsigned)(uint32_t)NXAX(a_data_filtred_rData_mask),
                       (unsigned)(uint32_t)NXAX(a_data_buffer_tracker_beat));
            #undef NXAX
        }
        // ★ T36：D$ 对**指定行**的 refill 读打点（`TB_REF=<hex 行地址>`；不依赖窗口）
        if (TB_REF_TGT != 0) {
            auto* _dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            unsigned _ra = (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT___zz_refill_read_cmdAddress;
            if ((_ra & 0xFFFFFFC0u) == TB_REF_TGT)
                printf("[REF] %llu cmd=%08X rsp=%08X widx=%u way=%u\n",
                       (unsigned long long)cyc, _ra,
                       (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT___zz_refill_read_rspAddress,
                       (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT__refill_read_wordIndex,
                       (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT___zz_refill_read_way);
        }
        // ★ T36：D$ **load 流水线**打点（`TB_LDW=<hex 页基址>` 或 `TB_LDWALL=1`+窗口）
        {
            auto* _dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            unsigned _a2 = (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_2_ADDRESS_POST_TRANSLATION;
            unsigned _a1 = (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_1_ADDRESS_PRE_TRANSLATION;
            const bool _pg = (TB_LDW_TGT != 0) && (((_a2 & 0xFFFFF000u) == TB_LDW_TGT) || ((_a1 & 0xFFFFF000u) == TB_LDW_TGT));
            const bool _all = (TB_LDW_TGT == 0) && TB_CORE && win_from >= 0 &&
                              (long)cyc >= win_from && (long)cyc <= win_to;
            if (_pg || _all)
                printf("[LD] %llu pre=%08X post=%08X miss=%d ab=%d v1=%d v2=%d waysH=%04X bankBusy=%d plru=%X\n",
                       (unsigned long long)cyc, _a1, _a2,
                       (int)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_2_MISS,
                       (int)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_2_ABORD,
                       (int)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_1_valid,
                       (int)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_2_valid,
                       (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_1_WAYS_HAZARD,
                       (int)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_0_BANK_BUSY,
                       (unsigned)(uint32_t)_dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_2_PLRU_0);
        }
        // ★ T36：D$ **写口**按数据值过滤（`TB_WTGT=<hex 64bit>`）—— 整跑抓"某一笔 store 有没有落到 D$"
        if (TB_WTGT_V != 0) {
            auto* _dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            for (int b = 0; b < 4; b++) {
                unsigned v = 0, addr = 0, mask = 0; unsigned long long d = 0;
                if (b == 0) { v = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_valid;
                              addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_payload_mask;
                              d = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_write_payload_data; }
                else if (b == 1) { v = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_valid;
                              addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_payload_mask;
                              d = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_write_payload_data; }
                else if (b == 2) { v = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_valid;
                              addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_payload_mask;
                              d = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_write_payload_data; }
                else { v = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_valid;
                              addr = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_payload_address;
                              mask = (unsigned)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_payload_mask;
                              d = (unsigned long long)_dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_write_payload_data; }
                if (v && d == TB_WTGT_V)
                    printf("[WTGT] %llu bank=%d set=%u word=%u mask=%02X data=%016llX\n",
                           (unsigned long long)cyc, b, addr >> 3, addr & 7, mask, d);
            }
        }
        // ★ T36：D$ load 命中**路与各路的 tag 地址**（`TB_TAG=<hex 页基址>`）——
        //   直接判"答这一拍的是不是那条地址"（假命中）还是"数据本身是错的"
        if (TB_TAG_TGT != 0) {
            auto* _dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            #define NXT(s) _dc->__PVT__DataCachePlugin_logic_cache__DOT__load_pipeline_stages_2_##s
            unsigned _p2 = (unsigned)(uint32_t)NXT(ADDRESS_POST_TRANSLATION);
            if (NXT(valid) && ((_p2 & 0xFFFFF000u) == TB_TAG_TGT))
                printf("[TAG] %llu post=%08X hits=%X miss=%d redo=%d rfH=%X"
                       " | w0=%08X/%d/%d w1=%08X/%d/%d w2=%08X/%d/%d w3=%08X/%d/%d\n",
                       (unsigned long long)cyc, _p2,
                       (unsigned)(uint32_t)NXT(WAYS_HITS), (int)NXT(MISS), (int)NXT(REDO),
                       (unsigned)(uint32_t)NXT(REFILL_HITS),
                       (unsigned)(uint32_t)NXT(WAYS_TAGS_0_address), (int)NXT(WAYS_TAGS_0_loaded), (int)NXT(WAYS_TAGS_0_fault),
                       (unsigned)(uint32_t)NXT(WAYS_TAGS_1_address), (int)NXT(WAYS_TAGS_1_loaded), (int)NXT(WAYS_TAGS_1_fault),
                       (unsigned)(uint32_t)NXT(WAYS_TAGS_2_address), (int)NXT(WAYS_TAGS_2_loaded), (int)NXT(WAYS_TAGS_2_fault),
                       (unsigned)(uint32_t)NXT(WAYS_TAGS_3_address), (int)NXT(WAYS_TAGS_3_loaded), (int)NXT(WAYS_TAGS_3_fault));
            #undef NXT
        }
        // ★ Task 18 第二轮：[COREF] = 真取指 PC / 重定向 / fence.i 通路 / I$ 失效
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
            printf("[COREF] %llu fpc=%08llX fire=%d jump(v=%d tgt=%08llX) corr=%d s1pc=%08llX"
                   " || PRjmp(v=%d pc=%08llX) readed=%016llX"
                   " || EC v=%d cause=%X reason=%02X FSM=%u->%u"
                   " [fencei=%d fencevma=%d flushd=%d ecall=%d xret=%d ebrk=%d]"
                   " || hits=%02X fresh=%d"
                   " || I$ inv(r=%d d=%d cnt=%d) ivport(c=%d rsp=%d) refill(start=%d v=%d cmdSent=%d)"
                   " redo=%d redoJmp=%d || LSUflushPort=%d\n",
                   (unsigned long long)cyc,
                   (unsigned long long)N_FETCHPC & 0xFFFFFFFFull, (int)N_FETCHFIR,
                   (int)N_JUMPV, (unsigned long long)N_JUMPTGT & 0xFFFFFFFFull,
                   (int)N_FETCHCORR,
                   (unsigned long long)N_S1PC & 0xFFFFFFFFull,
                   (int)N_PR_JMPV, (unsigned long long)N_PR_JMPPC & 0xFFFFFFFFull,
                   (unsigned long long)(uint64_t)N_PR_READED,
                   (int)N_EC_V, (unsigned)(uint32_t)N_EC_CAUSE, (unsigned)(uint32_t)N_EC_REASON,
                   (unsigned)(uint32_t)N_EC_FSM, (unsigned)(uint32_t)N_EC_FSMN,
                   (int)N_EC_FENCEI, (int)N_EC_FENCEV, (int)N_EC_FLUSHD,
                   (int)N_EC_ECALL, (int)N_EC_XRET, (int)N_EC_EBRK,
                   (unsigned)(uint32_t)N_HITS, (int)N_RS_FRESH,
                   (int)N_IC_INVR, (int)N_IC_INVD, (unsigned)(uint32_t)N_IC_CNT,
                   (int)N_IC_IVP, (int)N_IC_IVR,
                   (int)N_IC_RSV, (int)N_IC_RV, (int)N_IC_RCS,
                   (int)N_IC_REDO, (int)N_IC_RJMP, (int)N_LSU_FPC);
        // ★ Task 18 第三轮：[COREL] = LSU flush 推进 / D$ 写回忙 / D$ refill
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
            printf("[COREL] %llu flush(b=%d doit=%d cptr=%d rptr=%d) cacheStore(v=%d addr=%08llX)"
                   " || D$ wbBusy=%d refill(full=%d push=%d) store2valid=%d\n",
                   (unsigned long long)cyc,
                   (int)N_FL_BUSY, (int)N_FL_DOIT,
                   (unsigned)(uint32_t)N_FL_CPTR, (unsigned)(uint32_t)N_FL_RPTR,
                   (int)N_LSU_CACHE, (unsigned long long)N_CS_ADDR & 0xFFFFFFFFull,
                   (int)N_WBBUSY, (int)N_REF_FULL, (int)N_REF_PUSH, (int)N_ST2_V);
        // ★ Task 23：[COREH] = FetchPlugin stage-0 的 haltRequest（8 路逐位 + 或）
        //   + PcPlugin 的 6 路 jump 来源 + "重定向到自身"标志。
        //   判据：haltOr!=0 ⇒ 前端被 halt（"被 halt 住"）；
        //         haltOr==0 且 jump(v=1) 且 tgt==fpc ⇒ 前端把一个 PC 重定向到它自己（"被重定向刷死"）。
        //   8 路的导出式与 rtl/NaxSocMini.v 里的 assign 逐字对应（见每行注释）。
        if (TB_CORE_HALT && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to) {
            const int h389   = (int)(((int)N_H_FCDONE == 0) || (int)N_H_FCREQ);        // l389 = !done||req
            const int h476   = (int)N_H_FC476;                                        // l476 = refill_valid
            const int h552   = (int)N_H_FC552;                                        // l552 = reg
            const int h583   = (int)(((uint32_t)N_H_MMUST != 1u));                    // l583 = !(stateReg==IDLE)
            const int h1548  = (int)N_H_LSU1548;                                      // l1548 = reg
            const int h512   = (int)(((int)N_H_MMU512 == 0) || (int)N_H_MMUREQ);       // l512 = !done||req
            const int h986   = (int)(((uint32_t)N_H_PRIV986 != 1u)
                                     || ((int)N_RS_V && (int)N_RS_TRAP));             // l986
            const int h140   = (int)(((uint32_t)N_H_ENV140 != 1u));                   // l140
            const int haltOr = h389|h476|h552|h583|h1548|h512|h986|h140;
            const int haltGen= ((int)N_S0_RDYOUT && !(int)N_S0_RDYN) ? 1 : 0;
            const int jPriv  = (int)N_PR_JMPV;                                        // PrivilegedPlugin
            const int jComm  = (int)((int)N_RS_FRESH && !(int)N_RS_TRAP);             // CommitPlugin
            const int jDec   = (int)((int)N_FR_V && ((int)N_J_NEEDC1 || (int)N_J_NEEDC0)); // DecoderPrediction
            const int jAlign = (int)((int)N_J_ABVAL1 && !(int)N_J_ALCORR);            // AlignerPlugin
            const int jRedo  = (int)N_J_REDO;                                        // FetchCache redoJump
            const int jBtb   = (int)N_J_BTB;                                         // BtbPlugin
            printf("[COREH] %llu haltOr=%d(gen=%d)"
                   " H[fc389=%d fc476=%d fc552=%d fc583=%d lsu1548=%d mmu512=%d priv986=%d env140=%d]"
                   " s0(rdyOut=%d rdy=%d) || jump(v=%d tgt=%08llX)"
                   " src[priv=%d comm=%d dec=%d align=%d redo=%d btb=%d]"
                   " || fpc=%08llX tgtEqFpc=%d fire=%d mmuSt=%u privFSM=%u ecFSM=%u\n",
                   (unsigned long long)cyc, haltOr, haltGen,
                   h389, h476, h552, h583, h1548, h512, h986, h140,
                   (int)N_S0_RDYOUT, (int)N_S0_RDYN,
                   (int)N_JUMPV, (unsigned long long)N_JUMPTGT & 0xFFFFFFFFull,
                   jPriv, jComm, jDec, jAlign, jRedo, jBtb,
                   (unsigned long long)N_FETCHPC & 0xFFFFFFFFull,
                   ((unsigned long long)N_JUMPTGT == (unsigned long long)N_FETCHPC) ? 1 : 0,
                   (int)N_FETCHFIR,
                   (unsigned)(uint32_t)N_H_MMUST, (unsigned)(uint32_t)N_H_PRIV986,
                   (unsigned)(uint32_t)N_H_ENV140);
        }
        // ================= ★ M2-b Gate 2 第五轮：提交 PC / 取指 PC 直方图（TB_PCHIST=1）=============
        //   纪律：`PC_HIST` 为假时**一行不打、一次累加都不做**（判据装置更是不带 TB_PEEK_CODE）。
        //   采样点与其他内视探针一致（clk=0 相位、`eval()` 之后）⇒ 与 `[CORE]`/`[COREH]` 同拍可对账。
        if (PC_HIST) {
            const uint32_t cpc0 = (uint32_t)((uint64_t)P_CM_PC0 & 0xFFFFFFFFull);
            const uint32_t cpc1 = (uint32_t)((uint64_t)P_CM_PC1 & 0xFFFFFFFFull);
            const unsigned cmask = (unsigned)((uint32_t)P_CM_MASK & 3u);
            // ---- 全程（不受窗口限制）：提交 PC 有没有进过内核区 ----
            if (cmask & 1u) {
                n_commit_all++;
                if (!first_commit_cyc) { first_commit_cyc = cyc; first_commit_pc = cpc0;
                                         first_commit_rob = (uint32_t)((uint32_t)P_CM_ROB & 0x3Fu); }
                last_commit_cyc = cyc; last_commit_pc = cpc0;
                last_commit_rob = (uint32_t)((uint32_t)P_CM_ROB & 0x3Fu);
                if (cpc0 > max_commit_pc) max_commit_pc = cpc0;
                if (cpc0 >= KERNEL_BASE) {
                    if (!n_kern_commit) { first_kern_commit_cyc = cyc; first_kern_commit_pc = cpc0; }
                    n_kern_commit++;
                }
            }
            if (cmask & 2u) {
                n_commit_all++;
                if (!first_commit_cyc) { first_commit_cyc = cyc; first_commit_pc = cpc1;
                                         first_commit_rob = (uint32_t)((uint32_t)P_CM_ROB & 0x3Fu); }
                last_commit_cyc = cyc; last_commit_pc = cpc1;
                last_commit_rob = (uint32_t)((uint32_t)P_CM_ROB & 0x3Fu);
                if (cpc1 > max_commit_pc) max_commit_pc = cpc1;
                if (cpc1 >= KERNEL_BASE) {
                    if (!n_kern_commit) { first_kern_commit_cyc = cyc; first_kern_commit_pc = cpc1; }
                    n_kern_commit++;
                }
            }
            // ---- 前端取指 PC（**独立**于提交掩码的交叉校验）----
            if ((int)N_FR_V) {
                const uint32_t fpc = (uint32_t)((uint64_t)N_FR_PC & 0xFFFFFFFFull);
                if (fpc > max_fetch_pc) max_fetch_pc = fpc;
                if (fpc >= KERNEL_BASE) {
                    if (!n_kern_fetch) { first_kern_fetch_cyc = cyc; first_kern_fetch_pc = fpc; }
                    n_kern_fetch++;
                }
            }
            // ---- 窗口内 ----
            if ((long)cyc >= pc_from && (long)cyc <= pc_to) {
                cm_hist[cmask]++;
                if (cmask & 1u) {
                    n_commit_win++; h_commit[cpc0]++;
                    if (commit_seq.size() < 2000000u) commit_seq.push_back(cpc0);
                }
                if (cmask & 2u) {
                    n_commit_win++; h_commit[cpc1]++;
                    if (commit_seq.size() < 2000000u) commit_seq.push_back(cpc1);
                }
                if ((int)N_FR_V) {
                    n_fetch_win++;
                    h_fetch[(uint32_t)((uint64_t)N_FR_PC & 0xFFFFFFFFull)]++;
                }
                const uint32_t rp0 = (uint32_t)((uint32_t)N_ROB_COMMIT & 0x7Fu);
                const uint32_t rp1 = (uint32_t)((uint32_t)N_ROB_COMMITN & 0x7Fu);
                const unsigned d = (unsigned)((rp1 - rp0) & 0x7Fu);
                if (d <= 2u) n_rob_delta[d]++; else rob_delta_other++;
            }
        }
        // ★ Task 24 ③：[BTBL] = BtbPlugin 学习脉冲 + **BTB 数组写入**（谁把 pcTarget 写成了什么）
        //   + BTB 读出的 entry（正在发射的预测）+ RAS 栈顶 + 前端"把 PC 重定向到自身且源=btb"的首次拍。
        //   采样点在本循环的 clk=0 相位（`dut->soc_clk = 1` 之前）⇒ 看到的 mem[] 已经含**上一拍
        //   上升沿**写入的内容；因此 mem 变化要用**上一拍采到的** learn 载荷来配对（下方 prev_*）。
        if (TB_BTB) {
            auto dec_btb = [](uint64_t e, uint64_t& tgt, unsigned& sl, unsigned& h, int& br) {
                h   = (unsigned)(e & 0xFFFFull);
                sl  = (unsigned)((e >> 16) & 0x3ull);
                tgt = (e >> 18) & 0xFFFFFFFFFFull;
                br  = (int)((e >> 58) & 1ull);
            };
            // 当前组合的 learn 载荷（81bit 读响应 = {taken, pcTarget[39:0], pcOnLastSlice[39:0]}）
            const uint64_t r0 = (uint64_t)N_NB_RSP[0], r1 = (uint64_t)N_NB_RSP[1],
                           r2 = (uint64_t)N_NB_RSP[2];
            const uint64_t lp_pc  = (r0 | (r1 << 32)) & 0xFFFFFFFFFFull;
            const uint64_t lp_tgt = ((r1 >> 8) | (r2 << 24)) & 0xFFFFFFFFFFull;
            const int      lp_tk  = (int)((r2 >> 16) & 1ull);
            const bool     ln_v   = (bool)N_LN_V;
            const int selfBtb = ((int)N_J_BTB && (int)N_JUMPV
                                 && ((uint64_t)N_JUMPTGT == (uint64_t)N_FETCHPC)) ? 1 : 0;
            // 注意：`tgt==fpc` 单独的**瞬时**出现是正常现象（A/B/本体的运行中读数里都有；
            // 复位期 fpc=tgt=0 也满足）⇒ 只有"**连续**保持"才是活锁。这里对连续长度计数。
            self_run = selfBtb ? (self_run + 1) : 0;
            if (self_run == 1000ull) {
                if (!self_run_first) self_run_first = cyc;
                n_long_runs++;
                if (n_long_runs <= 4)
                    printf("[BTBL] %llu SELF-REDIRECT **持续 1000 拍**（首次连续，fpc=tgt=%08llX）\n",
                           (unsigned long long)cyc,
                           (unsigned long long)N_JUMPTGT & 0xFFFFFFFFull);
            }
            if (selfBtb && !prev_self_btb) {
                if (!n_self_btb) first_self_btb = cyc;
                n_self_btb++;
                if ((long)n_self_btb <= 8)
                    printf("[BTBL] %llu SELF-REDIRECT src=btb fpc=tgt=%08llX (第 %llu 次)\n",
                           (unsigned long long)cyc,
                           (unsigned long long)N_JUMPTGT & 0xFFFFFFFFull,
                           (unsigned long long)n_self_btb);
            }
            prev_self_btb = selfBtb;
            if (ln_v && !prev_ln_v) n_ln_all++;
            // ①BTB 数组逐 entry 变化（写完之后的第一次采样才看得到）
            if (btb_armed) {
                for (int i = 0; i < 512; i++) {
                    const uint64_t nv = (uint64_t)N_BTB_MEM[i];
                    if (nv == btb_snap[i]) continue;
                    uint64_t nt, ot; unsigned nsl, nh, osl, oh; int nbr, obr;
                    dec_btb(nv, nt, nsl, nh, nbr);
                    dec_btb(btb_snap[i], ot, osl, oh, obr);
                    n_btb_wr++;
                    const bool isWatch = (((nt & ~1ull) == BTB_WATCH) || ((ot & ~1ull) == BTB_WATCH)
                                          || ((i & 0x1FF) == ((int)(BTB_WATCH >> 3) & 0x1FF)));
                    if (isWatch) {
                        n_btb_wr_watch++;
                        if ((long)n_btb_wr_watch <= TB_BTB_CAP)
                            printf("[BTBL] %llu BTB-WRITE idx=%03X | old tgt=%08llX br=%d sl=%u h=%04X"
                                   " | new tgt=%08llX br=%d sl=%u h=%04X"
                                   " | 上一拍 learn: pc=%08llX tgt=%08llX taken=%d valid=%d"
                                   " | watchIdx=%03X\n",
                                   (unsigned long long)cyc, i & 0x1FF,
                                   (unsigned long long)(ot & 0xFFFFFFFFull), obr, osl, oh,
                                   (unsigned long long)(nt & 0xFFFFFFFFull), nbr, nsl, nh,
                                   (unsigned long long)(prev_ln_pc & 0xFFFFFFFFull),
                                   (unsigned long long)(prev_ln_tgt & 0xFFFFFFFFull),
                                   prev_ln_tk, (int)prev_ln_v,
                                   (int)((BTB_WATCH >> 3) & 0x1FFull));
                    }
                    btb_snap[i] = nv;
                }
            } else {
                for (int i = 0; i < 512; i++) btb_snap[i] = (uint64_t)N_BTB_MEM[i];
                btb_armed = true;
            }
            // ②BTB 本拍读出的 entry（fetch pc 命中 watch 时）
            {
                const uint64_t fpc = (uint64_t)N_FETCHPC & 0xFFFFFFFFull;
                const int hit = (fpc == BTB_WATCH) ? 1 : 0;
                if (hit && !prev_fpc_watch) {
                    uint64_t t2; unsigned sl2, h2; int br2;
                    dec_btb((uint64_t)N_BTB_RD, t2, sl2, h2, br2);
                    printf("[BTBL] %llu BTB-RD fpc=%08llX entry(tgt=%08llX br=%d sl=%u h=%04X)"
                           " | jump(v=%d tgt=%08llX srcBtb=%d)\n",
                           (unsigned long long)cyc, (unsigned long long)fpc,
                           (unsigned long long)(t2 & 0xFFFFFFFFull), br2, sl2, h2,
                           (int)N_JUMPV, (unsigned long long)N_JUMPTGT & 0xFFFFFFFFull,
                           (int)N_J_BTB);
                }
                prev_fpc_watch = hit;
            }
            // ③RAS 栈顶变成 watch 地址（ret 的预测返回目标）
            {
                const uint64_t rt = (uint64_t)N_RA_RD & 0xFFFFFFFFull;
                const int hw = ((rt & ~1ull) == BTB_WATCH) ? 1 : 0;
                if (hw && !prev_ras_watch)
                    printf("[BTBL] %llu RAS-top=%08llX (ret 的预测返回目标)\n",
                           (unsigned long long)cyc, (unsigned long long)rt);
                prev_ras_watch = hw;
            }
            prev_ln_v = ln_v; prev_ln_pc = lp_pc; prev_ln_tgt = lp_tgt; prev_ln_tk = lp_tk;
        }
        // ★ Task 18 第四轮：[COREW] = D$ writeback 槽占用（busy 的来源）
        if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
            printf("[COREW] %llu WBslot0(v=%d rdDone=%d victimBufReady=%d wrDone=%d fire=%d addr=%08llX)"
                   " slot1(v=%d) snoopTagUpdate=%d || refillSlot0v=%d\n",
                   (unsigned long long)cyc,
                   (int)N_WB0_V, (int)N_WB0_RD, (int)N_WB0_VB, (int)N_WB0_WR, (int)N_WB0_F,
                   (unsigned long long)N_WB0_A & 0xFFFFFFFFull,
                   (int)N_WB1_V, (int)N_SNOOPTU, (int)N_RFS0_V);
        // ================= ★ M2-b Gate 2 第二轮：写回槽清不掉的**两条例通路** =============
        // 计数全部只累加（§6 手法）；打印全部由 SOC_WB_DBG=1 打开（默认一行不打）。
        {
            const int wb0f = (int)N_WB0_F, wb1f = (int)N_WB1_F;
            const int l1271 = (int)N_L1271, wrsp = (int)N_WRSP_V, push = (int)N_PUSH_V;
            if (wb0f) c_wb0_fire++;
            if (wb1f) c_wb1_fire++;
            if (l1271) c_l1271++;
            if (wrsp) c_wrsp++;
            if (push) c_push++;
            if (push && (int)N_PUSH_REL) c_push_rel1++;
            if (push && !(int)N_PUSH_REL) c_push_rel0++;
            if ((int)N_WB0_V && !prev_wb0_v) { c_wb0_rise++; last_wb0_rise = cyc; }
            if ((int)N_WB1_V && !prev_wb1_v) c_wb1_rise++;
            if (wb0f && !prev_wb0_f) { if (!first_wb0_fire) first_wb0_fire = cyc; last_wb0_fire = cyc; }
            if (wrsp) last_wrsp = cyc;
            // "槽占着且写命令已发完、却一直没有 fire" 的拍数 —— 冻结的指纹
            if ((int)N_WB0_V && (int)N_WB0_WR && !wb0f) c_slot0_stuck++;
            if ((int)N_WB1_V && (int)N_WB1_WRD && !wb1f) c_slot1_stuck++;
            prev_wb0_f = wb0f; prev_wb1_f = wb1f; prev_l1271 = l1271;
            prev_wrsp = wrsp; prev_push = push;
            prev_wb0_v = (int)N_WB0_V; prev_wb1_v = (int)N_WB1_V;
            if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
                printf("[WBDBG] %llu"
                       " | SLOT0(v=%d fire=%d rel=%d dirt=%d prid=%d rdDone=%d wrDone=%d vb=%d a=%08llX)"
                       " SLOT1(v=%d fire=%d rel=%d dirt=%d prid=%d rdDone=%d wrDone=%d vb=%d a=%08llX)"
                       " | CMD v=%d rdy=%d fire=%d id=%d last=%d rel=%d dirt=%d prid=%d a=%08llX wl=%d wi=%d"
                       " | l1271=%d l1253=%d | RSP v=%d | PUSH v=%d rel=%d dirt=%d prid=%d a=%08llX"
                       " st[fl=%d rf=%d ld=%d ask=%d snAsk=%d snSuc=%d]\n",
                       (unsigned long long)cyc,
                       (int)N_WB0_V, wb0f, (int)N_WB0_REL, (int)N_WB0_DIRT, (int)N_WB0_PRID,
                       (int)N_WB0_RDD, (int)N_WB0_WRD, (int)N_WB0_VB,
                       (unsigned long long)N_WB0_A & 0xFFFFFFFFull,
                       (int)N_WB1_V, wb1f, (int)N_WB1_REL, (int)N_WB1_DIRT, (int)N_WB1_PRID,
                       (int)N_WB1_RDD, (int)N_WB1_WRD, (int)N_WB1_VB,
                       (unsigned long long)N_WB1_A & 0xFFFFFFFFull,
                       (int)N_WBC_V, (int)N_WBC_R, (int)N_WBC_F, (int)N_WBC_ID, (int)N_WBC_LAST,
                       (int)N_WBC_REL, (int)N_WBC_DIRT, (int)N_WBC_PRID,
                       (unsigned long long)N_WBC_ADDR & 0xFFFFFFFFull,
                       (int)N_WB_WLAST, (int)N_WB_WIDX,
                       l1271, (int)N_L1253, wrsp,
                       push, (int)N_PUSH_REL, (int)N_PUSH_DIRT, (int)N_PUSH_PRID,
                       (unsigned long long)N_PUSH_ADDR & 0xFFFFFFFFull,
                       (int)N_ST_FLUSH, (int)N_ST_RFILL, (int)N_LD_RFILL,
                       (int)N_CTRL_ASK, (int)N_SNOOP_ASK, (int)N_SNOOP_SUC);
        }
        // ---- Hub / TL 侧：那枚 D_RELEASE_ACK 到底有没有被造出来 ----
        {
            const int upd = (int)H_UPD_V, ain0 = (int)H_DOWNA0_V;
            if (upd) { c_hub_upd++; last_hub_upd = cyc; }
            if (ain0) { c_hub_ain0++; last_hub_ain0 = cyc; }
            if ((int)H_RSP_INV) c_hub_inv++;
            if ((int)H_RSP_INV && (int)H_RSP_HITB) c_hub_hitb++;
            if ((int)H_RSP_LOST) c_hub_rsp_lost++;
            if ((int)H_SETBUSY) c_setbusy++;
            if ((int)H_B0_V) c_b0_occ++;
            if ((int)H_B1_V) c_b1_occ++;
            if ((int)H_B2_V) c_b2_occ++;
            if ((int)H_PS0_ACK) { if (!prev_ps0ack) c_ps0_ack++; prev_ps0ack = 1; } else prev_ps0ack = 0;
            prev_hub_upd = upd; prev_hub_ain0 = ain0;
            if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
                printf("[HUBDBG] %llu | UPD_to_Dcache(v=%d op=%d src=%d sink=%d)"
                       " rsp(in=%d hitBe=%d byp=%d lost=%d pend=%d)"
                       " | B0(v=%d fromC=%d wd=%d alloc=%d last=%d slot=%d a=%08llX)"
                       " B1(v=%d wd=%d toDown=%d slot=%d a=%08llX rdyo=%d)"
                       " B2(v=%d wd=%d toDown=%d slot=%d a=%08llX)"
                       " | slotLock=%d setBusy=%d ps(v=%d%d%d%d pend0=%d pend1=%d ack0=%d)"
                       " | DOWN_A0(v=%d op=%d) UP_D(v=%d op=%d src=%d)\n",
                       (unsigned long long)cyc,
                       (int)H_UPD_V, (int)H_UPD_OP, (int)H_UPD_SRC, (int)H_UPD_SINK,
                       (int)H_RSP_INV, (int)H_RSP_HITB, (int)H_RSP_BYP, (int)H_RSP_LOST,
                       (int)H_RSP_PEND,
                       (int)H_B0_V, (int)H_B0_FROMC, (int)H_B0_WD, (int)H_B0_ALLO, (int)H_B0_LAST,
                       (int)H_B0_SLOT, (unsigned long long)H_B0_A & 0xFFFFFFFFull,
                       (int)H_B1_V, (int)H_B1_WD, (int)H_B1_TOWN, (int)H_B1_SLOT,
                       (unsigned long long)H_B1_A & 0xFFFFFFFFull, (int)H_B1_RDYO,
                       (int)H_B2_V, (int)H_B2_WD, (int)H_B2_TOWN, (int)H_B2_SLOT,
                       (unsigned long long)H_B2_A & 0xFFFFFFFFull,
                       (int)H_SLOTLOCK, (int)H_SETBUSY,
                       (int)H_PS0_V, (int)H_PS1_V, (int)H_PS2_V, (int)H_PS3_V,
                       (int)H_PS0_P, (int)H_PS1_P, (int)H_PS0_ACK,
                       (int)H_DOWNA0_V, (int)H_DOWNA0_OP,
                       (int)H_UPDD_V, (int)H_UPDD_OP, (int)H_UPDD_SRC);

            // ★ T32：那枚上行 RELEASE_ACK 的三道口（只累加 + 窗口内逐拍打；判据见 §14.5）
            {
                const int ackV = (int)G_ACK_V, hubIoV = (int)G_HUBIO_DV;
                if (ackV) { c_ack_v++; last_ack_v = cyc; }
                // ★ T32 跳一：多余释放？（rtl:9400/9401 重建）—— 释放了一个**本就空**的槽 ⇒ 下游把 id 复用/错带
                const int relV = ((int)G_D1V && !(int)G_D1FIRED && (int)G_D1L) ? 1 : 0;
                const int relP = (int)G_D1SRC & 3;
                const int spur = (relV && !(((unsigned)G_VALIDS >> relP) & 1u)) ? 1 : 0;
                if (relV) { c_rel_v++; last_rel_v = cyc; }
                if (spur) { c_rel_spur++; last_rel_spur = cyc; }
                // 跳二：slots_allocate（rtl:9349 重建）；并查上一次分配是否"下一拍就没落地"
                {
                    const int b0f = (int)G_B0FIRE, b0l = (int)G_B0LAST, b0s = (int)G_B0SAL;
                    const int allocNow = (b0f && b0s && g_first) ? 1 : 0;
                    if (g_prevAlloc && !(((unsigned)G_VALIDS >> g_prevAllocId) & 1u)) {
                        c_alloc_stickfail++; last_stickfail = cyc;
                    }
                    if (allocNow) {
                        c_alloc++; last_alloc = cyc;
                        if ((int)G_B0FRC) c_alloc_c++; else if ((int)G_B0WD) c_alloc_w++; else c_alloc_r++;
                    }
                    g_prevAlloc = allocNow; g_prevAllocId = (int)G_FREEID & 3;
                    g_first = b0f ? (b0l ? 1 : 0) : g_first;
                }
                if (ackV && !hubIoV) { c_ack_stuckbeforeio++; last_ack_stuck = cyc; }
                if (ackV && !(int)G_ACK_HIT) c_ack_nohit++;
                if ((int)G_ACK_FIRED) c_ack_fire++;
                if (ackV && (int)G_ACK_OP == 6) c_ack_ra++;
                if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
                    printf("[HUBG] %llu | ack(v=%d hit=%d fired=%d op=%d) hubIoUpD=%d"
                           " | decUpD(v=%d op=%d src=%d) | coreWrsp=%d"
                           " | ctxW(v=%d d=%03X) ctxR=%03X id=%d freeOh=%X valids=%X"
                           " | rel(v=%d p=%d%s) alc=%d%s first=%d | ctx[%03X %03X %03X %03X]\n",
                           (unsigned long long)cyc,
                           ackV, (int)G_ACK_HIT, (int)G_ACK_FIRED, (int)G_ACK_OP, hubIoV,
                           (int)H_UPDD_V, (int)H_UPDD_OP, (int)H_UPDD_SRC,
                           (int)N_WRSP_V,
                           (int)G_CTXW_V, (unsigned)G_CTXW_D & 0x3FFF,
                           (unsigned)G_CTXR1 & 0x3FFF, (int)G_FREEID, (unsigned)G_FREEOH & 0xF,
                           (unsigned)G_VALIDS & 0xF,
                           relV, relP, spur ? "  <<SPURIOUS>>" : "",
                           (int)G_B0FIRE && (int)G_B0SAL && g_first ? 1 : 0,
                           (((int)G_B0FIRE && (int)G_B0SAL && g_first) && (int)G_B0FRC) ? "C"
                             : (((int)G_B0FIRE && (int)G_B0SAL && g_first) && !(int)G_B0WD) ? "R" : "W",
                           g_first,
                           (unsigned)G_CTX[0] & 0x3FFF, (unsigned)G_CTX[1] & 0x3FFF,
                           (unsigned)G_CTX[2] & 0x3FFF, (unsigned)G_CTX[3] & 0x3FFF);
            }
        }
        // ---- Axi4Bridge（`toAxi4`，胶合块之前）内部逐笔：只在 A/D 真握手那一拍打一行 ----
        //   A_PUT_FULL_DATA=0, A_GET=4；把每一笔进桥的 A 命令的 (op/addr) 都记下来，
        //   就能判"Hub 下游那 8 拍 PUT 到底有没有进桥、进桥后有没有出 AW"。
        {
            m_dbg_aw = false;
            const bool a_fire = (int)T_UP_A_FIRE;
            const bool d_fire = (int)T_UP_D_FIRE;
            const uint32_t a_a  = (uint32_t)(uint64_t)T_ACMD_A;
            const int      a_op = (int)T_ACMD_OP;
            if (a_fire) {
                c_m_aw++;
                last_m_aw = cyc; last_m_aw_a = a_a;
                if (a_op == 0 || a_op == 1) { c_t_uaput++; last_t_uaput = cyc; last_t_uaput_a = a_a; }
            }
            if ((int)T_ACMD_V2 && (a_op == 0 || a_op == 1)) { c_t_acmd_put++; last_t_acmd_put = cyc; }
            if (a_a == WB_WATCH0 || a_a == WB_WATCH1) c_t_watch++;
            if (d_fire) { c_m_b++; last_m_b = cyc; }
            if ((int)T_CTXFULL) { c_ctxfull++; last_m_ctxfull = cyc; }
            if (TB_CORE && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to
                && (a_fire || d_fire))
                printf("[BRIDGE] %llu %s%s | A(up) op=%d beat=%d last=%d cmdV=%d cmdV2=%d a=%08X src=%d"
                       " fork(f=%d rdy=%d) buff=%d dataFork(v=%d r=%d) haltRdy=%d ctxFull=%d | D(up) fire=%d\n",
                       (unsigned long long)cyc,
                       a_fire ? "A-hs" : "", d_fire ? "D-hs" : "",
                       a_op, (int)T_UP_A_BEAT, (int)T_UP_A_LAST,
                       (int)T_ACMD_V, (int)T_ACMD_V2, a_a, (int)T_ACMD_SRC,
                       (int)T_FORK_FIRE, (int)T_FORK_RDY, (int)T_ACMD_BUFF,
                       (int)T_ADATA_V, (int)T_ADATA_R, (int)T_HALT_RDY, (int)T_CTXFULL,
                       (int)T_UP_D_FIRE);
        }
#endif  // TB_PEEK_CODE

#ifdef TB_PEEK_CODE
        // ★ Task 12：AlignerPlugin 装配窗口逐拍打印（TB_ALIGN=1 + SOC_WIN_FROM/TO 限定范围）
        //   格式解读：
        //     IN  = aligner 输入（fetch pipeline 末级 s2m）：iv（isInputValid）/rdy/pc/mf/mb/
        //            brv/brs/brpn（预测的"最后一个 slice"边界）/w（新取指行的 64bit 原文）
        //     BUF = 跨行携带寄存器：m（buffer.mask，还剩哪些 slice）/pc/d = 上一个取指行的原文
        //     FIR = fireInput / fireOutput / carry（8 slice，低 4 = buffer 高 4 = 输入行）/rem/corr
        //     OUT = FrontendPlugin.aligned（组合，本拍送下一级）：rdy + 槽0/槽1 的
        //            (MASK_ALIGNED, 32bit 窗口, INSTRUCTION_SLICE_COUNT)
        //     DEC = decompressed 阶段（aligned 打一拍）与 decoded 阶段的非法指令标志
        {
            unsigned carry = (unsigned)(AL_IVAL ? (((uint32_t)AL_MFRT & 0xF) << 4) : 0u) | (unsigned)((uint32_t)AL_BMASK & 0xF);
            if (TB_ALIGN && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
                printf("[ALIGN] %llu IN iv=%d rdy=%d pc=%08llX mf=%X mb=%X brv=%d brs=%u brpn=%08llX w=%016llX"
                       " | BUF m=%X pc=%08llX d=%016llX bv=%d bs=%u"
                       " | FIR in=%d out=%d carry=%02X rem=%02X corr=%d"
                       " | OUT rdy=%d [0](mk=%d,%08X,slc=%u) [1](mk=%d,%08X,slc=%u)"
                       " || DEC v=%d dpc0=%08llX din0=%08X dpc1=%08llX din1=%08X ill0=%d ill1=%d mop0=%08X mop1=%08X\n",
                       (unsigned long long)cyc,
                       (int)AL_IVAL, (int)AL_SRDY,
                       (unsigned long long)AL_PC & 0xFFFFFFFFull,
                       (unsigned)(uint32_t)AL_MFRT, (unsigned)(uint32_t)AL_MBCK,
                       (int)AL_BRVAL, (unsigned)(uint32_t)AL_BRSL,
                       (unsigned long long)AL_BRPN & 0xFFFFFFFFull,
                       (unsigned long long)(uint64_t)AL_WORD,
                       (unsigned)(uint32_t)AL_BMASK,
                       (unsigned long long)AL_BPC & 0xFFFFFFFFull,
                       (unsigned long long)(uint64_t)AL_BDATA,
                       (int)AL_BRVL, (unsigned)(uint32_t)AL_BRSL2,
                       (int)AL_FIN, (int)AL_FOUT, carry, (unsigned)(uint32_t)AL_REM, (int)AL_CORR,
                       (int)AL_ORDY,
                       (int)AL_OMK0, (unsigned)(uint32_t)AL_OIN0, (unsigned)(uint32_t)AL_OSL0,
                       (int)AL_OMK1, (unsigned)(uint32_t)AL_OIN1, (unsigned)(uint32_t)AL_OSL1,
                       (int)AL_DVAL,
                       (unsigned long long)AL_DPC0 & 0xFFFFFFFFull, (unsigned)(uint32_t)AL_DIN0,
                       (unsigned long long)AL_DPC1 & 0xFFFFFFFFull, (unsigned)(uint32_t)AL_DIN1,
                       (int)AL_ILL0, (int)AL_ILL1,
                       (unsigned)(uint32_t)AL_MOP0, (unsigned)(uint32_t)AL_MOP1);
            // I$ refill / 命中（同一窗口）——用来判定"零 word / 错位 word"是 I$ 侧还是对齐器侧
            if (TB_ALIGN && win_from >= 0 && (long)cyc >= win_from && (long)cyc <= win_to)
                printf("[FILL]  %llu ref(v=%d a=%08llX widx=%u way=%u) waddr=%03X rdv=%d | s2(hit=%d h=%d%d%d%d pc=%08llX w=%016llX)\n",
                       (unsigned long long)cyc,
                       (int)FC_RV, (unsigned long long)FC_RA & 0xFFFFFFFFull,
                       (unsigned)(uint32_t)FC_WIDX, (unsigned)(uint32_t)FC_WAY,
                       (unsigned)(uint32_t)FC_WRA, (int)FC_RDV,
                       (int)FC_HIT, (int)FC_H0, (int)FC_H1,
                       (unsigned long long)FC_S2PC & 0xFFFFFFFFull,
                       (unsigned long long)(uint64_t)FC_S2W);
        }
#endif  // TB_PEEK_CODE

#ifdef TB_PEEK_CODE
        // --- PC 采样（前端取指 PC / ALU0 执行 PC 变化时记一条）---
        {
            uint64_t fpc = F_PC, apc = A_PC;
            if (fpc != prev_fpc || apc != prev_apc) {
                prev_fpc = fpc; prev_apc = apc;
                pc_ring.push_back(PcSamp{cyc, fpc, apc, A_V});
                if (pc_ring.size() > 4000) pc_ring.erase(pc_ring.begin(), pc_ring.begin() + 1000);
            }
            int exv = EX_V;
            if (exv && !prev_exv) {
                n_ex++;
                if (PEEK && n_ex <= 8)                     // 陷阱循环会一直重复 ⇒ 只打前 8 条
                    printf("[EXCEPTION] cyc=%llu exceptionPort.valid=1 epc=0x%08llX mcause=%u"
                           " (1=fetch access fault, 2=illegal insn, 12=fetch page fault;"
                           " NOT the PrivilegedPlugin_logic_exception_code=%u)\n",
                           (unsigned long long)cyc,
                           (unsigned long long)EX_EPC & 0xFFFFFFFFull,
                           (unsigned)EX_MCAUSE, (unsigned)EX_CODE);
            }
            prev_exv = exv;
        }
        if (DCD_AT != 0 && (long)cyc == DCD_AT) {
            auto* dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            printf("[DCD] cyc=%llu dcache snapshot (module DataCache: ways/status/plru copies + data banks)\n",
                   (unsigned long long)cyc);
            for (int set = 0; set < 64; set++) {
                unsigned tA[4], tB[4], stA, stB, plA, plB;
                tA[0]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_0_mem__DOT__ram_block[set]&0x7FFFFF;
                tB[0]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_0_mem_1__DOT__ram_block[set]&0x7FFFFF;
                tA[1]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_1_mem__DOT__ram_block[set]&0x7FFFFF;
                tB[1]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_1_mem_1__DOT__ram_block[set]&0x7FFFFF;
                tA[2]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_2_mem__DOT__ram_block[set]&0x7FFFFF;
                tB[2]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_2_mem_1__DOT__ram_block[set]&0x7FFFFF;
                tA[3]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_3_mem__DOT__ram_block[set]&0x7FFFFF;
                tB[3]=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_3_mem_1__DOT__ram_block[set]&0x7FFFFF;
                stA=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__status_mem__DOT__ram_block[set]&0xF;
                stB=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__status_mem_1__DOT__ram_block[set]&0xF;
                plA=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__plru_ram__DOT__ram_block[set]&0x7;
                plB=(unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__plru_ram_1__DOT__ram_block[set]&0x7;
                int bad = (stA!=stB)||(plA!=plB)||(tA[0]!=tB[0])||(tA[1]!=tB[1])||(tA[2]!=tB[2])||(tA[3]!=tB[3]);
                printf("[DCDT] set=%02d tagsA=%06x %06x %06x %06x | tagsB=%06x %06x %06x %06x | st=%x/%x plru=%x/%x%s\n",
                       set, tA[0], tA[1], tA[2], tA[3], tB[0], tB[1], tB[2], tB[3], stA, stB, plA, plB,
                       bad ? "  <<< TWO-COPIES-DIFFER" : "");
            }
            for (int w = 0; w < 4; w++) {
                for (int set = 0; set < 64; set++) {
                    printf("[DCDD] way=%d set=%02d", w, set);
                    for (int i = 0; i < 8; i++) {
                        unsigned idx = (unsigned)(set * 8 + i);
                        unsigned long long v = 0;
                        if (w == 0)      v = (unsigned long long)dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_0_mem__DOT__ram_block[idx];
                        else if (w == 1) v = (unsigned long long)dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_1_mem__DOT__ram_block[idx];
                        else if (w == 2) v = (unsigned long long)dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_2_mem__DOT__ram_block[idx];
                        else             v = (unsigned long long)dc->__PVT__DataCachePlugin_logic_cache__DOT__banks_3_mem__DOT__ram_block[idx];
                        printf(" %016llx", v);
                    }
                    printf("\n");
                }
            }
        }
        if (SWEEP_ON && (long)cyc >= SW_FROM && (long)cyc <= SW_TO && SW_STEP > 0 &&
            ((long)cyc - SW_FROM) % SW_STEP == 0) {
            auto* dc = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core;
            int nbuf = 0, ndump = 0, ncode = 0, noth = 0, nzero = 0;
            for (int set = 0; set < 64; set++) {
                for (int w = 0; w < 4; w++) {
                    unsigned raw = 0;
                    switch (w) {
                      case 0: raw = (unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_0_mem__DOT__ram_block[set]; break;
                      case 1: raw = (unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_1_mem__DOT__ram_block[set]; break;
                      case 2: raw = (unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_2_mem__DOT__ram_block[set]; break;
                      default:raw = (unsigned)dc->__PVT__DataCachePlugin_logic_cache__DOT__ways_3_mem__DOT__ram_block[set]; break;
                    }
                    raw &= 0x7FFFFFu;
                    unsigned loaded = raw & 1u;
                    unsigned addr20 = (raw >> 1) & 0xFFFFFu;
                    if (!loaded || addr20 == 0) { nzero++; continue; }
                    unsigned long long a = ((unsigned long long)addr20 << 12) | ((unsigned)set << 6);
                    if (a >= 0x80000000ull && a < 0x80001000ull)      ncode++;
                    else if (a >= 0x8003F000ull && a < 0x80040000ull)  ndump++;
                    else if (a >= 0x80100000ull && a < 0x80110000ull)  nbuf++;
                    else noth++;
                }
            }
            printf("[DCDS] cyc=%llu valid=%d buffer=%d dump=%d code=%d other=%d empty=%d\n",
                   (unsigned long long)cyc, nbuf + ndump + ncode + noth, nbuf, ndump, ncode, noth, nzero);
        }
        // ================= ★ M2-b Gate 2 第六轮：真 trap 现场（TB_TRAP=1）=========================
        //   触发面（**既有信号**，未改任何 RTL/驱动值）：
        //     `PrivilegedPlugin_logic_rescheduleUnbuffered_rValid` 抬升（或同一有效期内三元组变化）
        //     = 特权态 FSM **接受**了一次 trap；同拍的 `rData_{cause,epc,tval}` 就是接下来
        //       要写进 (mcause, mepc, mtval) 的那个三元组。
        //   与 `PrivilegedPlugin_logic_exception_code`（随特权态 FSM 状态切语义的中间量）**无关**。
        if (TRAP_OBS) {
            const bool  rv = (int)(uint32_t)EX_RVALID;
            const uint32_t c = (uint32_t)EX_RCAUSE & 0xFu;
            const uint64_t e = (uint64_t)EX_REPC & 0xFFFFFFFFull;
            const uint64_t t = (uint64_t)EX_RTVAL & 0xFFFFFFFFull;
            if (rv && !prev_exrvalid) n_trap_rvalid_rise++;
            const bool new_trap = rv && (!prev_exrvalid || c != last_tr_c || e != last_tr_e || t != last_tr_t);
            if (new_trap) {
                n_trap_evt++;
                if (t != 0) ex_tval_nonzero++;
                if (!first_trap_cyc) first_trap_cyc = cyc;
                {
                    char key[64];
                    snprintf(key, sizeof(key), "cause=%u epc=0x%08llX tval=0x%08llX",
                             (unsigned)c, (unsigned long long)e, (unsigned long long)t);
                    const std::string skey(key);
                    h_trap_triple_all[skey]++;
                    h_trap_cause_all[c]++;
                    // 全程最后 32 次（环形）
                    trap_last.push_back(TrapEvt{cyc, c, e, t});
                    if (trap_last.size() > 32u) trap_last.erase(trap_last.begin());
                }
                if ((long)cyc >= trap_from && (long)cyc <= trap_to) {
                    n_trap_win++;
                    h_trap_cause[c]++;
                    h_trap_tup[(t != 0) ? 1 : 0][c]++;
                    {
                        char key[64];
                        snprintf(key, sizeof(key), "cause=%u epc=0x%08llX tval=0x%08llX",
                                 (unsigned)c, (unsigned long long)e, (unsigned long long)t);
                        h_trap_triple[std::string(key)]++;
                    }
                    if (trap_evts.size() < 8192u) trap_evts.push_back(TrapEvt{cyc, c, e, t});
                    if (trap_lines > 0 && (long)n_trap_win <= trap_lines)
                        printf("[TRAP] cyc=%llu rData: cause=%u epc=0x%08llX tval=0x%08llX"
                               " | payload_tval=0x%08llX\n",
                               (unsigned long long)cyc, (unsigned)c,
                               (unsigned long long)e, (unsigned long long)t,
                               (unsigned long long)((uint64_t)EX_PTVAL & 0xFFFFFFFFull));
                }
            }
            if (rv) { last_tr_c = c; last_tr_e = e; last_tr_t = t; }
            prev_exrvalid = rv;
        }
#endif  // TB_PEEK_CODE

#ifdef TB_PEEK_CODE
        // --- 装置内视：console 的写执行 / 读回 / THRE 分类 ---
        {
            int cawr_cwwr = C_AWR && C_WWR;
            if (cawr_cwwr && !prev_cawr_cwwr) {
                n_con_wr++; last_wr_cyc = cyc;
                // ★ 第六轮：写进 THR 的**原始字节**（含不可打印）——TB_CONRAW=1 时记录
                if (CONRAW) {
                    n_raw_thr++;
                    if (raw_thr.size() < 200000u) raw_thr.push_back((uint8_t)C_TXDATA);
                }
                if (PEEK)
                    printf("[PEEK-WR] cyc=%llu console exec#%llu txDataReg<=0x%02X\n",
                           (unsigned long long)cyc, (unsigned long long)n_con_wr,
                           (unsigned)(uint8_t)C_TXDATA);
            }
            prev_cawr_cwwr = cawr_cwwr;
            int rv = C_RV;
            if (rv && !prev_rv) {                       // rValid 抬升 = 一笔读握手完成
                n_con_rd++; last_rd_cyc = cyc;
                if ((C_RD & 0x20) != 0) n_rd_thre1++; else n_rd_thre0++;
                if (PEEK)
                    printf("[PEEK-RD] cyc=%llu rd#%llu rData=0x%08X THRE=%u TEMT=%u rSel=%u\n",
                           (unsigned long long)cyc, (unsigned long long)n_con_rd, (uint32_t)C_RD,
                           (unsigned)((C_RD >> 5) & 1), (unsigned)((C_RD >> 6) & 1), (unsigned)G_RSEL);
            } else if (!rv && prev_rv) {
                n_rd_ack++;                              // rValid 落沿 = CPU 已取走这笔读
            }
            prev_rv = rv;
            int txd = C_TXDATA;
            if (txd != prev_txdata) {
                prev_txdata = txd;
                if (n_con_wr > 4) n_thr_wr++;            // 前 4 笔是 LCR/DLL/DLM/LCR 配置
                last_thr_byte = (uint8_t)txd;
            }
        }
#endif  // TB_PEEK_CODE

        // ===== 判据：线上解出的文本 =====
        // 唯一定义处：循环内的提前退出与收尾报告**共用**同一份判据（避免两处漂移）。
        //   SOC_EXPECT 设了 ⇒ 子串判据（Task 9 的 banner）；没设 ⇒ Task 8 的精确匹配。
        if (criterion_ok()) {
            if (dec.waveform_ok()) {
                pass_reason = expect_sub
                    ? "wire text contains expected substring + framing ok + bit period ok"
                    : "wire text exact + framing ok + bit period ok";
                break;
            }
            // 文本对了但位周期自证不过：**不提前退出**，继续跑到超时，把波形数据留下供取证
            else if (pass_reason[0] == 0) pass_reason = "text ok but waveform self-check failed (continuing)";
        }

        // ===== clk=1 相位：寄存器更新 =====
        dut->soc_clk = 1;
        dut->eval();

        // ===== ★ Task 20：DUT 自己 `$finish` 就立刻结束，不空转到 MAX_CYC =====
        //   DUT 内的断言走 `$display(...) + $finish`（例：NaxRiscv `Decoder.scala:L106/L107`
        //   的 "FAILURE Tilelink decoder miss ???"，见 rtl/NaxSocMini.v 的 Decoder 模块）。
        //   不检查 `gotFinish()` 的后果：$finish 之后 tb 仍会把 `eval()` 空转到 MAX_CYC
        //   （20M 拍 ≈ 10 分钟白烧），并打印误导性的 `FAIL: timeout`（看着像"核没跑"，
        //   实际是 DUT 自己主动退出）。
        //   位置：放在 posedge 的 `eval()` **之后**，这样 `cyc` 就是断言真正触发的那一拍。
        //   对正常跑完的用例（pack 探针等）无影响：全程 `gotFinish()==false`，本分支不执行。
        if (Verilated::gotFinish()) {
            printf("[FINISH] DUT asserted $finish at cyc=%llu\n", (unsigned long long)cyc);
            break;
        }
    }

    // ===================== 报告 =====================
#ifdef TB_PEEK_CODE
    // ★ Task 12：I$ bank RAM 内容取证（TB_BANKDUMP=1）。
    //   判定"给到前端的 64bit word 错位"是**写进去时就错**（填充/位宽适配）还是**读出来才错**（读地址/时序）。
    //   用法：TB_BANKDUMP=<bank>[,<set>] 或 TB_BANKDUMP=all；set 指的是 address[11:6]。
    if (getenv("TB_BANKDUMP")) {
        auto dump_bank = [&](int b, int set) {
            const char* nm[4] = {"banks_0", "banks_1", "banks_2", "banks_3"};
            auto* arr = (b == 0) ? &dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_banks_0_mem
                      : (b == 1) ? &dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_banks_1_mem
                      : (b == 2) ? &dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_banks_2_mem
                                 : &dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core->__PVT__FetchCachePlugin_logic_banks_3_mem;
            (void)nm;
            for (int wi = 0; wi < 8; wi++) {
                uint64_t v = (uint64_t)(*arr)[set * 8 + wi];
                printf("[IBANK] %s set=%d word=%d entry=%03X data=%016llX\n",
                       (b == 0 ? "b0" : b == 1 ? "b1" : b == 2 ? "b2" : "b3"),
                       set, wi, set * 8 + wi, (unsigned long long)v);
            }
        };
        const char* e = getenv("TB_BANKDUMP");
        int b = -1, set = -1;
        if (strcmp(e, "all") == 0) { b = -1; set = -1; }
        else { sscanf(e, "%d,%d", &b, &set); }
        for (int bb = 0; bb < 4; bb++) {
            if (b >= 0 && bb != b) continue;
            for (int ss = 0; ss < 4; ss++) {
                if (set >= 0 && ss != set) continue;
                dump_bank(bb, ss);
            }
        }
    }
#endif  // TB_PEEK_CODE

    // ================= ★ Task 19：B 通道 id 回带契约的**常驻断言** =================
    // 契约：内存从方**必须**把 `awid` 回带到 `bid`（本核 D$ 的写回槽是按 AXI write id 选的：
    //   `writeback_slots_N_fire = ... || (io_mem_write_rsp_valid && io_mem_write_rsp_payload_id==N)`，
    //   见 rtl/NaxSocMini.v 的 DataCachePlugin `writeback_slots_N_fire`）。
    //   回错一笔 ⇒ 写回响应投错槽 ⇒ `writebackBusy` 钉死 ⇒ flushPort 无响应 ⇒ 前端被 halt
    //   （T18 的冻结就是这一条，代价是 12000 拍 + 一次假"核内部阻塞"结论）。
    // 判据：`AW id 直方图 == B 回带的 id 直方图`（**按线上真实握手记数**）。
    //   为什么用直方图而不是逐笔：① 与流量大小无关，一次抓「没回带 / 回成常数 / 回错」三类；
    //   ② 逐笔配对在装置侧只能自证（B 的 id 本来就取自同一笔 AW 的记录），直方图才能抓住"驱动端硬编码"。
    // 未决 AW（W 还没收完 ⇒ 还没回 B 的责任）从 AW 侧扣除，避免"跑完那一刻刚好有笔在飞"的假红。
    uint32_t pend_hist[16] = {0}, aw_done_hist[16];
    for (size_t i = 0; i < aw_q.size(); i++) pend_hist[aw_q[i].id & 0xF]++;
    bool bid_hist_ok = true;
    for (int i = 0; i < 16; i++) {
        aw_done_hist[i] = aw_hist[i] - pend_hist[i];
        if (aw_done_hist[i] != b_hist[i]) bid_hist_ok = false;
    }
    auto print_hist = [](const char* tag, const uint32_t* h) {
        printf("[BID-CHK] %s:", tag);
        unsigned n = 0;
        for (int i = 0; i < 16; i++) if (h[i]) { printf(" id=%d:%u", i, h[i]); n++; }
        if (n == 0) printf(" (空)");
        printf("\n");
    };
    printf("[BID-CHK] 装置 B 通道 id 回带 = %s（SOC_BID_ZERO=%d）| AW 总数=%llu B 握手总数=%llu "
           "| 未决 AW（W 未收完、尚未回 B）= %zu 笔\n",
           BID_ZERO ? "关闭（旧缺陷行为）" : "开启（默认）", (int)BID_ZERO,
           (unsigned long long)n_aw, (unsigned long long)n_b_hs, aw_q.size());
    print_hist("AW id 直方图", aw_hist);
    print_hist("B  id 直方图", b_hist);
    if (!aw_q.empty()) print_hist("AW(扣未决)", aw_done_hist);
    printf("[BID-CHK] 断言 AW id 直方图 == B id 直方图：%s%s\n",
           bid_hist_ok ? "OK" : "FAIL",
           bid_hist_ok ? "" : "  ← 从方没有把 awid 回带到 bid（或回错）；"
                             "本核 D$ 按 AXI write id 选写回槽 ⇒ 写回槽永不清、前端被 halt");

    bool text_ok = expect_sub ? (dec.text.find(expect_sub) != std::string::npos)
                              : (strcmp(dec.text.c_str(), CONSOLE_EXPECT) == 0);
    bool frames_ok = expect_sub ? (dec.frames > 0) : (dec.frames == 8);
    bool framing_ok = (dec.stop_errors == 0);
    bool wave_ok = dec.waveform_ok();
    // ★ Task 19：B 通道 id 回带契约是**判据的一部分**（不再只是观测）——直方图不等就直接 FAIL。
    bool pass = text_ok && frames_ok && framing_ok && wave_ok && bid_hist_ok;

    printf("mem data width: %u bytes | decode P=%ld cycles | frames=%d stop_errors=%d\n",
           (unsigned)BUS_BYTES, (long)dec.P, dec.frames, dec.stop_errors);
    printf("uart waveform self-check: min_low=%d min_high=%d P=%ld => %s\n",
           dec.min_low, dec.min_high, (long)dec.P, wave_ok ? "OK" : "BAD");
    printf("decoded console text = \"%s\" (%zu chars)\n", dec.text.c_str(), dec.text.size());
    if (expect_sub)
        printf("--- wire text (raw, the criterion source) ---\n%s\n--- end wire text ---\n",
               dec.text.c_str());
    printf("AXI: ar=%llu aw=%llu w=%llu r_beats=%llu orphan_w=%d oob_r=%llu oob_w=%llu"
           " r_stall_cyc=%llu wlast_mismatch=%llu w_addr_err=%u tracer_cyc=%llu\n",
           (unsigned long long)n_ar, (unsigned long long)n_aw, (unsigned long long)n_w,
           (unsigned long long)n_r_beats, aw_orphan_w,
           (unsigned long long)n_drop_oob_r, (unsigned long long)n_drop_oob_w,
           (unsigned long long)n_r_stall, (unsigned long long)n_wlast_mismatch, w_addr_err,
           (unsigned long long)n_tracer);

    int pending_beats = (r_state == 2 && !r_last_sent) ? r_beats : 0;
    if (AW_GATE)
        printf("[AW-GATE] SOC_AW_GATE=1：从方压住 awready 共 %llu 拍（awvalid 未见的拍）"
               " | aw_q 未决=%zu\n",
               (unsigned long long)n_aw_hold, aw_q.size());
    if (W_STALL)
        printf("[W-STALL] SOC_W_STALL=1：从方压住 wready 共 %llu 拍（首次 cyc=%llu）| "
               "被丢弃的 W 拍 = %d（默认口径下同样的流会丢这么多）\n",
               (unsigned long long)n_w_stall_cyc, (unsigned long long)n_w_stall_first, aw_orphan_w);
    printf("[END-STATE] ar_queue_depth=%zu r_state=%d r_remaining_beats=%d(cur=0x%08X id=%u)"
           " aw_queue_depth=%zu final: arvalid=%u rready=%u awvalid=%u wvalid=%u bvalid=%u\n",
           ar_queue.size(), r_state, pending_beats, r_cur, r_id, aw_q.size(),
           (unsigned)dut->mem_ar_arvalid, (unsigned)dut->mem_r_rready,
           (unsigned)dut->mem_aw_awvalid, (unsigned)dut->mem_w_wvalid, (unsigned)dut->mem_b_bvalid);

    // 探针**不该**写 DRAM（只写 MMIO）⇒ 这一段应当全 0
    uint64_t n_mem_changed = 0;
    for (uint32_t i = 0; i < MEM_BYTES / 4; i++) if (mem[i] != orig[i]) n_mem_changed++;
    printf("DRAM words changed by the run: %llu (探针只写 MMIO ⇒ 期望 0)\n",
           (unsigned long long)n_mem_changed);
#ifdef TB_PEEK_CODE
    // ★ 取证（默认关，`TB_MEMDIFF=1` 开）：把"被改动的字"连同地址与原值列出来。
    //   为什么要它：console 文本是花的，且 THR 写 byte-for-byte 等于线上字节 ⇒ 文本不是 16550/解码
    //   造成的；于是要分清 (a) 真的有 agent 往那段内存写了东西，还是 (b) 内存没变、核**读**错了。
    //   范围过滤 TB_MEMDIFF_FROM/TO 用来把 0x8000_0000..0x8004_0000（OpenSBI 镜像/堆）单独看。
    if (getenv("TB_MEMDIFF")) {
        uint64_t lo = getenv("TB_MEMDIFF_FROM") ? strtoull(getenv("TB_MEMDIFF_FROM"), nullptr, 0) : 0ull;
        uint64_t hi = getenv("TB_MEMDIFF_TO")   ? strtoull(getenv("TB_MEMDIFF_TO"),   nullptr, 0) : 0ull;
        uint64_t lim = getenv("TB_MEMDIFF_MAX") ? strtoull(getenv("TB_MEMDIFF_MAX"), nullptr, 0) : 256ull;
        uint64_t hit = 0, shown = 0;
        printf("[MEMDIFF] range=[0x%08llX,0x%08llX) max=%llu\n",
               (unsigned long long)lo, (unsigned long long)hi, (unsigned long long)lim);
        for (uint32_t i = 0; i < MEM_BYTES / 4u; i++) {
            if (mem[i] == orig[i]) continue;
            uint64_t a = (uint64_t)BASE + 4ull * (uint64_t)i;
            if (lo && a < lo) continue;
            if (hi && a >= hi) continue;
            hit++;
            if (shown < lim) {
                printf("[MEMDIFF] 0x%08llX: %08X -> %08X\n",
                       (unsigned long long)a, (unsigned)orig[i], (unsigned)mem[i]);
                shown++;
            }
        }
        printf("[MEMDIFF] changed words in range = %llu (listed %llu)\n",
               (unsigned long long)hit, (unsigned long long)shown);
    }
    // ★ T35：收尾时把指定地址附近的 DRAM 字打出来（`TB_PEEK_ADDR=<hex>`，默认不设 = 一行不打）
    if (const char* _pa = getenv("TB_PEEK_ADDR")) {
        uint64_t a0 = strtoull(_pa, nullptr, 0);
        printf("[DRAM] base=0x%08llX:", (unsigned long long)a0);
        for (int i = 0; i < 12; i++) {
            uint64_t a = a0 + 8ull * i;
            uint64_t off = a - BASE;
            uint64_t v = 0; for (int b = 0; b < 8; b++) v |= (uint64_t)mem_u8()[off + b] << (8 * b);
            printf(" %llX:%016llX", (unsigned long long)a, (unsigned long long)v);
        }
        printf("END\n");
    }
    printf("[GLUESUM] 胶合块 AW 门 memRdBusy=1 的拍数=%llu | 其中从方 mem_aw_awvalid=0 的拍数=%llu"
           "（首次 cyc=%u）\n", (unsigned long long)c_rdbusy,
           (unsigned long long)c_aw_suppressed, first_aw_suppressed);
    // ★ T36：线上电平沿的收尾读数（区分"核停发" vs "装置解码器卡住"）
    printf("[TXEDGE] uart_txd 电平沿总数=%llu（最后一次 cyc=%llu）| 解码帧=%d"
           " | 沿贴近 max_cyc 且帧数不涨 ⇒ 核仍在发、问题在解码侧；沿也停 ⇒ 核真停发\n",
           (unsigned long long)n_txd_edges, (unsigned long long)last_txd_edge_cyc, dec.frames);
    printf("[WBSUM] D$ 写回槽累计（全程，只累加）："
           "slot0_fire=%llu slot1_fire=%llu | slot0_valid 上升=%llu(最后一次 cyc=%llu) slot1_valid 上升=%llu\n"
           "[WBSUM]   push(writeback_push_valid)=%llu（release=1 的 %llu / release=0 的 %llu）"
           " | 通路① when_DataCache_l1271 脉冲=%llu | 通路② io_mem_write_rsp_valid 脉冲=%llu（最后一次 cyc=%llu）\n"
           "[WBSUM]   slot0 一句'valid && wrDone && !fire'的拍数=%llu | slot1 同=%llu"
           " | slot0 首次 fire cyc=%llu 最后一次 fire cyc=%llu\n",
           (unsigned long long)c_wb0_fire, (unsigned long long)c_wb1_fire,
           (unsigned long long)c_wb0_rise, (unsigned long long)last_wb0_rise,
           (unsigned long long)c_wb1_rise,
           (unsigned long long)c_push, (unsigned long long)c_push_rel1, (unsigned long long)c_push_rel0,
           (unsigned long long)c_l1271, (unsigned long long)c_wrsp, (unsigned long long)last_wrsp,
           (unsigned long long)c_slot0_stuck, (unsigned long long)c_slot1_stuck,
           (unsigned long long)first_wb0_fire, (unsigned long long)last_wb0_fire);
    printf("[HUBSUM] Hub 相干应答那一段（全程，只累加）："
           "上行 C 被收下的拍数=%llu（其中走 backend 的脏释放=%llu）\n"
           "[HUBSUM]   **上行 D_RELEASE_ACK 脉冲=%llu（最后一次 cyc=%llu）**"
           " | 下游 A0(Hub→toAxi4 的 PUT) 脉冲=%llu（最后一次 cyc=%llu）"
           " | downD→setsBusy 脉冲=%llu\n"
           "[HUBSUM]   backend 占用拍数：stage0=%llu stage1=%llu stage2=%llu"
           " | probeAckDataCompleted(slot0)=%llu | rsp_lostIt 累计=%llu\n",
           (unsigned long long)c_hub_inv, (unsigned long long)c_hub_hitb,
           (unsigned long long)c_hub_upd, (unsigned long long)last_hub_upd,
           (unsigned long long)c_hub_ain0, (unsigned long long)last_hub_ain0,
           (unsigned long long)c_setbusy,
           (unsigned long long)c_b0_occ, (unsigned long long)c_b1_occ, (unsigned long long)c_b2_occ,
           (unsigned long long)c_ps0_ack, (unsigned long long)c_hub_rsp_lost);
    printf("[HubAck] ★T32 脏释放上行应答三道口（全程累加）：downD_toUp.upD_valid 拍数=%llu（最后 cyc=%llu）"
           " | 其中 op=RELEASE_ACK 的=%llu\n"
           "[HubAck]   **valid=1 但 hub_io_up_d_valid=0（卡在仲裁/出口）=%llu 拍（最后 cyc=%llu）**"
           " | valid=1 但 hit=0（decodeCtx 判非 fromC 或 isProbeData ⇒ **静默吞掉**）=%llu | fired 拍数=%llu\n",
           (unsigned long long)c_ack_v, (unsigned long long)last_ack_v,
           (unsigned long long)c_ack_ra,
           (unsigned long long)c_ack_stuckbeforeio, (unsigned long long)last_ack_stuck,
           (unsigned long long)c_ack_nohit, (unsigned long long)c_ack_fire);
    printf("[HubAck] ★T32 跳一：slots_release_valid 拍数=%llu（最后 cyc=%llu）"
           " | 其中**释放了本就空的槽（多余释放）**=%llu 拍（最后 cyc=%llu，>0 ⇒ 走 B2：下游把 id 复用/错带）\n",
           (unsigned long long)c_rel_v, (unsigned long long)last_rel_v,
           (unsigned long long)c_rel_spur, (unsigned long long)last_rel_spur);
    printf("[HubAck] ★T32 跳二：slots_allocate 拍数=%llu（C=%llu W=%llu R=%llu，最后 cyc=%llu）"
           " | 其中**下一拍 valids 没落地**=%llu 拍（最后 cyc=%llu，>0 ⇒ 分配被丢掉）\n",
           (unsigned long long)c_alloc, (unsigned long long)c_alloc_c,
           (unsigned long long)c_alloc_w, (unsigned long long)c_alloc_r,
           (unsigned long long)last_alloc,
           (unsigned long long)c_alloc_stickfail, (unsigned long long)last_stickfail);
    printf("[BRSUM] Axi4Bridge(胶合块之前) 全程台账：A 通道握手=%llu（最后一次 cyc=%llu addr=%08llX）"
           " | 其中 op=PUT_FULL/PARTIAL 的 %llu 笔（最后一次 cyc=%llu addr=%08llX）"
           " | D 通道握手=%llu（最后一次 cyc=%llu）\n"
           "[BRSUM]   cmdV2 期间 op=PUT 的拍数=%llu | 两笔丢失地址(0x800270C0/0x80025040)在 A 命令上出现的拍数=%llu"
           " | a_ctxFull 为 1 的拍数=%llu（最后一次 cyc=%llu）\n",
           (unsigned long long)c_m_aw, (unsigned long long)last_m_aw,
           (unsigned long long)last_m_aw_a & 0xFFFFFFFFull,
           (unsigned long long)c_t_uaput, (unsigned long long)last_t_uaput,
           (unsigned long long)last_t_uaput_a & 0xFFFFFFFFull,
           (unsigned long long)c_m_b, (unsigned long long)last_m_b,
           (unsigned long long)c_t_acmd_put, (unsigned long long)c_t_watch,
           (unsigned long long)c_ctxfull, (unsigned long long)last_m_ctxfull);
    printf("[EXCEPTION] total exceptionPort.valid events = %llu (第一个的 code/epc 见上文 [EXCEPTION])\n",
           (unsigned long long)n_ex);
    // ================= ★ Step A：pBus 事务原文（最近 96 笔，含最后 5 笔）=================
    printf("[PBUS] 事务总数=%llu | 最后一次事务 cyc=%llu | 静默看门狗报告 %llu 次\n",
           (unsigned long long)n_pbus_ev, (unsigned long long)last_pbus_cyc,
           (unsigned long long)n_pbus_stall_report);
    printf("--- pBus 最近事务（旧→新；* = 最后 5 笔）---\n");
    for (size_t i = 0; i < pbus_ring.size(); i++)
        printf("  %c cyc=%-8llu %s\n",
               (pbus_ring.size() - i <= 5) ? '*' : ' ',
               (unsigned long long)pbus_ring[i].cyc, pbus_ring[i].txt);
    // ---- 核侧 uncache 请求原文（核自己算出来的地址，最后 40 笔）----
    printf("[CORE-PBUS-A] 核侧 uncache 请求总数=%llu\n", (unsigned long long)n_corereq);
    for (size_t i = 0; i < core_ring.size(); i++)
        printf("  %c cyc=%-8llu op=0x%X addr=0x%08llX\n",
               (core_ring.size() - i <= 5) ? '*' : ' ',
               (unsigned long long)core_ring[i].cyc, core_ring[i].op,
               (unsigned long long)core_ring[i].addr & 0xFFFFFFFFull);
    printf("[CONSOLE] wr_exec=%llu (含 4 笔配置写) | thr_writes=%llu last_THR=0x%02X | "
           "reads=%llu (被 CPU 取走 %llu) THRE=1 的读 %llu / THRE=0 的读 %llu\n",
           (unsigned long long)n_con_wr, (unsigned long long)n_thr_wr, (unsigned)last_thr_byte,
           (unsigned long long)n_con_rd, (unsigned long long)n_rd_ack,
           (unsigned long long)n_rd_thre1, (unsigned long long)n_rd_thre0);
    printf("[CONSOLE] final: txDataReg=0x%02X txPend=%u threPending=%u rxHave=%u "
           "awReady=%u wReady=%u rValid=%u rData=0x%08X | TX fsm_state=%u fsm_pend=%u fsm_data=0x%02X "
           "| glue rSel=%u wSel=%u | last_rd_cyc=%llu last_wr_cyc=%llu\n",
           (unsigned)(uint8_t)C_TXDATA, (unsigned)C_PEND, (unsigned)C_THRE,
           (unsigned)C_RXHAVE, (unsigned)C_AWR, (unsigned)C_WWR, (unsigned)C_RV, (uint32_t)C_RD,
           (unsigned)C_TXST, (unsigned)C_TXPND, (unsigned)(uint8_t)C_TXDN,
           (unsigned)G_RSEL, (unsigned)G_WSEL,
           (unsigned long long)last_rd_cyc, (unsigned long long)last_wr_cyc);
    // ★ Task 24 ③：[BTBL] 收尾汇总（谁教了 BTB / btb 自指从第几拍开始）
    if (TB_BTB)
        printf("[BTBL] 汇总: learn 脉冲=%llu | BTB entry 写入=%llu（其中涉及观测点/别名 idx 的 %llu）| "
               "btb 自指跳转瞬时=%llu 首次 cyc=%llu | 连续≥1000 拍的段=%llu 首段 cyc=%llu\n",
               (unsigned long long)n_ln_all, (unsigned long long)n_btb_wr,
               (unsigned long long)n_btb_wr_watch,
               (unsigned long long)n_self_btb, (unsigned long long)first_self_btb,
               (unsigned long long)n_long_runs, (unsigned long long)self_run_first);
    // ================= ★ M2-b Gate 2 第五轮：提交 PC / 取指 PC 直方图收尾（TB_PCHIST=1）=========
    if (PC_HIST) {
        auto dump_top = [](const char* tag, std::map<uint32_t, uint64_t>& h, uint64_t total, int topn) {
            std::vector<std::pair<uint64_t, uint32_t>> v;      // (次数, pc)
            for (std::map<uint32_t, uint64_t>::iterator it = h.begin(); it != h.end(); ++it)
                v.push_back(std::make_pair(it->second, it->first));
            std::sort(v.begin(), v.end(),
                      [](const std::pair<uint64_t, uint32_t>& a, const std::pair<uint64_t, uint32_t>& b) {
                          if (a.first != b.first) return a.first > b.first;
                          return a.second < b.second;
                      });
            printf("[PCHIST] %s：去重 PC=%zu | 总次数=%llu\n", tag, h.size(), (unsigned long long)total);
            const int n = ((int)v.size() < topn) ? (int)v.size() : topn;
            for (int i = 0; i < n; i++)
                printf("[PCHIST]   #%02d pc=0x%08X n=%llu (%.4f%%)\n", i + 1, v[i].second,
                       (unsigned long long)v[i].first,
                       total ? (100.0 * (double)v[i].first / (double)total) : 0.0);
        };
        dump_top("窗口内**提交 PC** top20", h_commit, n_commit_win, 20);
        dump_top("窗口内**前端取指 PC**(serialized) top20", h_fetch, n_fetch_win, 20);
        printf("[PCHIST] 窗口 [%ld,%ld]：提交事件=%llu（commit_mask 取值 00=%llu 01=%llu 10=%llu 11=%llu）"
               " | 取指采样=%llu | ptr_commit 推进 0/1/2 拍的拍数=%llu/%llu/%llu 其它=%llu\n",
               pc_from, pc_to,
               (unsigned long long)n_commit_win,
               (unsigned long long)cm_hist[0], (unsigned long long)cm_hist[1],
               (unsigned long long)cm_hist[2], (unsigned long long)cm_hist[3],
               (unsigned long long)n_fetch_win,
               (unsigned long long)n_rob_delta[0], (unsigned long long)n_rob_delta[1],
               (unsigned long long)n_rob_delta[2], (unsigned long long)rob_delta_other);
        printf("[PCKERN] **提交 PC ≥ 0x82000000**：any=%d 首个=(cyc=%llu,pc=0x%08X) 共 %llu 条"
               " || 前端**取指 PC** ≥ 0x82000000：any=%d 首个=(cyc=%llu,pc=0x%08X) 共 %llu 条\n",
               (int)(n_kern_commit != 0), (unsigned long long)first_kern_commit_cyc,
               first_kern_commit_pc, (unsigned long long)n_kern_commit,
               (int)(n_kern_fetch != 0), (unsigned long long)first_kern_fetch_cyc,
               first_kern_fetch_pc, (unsigned long long)n_kern_fetch);
        printf("[PCKERN] 全程（0..%llu 拍）提交条数=%llu | 第一条=(cyc=%llu,pc=0x%08X,rob=%02u)"
               " | 最后一条=(cyc=%llu,pc=0x%08X,rob=%02u) | maxCommitPC=0x%08X maxFetchPC=0x%08X\n",
               (unsigned long long)cyc, (unsigned long long)n_commit_all,
               (unsigned long long)first_commit_cyc, first_commit_pc, (unsigned)first_commit_rob,
               (unsigned long long)last_commit_cyc, last_commit_pc, (unsigned)last_commit_rob,
               max_commit_pc, max_fetch_pc);
        // ---- 停点是"重复同一小段"还是"缓慢推进"：相邻变化次数 + 游程（run-length）----
        if (!commit_seq.empty()) {
            uint64_t n_chg = 0;
            for (size_t i = 1; i < commit_seq.size(); i++)
                if (commit_seq[i] != commit_seq[i - 1]) n_chg++;
            printf("[PCTRACE] 窗口提交序列长度=%zu | **相邻 PC 变化次数=%llu**（变化占比=%.4f%%）"
                   " | 首=0x%08X 末=0x%08X\n",
                   commit_seq.size(), (unsigned long long)n_chg,
                   commit_seq.size() ? (100.0 * (double)n_chg / (double)commit_seq.size()) : 0.0,
                   commit_seq.front(), commit_seq.back());
            // 游程 top20（"在 A、B、C 三点间循环" 会直接看成一串长游程）
            std::vector<std::pair<uint64_t, uint32_t>> runs;      // (长度, pc)
            {
                size_t i = 0;
                while (i < commit_seq.size()) {
                    size_t j = i;
                    while (j < commit_seq.size() && commit_seq[j] == commit_seq[i]) j++;
                    runs.push_back(std::make_pair((uint64_t)(j - i), commit_seq[i]));
                    i = j;
                }
            }
            std::sort(runs.begin(), runs.end(),
                      [](const std::pair<uint64_t, uint32_t>& a, const std::pair<uint64_t, uint32_t>& b) {
                          if (a.first != b.first) return a.first > b.first;
                          return a.second < b.second;
                      });
            printf("[PCTRACE] 游程段数=%zu | 最长游程 top10：", runs.size());
            for (size_t i = 0; i < runs.size() && i < 10; i++)
                printf(" 0x%08X×%llu", runs[i].second, (unsigned long long)runs[i].first);
            printf("\n");
            // 头 40 / 尾 60 条（按提交顺序；用于看"是不是在 A/B/C 之间循环"）
            printf("[PCTRACE] 窗口**最早** 40 条提交 PC（提交顺序）:\n  ");
            for (size_t i = 0; i < commit_seq.size() && i < 40; i++)
                printf(" %08X", commit_seq[i]);
            printf("\n[PCTRACE] 窗口**最后** 60 条提交 PC（提交顺序）:\n  ");
            const size_t from = (commit_seq.size() > 60) ? (commit_seq.size() - 60) : 0;
            for (size_t i = from; i < commit_seq.size(); i++)
                printf(" %08X", commit_seq[i]);
            printf("\n");
        } else {
            printf("[PCTRACE] 窗口内**一条提交都没有**（commit_mask 全程为 0）⇒ 停点在窗口之前就发生了\n");
        }
    }
    // ================= ★ M2-b Gate 2 第六轮收尾：真 trap 直方图 + 串口原始字节（默认关）==========
    if (TRAP_OBS) {
        printf("[TRAPS] 窗口 [%ld,%ld]：rValid 抬升=%llu 次 | 三元组去重事件=%llu 次 | 窗口内事件=%llu"
               "（其中 tval≠0 的 %llu 次）\n",
               trap_from, trap_to,
               (unsigned long long)n_trap_rvalid_rise, (unsigned long long)n_trap_evt,
               (unsigned long long)n_trap_win, (unsigned long long)ex_tval_nonzero);
        printf("[TRAPS] 窗口内 **mcause 直方图**（按事件计）：");
        for (int i = 0; i < 16; i++) if (h_trap_cause[i]) printf(" cause=%d:%llu", i, (unsigned long long)h_trap_cause[i]);
        printf("\n[TRAPS] 同上按 tval 是否为 0 分开：tval==0 →");
        for (int i = 0; i < 16; i++) if (h_trap_tup[0][i]) printf(" cause=%d:%llu", i, (unsigned long long)h_trap_tup[0][i]);
        printf("\n[TRAPS]   tval!=0 →");
        for (int i = 0; i < 16; i++) if (h_trap_tup[1][i]) printf(" cause=%d:%llu", i, (unsigned long long)h_trap_tup[1][i]);
        printf("\n");
        {
            std::vector<std::pair<uint64_t, std::string>> v;
            for (std::map<std::string, uint64_t>::iterator it = h_trap_triple.begin();
                 it != h_trap_triple.end(); ++it)
                v.push_back(std::make_pair(it->second, it->first));
            std::sort(v.begin(), v.end(),
                      [](const std::pair<uint64_t, std::string>& a,
                         const std::pair<uint64_t, std::string>& b) {
                          if (a.first != b.first) return a.first > b.first;
                          return a.second < b.second;
                      });
            printf("[TRAPS] 窗口内 **(cause,epc,tval) 去重 top%zu**（按次数降序）：\n",
                   v.size() > 12 ? (size_t)12 : v.size());
            for (size_t i = 0; i < v.size() && i < 12; i++)
                printf("[TRAPS]   #%02zu n=%llu  %s\n", i + 1, (unsigned long long)v[i].first,
                       v[i].second.c_str());
        }
        // 事件时间线：前 12 条 +（若 ≤40 条则全给）⇒ 看"反复"的周期
        printf("[TRAPS] 事件序列（前 %zu 条，cyc 递增）：\n",
               trap_evts.size() > 12 ? (size_t)12 : trap_evts.size());
        for (size_t i = 0; i < trap_evts.size() && i < 12; i++)
            printf("[TRAPS]   %02zu cyc=%llu cause=%u epc=0x%08llX tval=0x%08llX\n",
                   i + 1, (unsigned long long)trap_evts[i].cyc, (unsigned)trap_evts[i].cause,
                   (unsigned long long)trap_evts[i].epc, (unsigned long long)trap_evts[i].tval);
        // 相邻事件间隔（看是否等间隔循环）
        if (trap_evts.size() >= 3) {
            std::vector<uint64_t> gaps;
            for (size_t i = 1; i < trap_evts.size(); i++)
                gaps.push_back(trap_evts[i].cyc - trap_evts[i - 1].cyc);
            std::sort(gaps.begin(), gaps.end());
            printf("[TRAPS] 相邻事件间隔：min=%llu median=%llu max=%llu（去重后 %zu 种）\n",
                   (unsigned long long)gaps.front(),
                   (unsigned long long)gaps[gaps.size() / 2],
                   (unsigned long long)gaps.back(), gaps.size());
        }
        // ---- 兜底：**全程**（窗口无关）直方图 + 最后 32 次事件 ----
        printf("[TRAPALL] 全程：首个事件 cyc=%llu | 事件总数=%llu\n",
               (unsigned long long)first_trap_cyc, (unsigned long long)n_trap_evt);
        printf("[TRAPALL] 全程 mcause 直方图（按事件计）：");
        for (int i = 0; i < 16; i++)
            if (h_trap_cause_all[i]) printf(" cause=%d:%llu", i, (unsigned long long)h_trap_cause_all[i]);
        printf("\n");
        {
            std::vector<std::pair<uint64_t, std::string>> v;
            for (std::map<std::string, uint64_t>::iterator it = h_trap_triple_all.begin();
                 it != h_trap_triple_all.end(); ++it)
                v.push_back(std::make_pair(it->second, it->first));
            std::sort(v.begin(), v.end(),
                      [](const std::pair<uint64_t, std::string>& a,
                         const std::pair<uint64_t, std::string>& b) {
                          if (a.first != b.first) return a.first > b.first;
                          return a.second < b.second;
                      });
            printf("[TRAPALL] 全程 (cause,epc,tval) 去重 top%zu：\n",
                   v.size() > 12 ? (size_t)12 : v.size());
            for (size_t i = 0; i < v.size() && i < 12; i++)
                printf("[TRAPALL]   #%02zu n=%llu  %s\n", i + 1, (unsigned long long)v[i].first,
                       v[i].second.c_str());
        }
        printf("[TRAPALL] 全程**最后 %zu 次**事件（cyc 递增）：\n", trap_last.size());
        for (size_t i = 0; i < trap_last.size(); i++)
            printf("[TRAPALL]   cyc=%llu cause=%u epc=0x%08llX tval=0x%08llX\n",
                   (unsigned long long)trap_last[i].cyc, (unsigned)trap_last[i].cause,
                   (unsigned long long)trap_last[i].epc, (unsigned long long)trap_last[i].tval);
    }
    if (CONRAW) {
        auto dump_raw = [&](const char* tag, const std::vector<uint8_t>& v, uint64_t total) {
            printf("[CONRAW] %s：总字节=%llu | 记录=%zu（本 dump 给最后 %zu 个）\n",
                   tag, (unsigned long long)total, v.size(), CONRAW_KEEP);
            const size_t from = (v.size() > CONRAW_KEEP) ? (v.size() - CONRAW_KEEP) : 0;
            printf("[CONRAW] %s hex:", tag);
            for (size_t i = from; i < v.size(); i++) printf(" %02X", v[i]);
            printf("\n[CONRAW] %s text:", tag);
            for (size_t i = from; i < v.size(); i++) {
                uint8_t b = v[i];
                if (b == '\n') printf("\\n");
                else if (b == '\r') printf("\\r");
                else if (b >= 0x20 && b < 0x7F) printf("%c", (char)b);
                else printf("\\x%02X", b);
            }
            printf("\n[CONRAW] %s 末 24 字符（每行一条，便于对 `: init fai`）：\n", tag);
            const size_t from24 = (v.size() > 24) ? (v.size() - 24) : 0;
            for (size_t i = from24; i < v.size(); i++)
                printf("[CONRAW]   #%zu = 0x%02X '%c'\n", i, v[i],
                       (v[i] >= 0x20 && v[i] < 0x7F) ? (char)v[i] : '.');
        };
        dump_raw("线上(UART TXD)解出的字节", raw_wire, n_raw_wire);
        dump_raw("写进 THR 的字节", raw_thr, n_raw_thr);
        printf("[CONRAW] 线上 vs THR：线上=%llu THR 写=%llu 差=%lld | 最后线上字节 cyc=%ld\n",
               (unsigned long long)n_raw_wire, (unsigned long long)n_raw_thr,
               (long long)n_raw_thr - (long long)n_raw_wire, last_uart_cyc);
    }
#endif  // TB_PEEK_CODE
    printf("pin[0..7] @0x80000000 (probe image intact): "
           "0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X\n",
           mem[0], mem[1], mem[2], mem[3], mem[4], mem[5], mem[6], mem[7]);

#ifdef TB_PEEK_CODE
    if (PEEK) {
        // I$ way0 行存储（22bit/项 = 2 字节 + tag/valid）：看线上取回的 2 字节半字是否与镜像逐字节一致
        auto& W0 = dut->rootp->nax_mini_soc->u_soc->naxes_0_thread_core
                        ->__PVT__FetchCachePlugin_logic_ways_0_mem__DOT__ram_block;
        printf("--- I$ way0 ram_block (64 x 22bit): raw | low16 ---\n");
        for (int i = 0; i < 64; i++)
            printf("  I$[%02d]=0x%06X low16=0x%04X\n", i, (unsigned)W0[i],
                   (unsigned)(W0[i] & 0xFFFF));
    }

    if (PEEK) {
        size_t n = pc_ring.size();
        printf("--- PC ring tail (%zu samples kept; frontend fetch_PC / ALU0 exec_PC) ---\n", n);
        size_t from = (n > 40) ? (n - 40) : 0;
        for (size_t i = from; i < n; i++)
            printf("  cyc=%8llu fetchPC=0x%08llX alu0PC=0x%08llX alu0_v=%d\n",
                   (unsigned long long)pc_ring[i].cyc,
                   (unsigned long long)pc_ring[i].fpc & 0xFFFFFFFFull,
                   (unsigned long long)pc_ring[i].apc & 0xFFFFFFFFull, pc_ring[i].av);
    }
#endif  // TB_PEEK_CODE

    if (pass) {
        printf("TEST PASSED criterion=%s frames=%d cyc=%llu text_ok=%d frames_ok=%d framing_ok=%d wave_ok=%d "
               "bid_hist_ok=%d | %s\n",
               expect_sub ? expect_sub : "NAXMINI\\n",
               dec.frames, (unsigned long long)cyc,
               (int)text_ok, (int)frames_ok, (int)framing_ok, (int)wave_ok,
               (int)bid_hist_ok, pass_reason);
    } else {
        printf("FAIL: timeout cyc=%llu frames=%d console=\"%s\" stop_errors=%d wave_ok=%d"
               " (text_ok=%d frames_ok=%d bid_hist_ok=%d)%s%s%s\n",
               (unsigned long long)cyc, dec.frames, dec.text.c_str(), dec.stop_errors,
               (int)wave_ok, (int)text_ok, (int)frames_ok, (int)bid_hist_ok,
               text_ok ? "" : " (text mismatch)",
               frames_ok ? "" : " (frame count mismatch)",
               bid_hist_ok ? "" : " (B channel id histogram mismatch ⇒ 从方没回带 awid)");
    }

    delete dut;
    return pass ? 0 : 1;
}
