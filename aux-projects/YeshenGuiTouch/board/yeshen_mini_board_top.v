// ============================================================================
// yeshen_mini_board_top —— 盘古100K200K MINI（PG2L200H / FBB676 / speedgrade -6）板级顶层
//
// 结构（spec §4.1）：PLL + yeshen_mini_soc（= VexiiRiscv + YeshenSocGlue）+ DDR3Bridge + 紫光 DDR3 IP
//
//   clk_in 27MHz ─► pll_100m_125m ─► soc_clk 100MHz ─► yeshen_mini_soc.soc_clk
//                                                   └► DDR3Bridge.clock（AXI 从口侧）
//   ref_clk_p/n 125MHz ─► GTP_INBUFGDS ─► u_ddr3.ref_clk
//   ref_clk_p/n 125MHz ─► u_ddr3 ─► core_clk 125MHz ─► DDR3Bridge.io_ddr_clk
//   yeshen_mini_soc.mem_*（64bit AXI4 主）─► DDR3Bridge.io_axi_*（64bit 从）
//   DDR3Bridge.io_ddr*（256bit 简化 AXI 主）─► u_ddr_arb 桥侧 b_*
//   视频帧存 video_passthrough.ddr_*（256bit 简化 AXI 主）─► u_ddr_arb 视频侧 v_*
//   u_ddr_arb IP 侧 m_* ─► u_ddr3 的 axi_* 用户口（★ V1 起：用户口由仲裁器独占）
//
// 端口名与 `constraints/yeshen_mini.fdc` **逐字对齐**（V1 起 **142 个端口 / 142 条 PAP_IO_LOC**
//   = 原 99（P1 的 86 + 以太网 PHY0 的 13）+ 相机 14 + LCD 29；脚本实测两侧集合完全相等）：
//   clk_in / rst_board_n / key1 / uart_txd / uart_rxd / led[3:0] /
//   sd_sck / sd_mosi / sd_cs_n / sd_miso / ref_clk_p / ref_clk_n / mem_*（71）/
//   camera_clk_0 / camera_data_0[7:0] / camera_href_0 / camera_vsync_0 / SCL_0 / SDA_0 /
//   cam_rst_0 / lcd_r[7:0] / lcd_g[7:0] / lcd_b[7:0] / lcd_de / lcd_hs / lcd_vs / lcd_pclk / lcd_pwm
//   ⇒ 对账依据：把 fdc 里未注释的 PAP_IO_LOC 全抽出来排序，与 `sed -n '/^module/,/^);/p'`
//     的本文件端口表逐条比对（dev_map 会以 "对象找不到" 的形式兜底）。
//
// ★ V1 新增硬件链（Task 7）：`video_passthrough u_video`（相机→裁列→帧存→LCD→overlay）
//   + `ddr_arbiter_2to1 u_ddr_arb`（DDR3Bridge 与视频帧存 2:1 共享 256bit 简化 AXI）
//   + `video_regs u_video_regs`（VIDEO CSR 窗 0xF000_7400，经 u_soc 的 video_* 从口）
//   + `pll_lcd u_pll_lcd`（27MHz → 51.923MHz 像素钟，经 GTP_CLKBUFG 进 lcd_clk）。
//   约束段见 fdc 的【V1 相机/LCD】与【V1 lcd_clk/cam_pixel_clk】两段。
//
// ---------------------------------------------------------------------------
// 【1】★ DDR 侧的 125MHz 域时钟取 **DDR3 IP 自己的 core_clk 输出**，不是 PLL 的第二路输出
//
//   依据（逐条）：
//   (a) **IP 的用户口（axi_awvalid/wdata/rvalid…）是 IP 内部 core_clk 域同步的**，我们这侧的
//       驱动/采样必须与**同一个** core_clk 同步。用板级 PLL 另出的 125MHz（与 ref_clk 那颗
//       125MHz 振荡器**不同源**，频率差最多 ±100ppm）去采样 IP 用户口，等于在 IP 用户口上做
//       **跨异步域采样**：IP 的 R 通道没有 rready（一拍收不下就丢，见 DDR3Bridge.scala 文件头
//       约束 1/4），一次亚稳采样就是丢一个 256bit beat ⇒ 板上表现为"偶尔挂死"。
//   (b) **官方 200H 4_10 demo（本板唯一硬件验证过的同族工程）就是这么接的**：
//       `HDMI_IN_DDR3_HDMI_OUT_top.v:294` `.core_clk(core_clk)` + `:164`
//       `.ddr_clk(core_clk)`（DDR 侧用户逻辑跑在 IP 输出上），其 fdc 把该时钟约束为
//       `create_generated_clock -name {ddrphy_sysclk} … ddrphy_gpll/clkout0`。
//   (c) **YeshenCore/NaxYeshenSoC 的 `soc_ddr_top.v` / `nax_board_top.v` 同样是
//       `.io_ddr_clk(core_clk)`**（core_clk = `ddr3_test` 的输出）—— 本任务书要求"沿用既有实践"。
//   ⇒ 故 fdc 里那个 125MHz 域叫 **core_clk**，且它是 `create_generated_clock`（由 ref_clk 派生），
//   不是板级 PLL 的 `create_clock`。
//
//   `pll_100m_125m` 仍按 plan Task 14 Step 3 出第二路 125MHz（`clkout1`），但**板上不接**
//   （P2/P3 若需要一个与 DDR 无关的 125MHz 时才有用；接上去就会与 (a) 冲突）。
//
// 【2】★ 125MHz 差分参考时钟走显式 `GTP_INBUFGDS`
//   官方 4_10 demo（`GTP_INBUFGDS #(.IOSTANDARD("DEFAULT"), .TERM_DIFF("ON"))`，L277-284）与
//   DDR3 IP example_design（`test_ddr.v:307-312` 的 `GTP_INBUFDS`）都显式插了差分输入缓冲，
//   再把单端结果接 `ddr3_test.ref_clk`。fdc 里 ref_clk_p/ref_clk_n 是 **HSTL15D_I（差分）**，
//   不插缓冲就会让 N2 成为"配了差分标准却悬空的输入脚"。本层照官方 4_10 写法。
//
// 【3】★ 复位链：`ddr_init_done && pll_lock_100m` 之后才放 SoC（= `soc_ddr_top.v` 既有实践）
//   · `u_ddr3.resetn` 直接吃**原始按键** `rst_board_n`（C22/KEY0，低有效）—— 与既有
//     `soc_ddr_top.v` 的 `.resetn(rst_board)` 同构（实测官方 4_10 用 `if (~rst_in)` ⇒ 低有效）。
//   · `soc_resetn` 是 soc_clk 域的两级同步器输出：`ddr_init_done && pll_lock_100m` 之前恒 0
//     （异步置位由"寄存器上电为 0"天然满足），之后跟随按钮（1 = 运行）。
//     ⚠️ 这里的 lock 是**板级 PLL 的** lock（`pll_lock_100m`），不是 `ddr3_test.pll_lock`
//        那个**输出** —— 两者同名不同源，**不能接成同一根 wire**（PDS 会报
//        `DRC-1021: Net ... has multiple drivers`；实测踩过一次）。
//   · `yeshen_mini_soc.async_reset` 是**异步高有效**（见其文件头★复位语义），故取 `~soc_resetn`。
//   · `DDR3Bridge.reset` 是 Chisel 隐式复位（**高有效**），同取 `~soc_resetn`；桥内部对 CDC 的
//     低有效端已做取反（DDR3Bridge.scala 约束 5），板级不必再管。
//
// 【4】装载 strap：`key1`（C23/KEY1，上电默认高）直接进 `u_soc.load_mode`。
//   口径与 YeshenCore 一致（`.io_loadMode(btn_key[0])`）：**未按下（高）= 装载模式**，
//   装载器当主人期间 CPU 被扣在复位（`u_soc.cpu_reset` 在 yeshen_mini_soc 内部 OR 进核复位）。
//
// 【5】GPIO：`gpio_in` 拉 0；**`gpio_out[7:0]` 接板载 8 只 LED**（2026-10-23，见 led_diag_spec.md）；
//   `gpio_dir` 只接到内部线（LED 直驱不看方向）。`tracer_valid/tracer_payload`（template 的
//   CsrTracer；VexiiRiscv 无此口 ⇒ 本层恒 0）不引到引脚。
//
// 【6】★ N2 / N2b / N5b / T-18c：`npu_clk` 时钟源（**现值 56.250MHz**；N2b–t18b 期为 50.000MHz）
//   · **N2b 起：来源 = 第二颗独立 PLL**（`board/pll_50m.v`，一颗独立的 `GTP_GPLL`，VCO=675MHz、
//     RATIO0=13.5 ⇒ clkout0 = 精确 50.000000MHz）→ `GTP_CLKBUFG` → SoC 的 `npu_clk` 端口。
//   · **★ T-18c（2026-10-16）：RATIO0 13.5 → 12.0 ⇒ clkout0 = 675/12 = 精确 56.250000MHz** ——
//     把板级真钟抬到 18.4 ns 约束档（请求 54.3478 ≤ 板钟 56.25 ≤ t18b 实测 56.2683）；本层其余
//     一字未动（完整算术与取值依据见 `board/pll_50m.v` 文件头【T-18c 追加】）。
//     ⇒ `npu_clk` 是**真独立时钟**（另一颗振荡器，与 `soc_clk` 无固定相位/频率关系），
//     fdc 用 **`create_clock`** 声明它（**不是** create_generated_clock）。
//   · **N2b 删掉了 N2 的回退**：N2（commit 3f5f791）为 `npu_clk` 走的是 `soc_clk ÷ 2`
//     （`npu_clk_div` 翻转触发器 + `create_generated_clock -divide_by 2`）—— 频率精确但**相位与
//     CPU 耦合**（恒 = CPU/2），不是真独立域。用户裁决**弃用**该回退，改为本文件的第二颗 PLL。
//     （N2 当时的理由 = "复用 u_pll.clkout1 做不出精确 50.000"：单 VCO 下 clkout1 只能整数分频
//      ⇒ VCO 必须 ≥1350MHz，越出 600~1200MHz 窗口，穷举 0 组解 —— 证明见 `pll_100m_125m.v`
//      文件头【N2 追加】段与 `constraints/yeshen_mini.fdc` 的 N2 段。N2b 的解法**不是**复用
//      clkout1，而是**再加一颗 GTP_GPLL**（独立 VCO）—— 那正是 N2 段里记录但未取的"备选②"。）
//   · **★ N5b：`NpuTop` 已整块搬进 `npu_clk`**（`u_soc.u_npu.clk = npu_clk`）。NPU 的三个对外接口
//     在 SoC 内（glue 边界）经三座异步桥跨到 `soc_clk`（见 `yeshen_mini_soc.v`【11】）⇒
//     `npu_clk` 现在有**真实的大功能负载**（NpuTop + 三座桥 npu 侧 + NpuResetSync npu 域）。
//   · **N2/N2b 的"活体"脚手架（`npu_clk_alive_r` + `npu_clk_alive` 端口 + 诊断帧的 `<npu>` 字节）
//     已全部删除** —— 这正是 N2b 文件头预告的 N5 收尾：`npu_clk` 有了真功能负载，不再需要
//     "喂活"来防综合/映射把第二颗 PLL+BUFG 当悬空（`Public-4060 … dangling`）整条清掉。
//     ⇒ 上电诊断帧**回到 8 字节**：`R D <ddr> P <pll> C <core> \n`（删掉了 `N <npu>` 两字节）。
//   · 板级顶层端口表与 `constraints/yeshen_mini.fdc` **一格未动**（`npu_clk_alive` 一直是 SoC 内部端口，
//     从未落到板级顶层/引脚）。
// ============================================================================

module yeshen_mini_board_top (
    // ---- 系统 ----
    input  wire        clk_in,          // 板载 27MHz 有源晶振（D18，官方 4_10 sys_clk）
    input  wire        rst_board_n,     // KEY0（C22），**低有效**原始按键
    input  wire        key1,            // KEY1（C23），装载 strap：高 = 装载模式（上电默认高）
    input  wire        key2,            // KEY2（B22），双目切换（低有效）
    input  wire        key3,            // KEY3（B20），相机返回兜底（低有效）

    // ---- GT911 CTP（J26 33..36）----
    input  wire        ctp_int,         // J26-33 AE21，低有效
    output wire        ctp_rst,         // J26-34 AD21，低有效
    inout  wire        ctp_scl,         // J26-35 AF22，开漏
    inout  wire        ctp_sda,         // J26-36 AE22，开漏

    // ---- 串口（控制台 ttyS0）----
    output wire        uart_txd,        // C24
    input  wire        uart_rxd,        // B24

    // ---- 板载 LED（fdc 只约束 led[0..3]；led[4..7] 在 fdc 里是注释段）----
    output wire [7:0]  led,

    // ---- TF 卡（SPI 模式；**J25** 3/4/5/6，固定 3.3V）----
    // 权威 = tf_test_200mini 的 TF-J25 段（该工程上板实测 TF-OK）；旧 J10 映射已更正
    output wire        sd_sck,          // J25-3  V14
    output wire        sd_mosi,         // J25-4  U14
    input  wire        sd_miso,         // J25-5  T18
    output wire        sd_cs_n,         // J25-6  T17

    // ---- 以太网 PHY0（RGMII；引脚=官方 mini-base 管脚映射表逐格）----
    input  wire        eth_rgmii_rxc,    // D19  PHY0_RXC
    input  wire        eth_rgmii_rx_ctl, // H16  PHY0_RXCTL
    input  wire [3:0]  eth_rgmii_rxd,    // B19/A19/E16/D16 = PHY0_RXD3..0
    output wire        eth_rgmii_txc,    // G16  PHY0_TXC
    output wire        eth_rgmii_tx_ctl, // D20  PHY0_TXCTL
    output wire [3:0]  eth_rgmii_txd,    // D21/C21/B21/E20 = PHY0_TXD3..0
    output wire        eth_phy_rstn,     // G25

    // ---- DDR3 125MHz 差分参考时钟（N3/N2，GCLK_125M_P/N）----
    input  wire        ref_clk_p,
    input  wire        ref_clk_n,

    // ========================================================================
    // ★ V1（2026-10-20）：摄像头 CAM0（双目模组的**上面那路**，落 J10）+ LCD 屏（J26）
    //   端口名与 `constraints/yeshen_mini.fdc` 里 `p:<name>` **逐字对齐**（FDC 侧是唯一权威）：
    //     相机 14 只：camera_clk_0 / camera_data_0[7:0] / camera_href_0 / camera_vsync_0 /
    //                 SCL_0 / SDA_0 / cam_rst_0   （VCCIO 3.3 / LVCMOS33）
    //     LCD 29 只 ：lcd_r[7:0] / lcd_g[7:0] / lcd_b[7:0] / lcd_de / lcd_hs / lcd_vs /
    //                 lcd_pclk / lcd_pwm           （VCCIO 3.3 / LVCMOS33）
    //   ⇒ 顶层端口数 99 → **142**（+ 相机 14 + LCD 29）。全部直连 `video_passthrough u_video`，
    //     本层不加任何 glue（相机引脚方向：data/clk/href/vsync = INPUT，SCCB/rst = OUTPUT）。
    //   ★ V1b（2026-10-27）：+ CAM1 14 只（camera_clk/data/href/vsync_1 + SCL_1/SDA_1/cam_rst_1）
    //     + KEY2 1 只（B22，双目切换；经 `key_toggle u_key2` 消抖后进 video_regs 的 CAM_CTRL）
    //     ⇒ 端口位 / fdc 的 PAP_IO_LOC 各 +15：**146 → 161**（上面那个 142 是 led[4..7] 扩成
    //     8 只**之前**的旧口径；2026-10-23 LED 段落地后实际已 146）。CAM1 同样顶层直连 u_video。
    // ========================================================================
    input  wire        camera_clk_0,    // L22  相机像素时钟（PCLK）
    input  wire [7:0]  camera_data_0,   // M24/R22/K26/K25/M25/N19/T24/R21  D7..D0
    input  wire        camera_href_0,   // T25  行有效
    input  wire        camera_vsync_0,  // L23  帧同步
    // ---- ★ V1b（2026-10-27）：双目第二路 CAM1（同一 J10 连接器；球号=参考工程实测）----
    input  wire        camera_clk_1,    // M21
    input  wire [7:0]  camera_data_1,   // M22/R23/T23/AB24/P26/M26/AA24/AB25  D7..D0
    input  wire        camera_href_1,   // U26
    input  wire        camera_vsync_1,  // U25
    output wire        SCL_1,           // AC24
    output wire        SDA_1,           // Y25
    output wire        cam_rst_1,       // AC26
    output wire        SCL_0,           // P19  SCCB 时钟
    output wire        SDA_0,           // R20  SCCB 数据
    output wire        cam_rst_0,       // T22  相机复位

    output wire [7:0]  lcd_r,           // AF23/AE23/AF25/AF24/AE26/AE25/W15/W14  R7..R0
    output wire [7:0]  lcd_g,           // AC16/AB16/AD17/AC17/AB20/AA20/AF17/AE17  G7..G0
    output wire [7:0]  lcd_b,           // AF18/AE18/AE20/AD20/AF20/AF19/AD24/AD23  B7..B0
    output wire        lcd_de,          // AC23
    output wire        lcd_hs,          // AD26  行同步（低有效）
    output wire        lcd_vs,          // AD25  帧同步（低有效）
    output wire        lcd_pclk,        // AC19  像素时钟（= ~lcd_clk，51.923MHz）
    output wire        lcd_pwm,         // AC22  背光（本版恒 1）

    // ---- DDR3 物理接口（71 脚，逐条对齐 constraints/yeshen_mini.fdc）----
    output wire        mem_cs_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm
);

    // ========================================================================
    // 时钟与复位
    // ========================================================================
    wire        soc_clk;            // PLL clkout0 = 100MHz（SoC + fabric + 外设 + 桥的 AXI 侧）
    wire        cpu_clk_raw;        // 第三颗板级 PLL（u_pll_cpu，pll_cpu）clkout0，未缓冲
    wire        cpu_clk;            // 过 u_cpuck_bufg 后的独立 CPU 时钟（100MHz 起步，可升 108MHz）
    wire        core_clk;           // DDR3 IP 输出 = 125MHz（桥的 DDR 侧；见文件头【1】）
    wire        pll_clk_125m_unused;// PLL clkout1 = 126.5625MHz（本版不接，见文件头【1】）
    wire        pll_lock_100m;      // **板级 PLL** 的 lock（复位链用它，见文件头【3】）
    wire        pll_lock_cpu;       // CPU 独立 PLL（u_pll_cpu）的 lock（复位链同条件）
    wire        ddr_init_done;      // DDR3 IP 的输出
    wire        ref_clk;            // GTP_INBUFGDS 之后的单端 125MHz → u_ddr3.ref_clk
    // ★ N2b/N5b（文件头【6】）：NPU 独立时钟 `npu_clk`（**L2a 认证档 54.000MHz**；T-18c 曾 56.25，已证伪）
    wire        npu_clk_raw;        // 第二颗板级 PLL（u_pll_npu，pll_50m）的 clkout0，未缓冲
    wire        npu_clk;            // 过 u_npuclk_bufg 后进 u_soc.npu_clk（N5b：NpuTop 整块跑它 + 三座桥 npu 侧）
    // ★ V1（Task 7）：LCD 像素钟（27MHz → 51.923MHz，第四颗板级 PLL `pll_lcd`）
    wire        lcd_pclk_raw;       // u_pll_lcd.clkout0，未缓冲
    wire        lcd_clk;            // 过 u_lcdclk_bufg 后进 u_video.lcd_clk（1024x600 扫描 + overlay 显示侧）
    wire        pll_lock_lcd;       // LCD PLL 的 lock（本层只作观测；复位链**不**依赖它，见下）
    // ★ 2026-10-23：GPIO 低位接 8 只板载 LED（语义见 y1/reports/led_diag_spec.md）
    wire [12:0] gpio_out;           // 0..7 LED；8 SCL；9 SDA；10 RST；11/12 输入位
    wire [12:0] gpio_dir;           // 0=输入 1=输出；CTP 的 SCL/SDA 为开漏
    wire [12:0] gpio_in;            // 8/9 CTP I2C 回读；11 INT；12 KEY3
    wire        ctp_irq;            // 反相后的 CTP_INT → PLIC 源 5
    reg         ctp_int_meta, ctp_int_sync;
    reg         key3_meta, key3_sync;
    always @(posedge soc_clk) begin
        ctp_int_meta <= ctp_int;
        ctp_int_sync <= ctp_int_meta;
        key3_meta    <= key3;
        key3_sync    <= key3_meta;
    end
    assign ctp_irq = ~ctp_int_sync;
    assign gpio_in[7:0]  = 8'h00;
    assign gpio_in[8]    = ctp_scl;
    assign gpio_in[9]    = ctp_sda;
    assign gpio_in[10]   = 1'b0;
    assign gpio_in[11]   = ctp_int_sync;
    assign gpio_in[12]   = key3_sync;
    // hw_test variant C (screen on J26) drove SCL push-pull and read GT911 at
    // 0x5D; the panel has no SCL pull-up, so a pure open-drain SCL never rises.
    // SDA keeps the open-drain behaviour (the panel pulls it up).
    assign ctp_scl = gpio_dir[8] ? gpio_out[8] : 1'bz;
    assign ctp_sda = (gpio_dir[9] && !gpio_out[9]) ? 1'b0 : 1'bz;
    assign ctp_rst = gpio_out[10];
    //
    // ⚠️ 板级 PLL 的 lock 与 DDR3 IP 的 `pll_lock` **输出**是两个不同的信号，必须分开命名：
    //    写成同一个 wire 会被 PDS 判 **DRC-1021: Net ... has multiple drivers**
    //    （实测踩过：`Net led[0] has multiple drivers`，两个驱动源就是
    //     `u_pll/u_gpll.LOCK` 与 `u_ddr3/…/N115.Z`）。`ddr3_test` 的 `pll_lock` 只是它内部
    //     PHY 的锁定指示，板级复位链**只用板级 PLL 的 lock**（口径同既有
    //    `soc_ddr_top.v` 的 `!ddr_init_done || !pll_lock_80m`），故那个输出**不接**。
    // 复位同步（soc_clk 域；口径照 YeshenCore/NaxYeshenSoC 的 soc_ddr_top.v）
    reg         rst_sync1, rst_sync2;
    reg         soc_resetn;         // 1 = 运行（SoC 已放行）
    always @(posedge soc_clk) begin
        if (!ddr_init_done || !pll_lock_100m || !pll_lock_cpu) begin
            rst_sync1  <= 1'b0;
            rst_sync2  <= 1'b0;
            soc_resetn <= 1'b0;
        end else begin
            rst_sync1  <= rst_board_n;
            rst_sync2  <= rst_sync1;
            soc_resetn <= rst_sync2;
        end
    end
    wire soc_async_reset = ~soc_resetn;   // 异步高有效（yeshen_mini_soc.async_reset 语义）

    // ========================================================================
    // ★ 2026-10-03：DDR3 IP 的 `resetn` 必须由 **POR 计数器**驱动，**不能直接接原始按键**
    // ========================================================================
    // 依据（与已知-good 配置对齐）：官方 4_10 与 YeshenCore/verilog_soc/soc_ddr_top.v L435-438 都是
    //     reg [15:0] ddr_por_cnt;
    //     always @(posedge free_clk) if (ddr_por_cnt != 16'h2710) ddr_por_cnt <= ddr_por_cnt + 1'b1;
    //     wire ddr_rstn = (ddr_por_cnt == 16'h2710) & rst_board;
    // 即让 DDR IP 在上电后**看到一个约 0.37ms@27MHz 的复位脉冲**（PHY 校准/内部状态机需要它）。
    // 我们原来写 `.resetn(rst_board_n)`：按键上电即高 ⇒ **等于没有复位脉冲** ⇒ 实测板上
    // `ddr_init_done` 恒 0（丝印 LED2 不亮）、SoC 被自己的复位门控扣住 ⇒ 串口 0 字节。
    // ⚠️ 只对齐这一条已知差异；DDR 的 71 个引脚已与"本板跑通过那版 FDC"逐格核对（71/71 一致）。
    reg  [15:0] ddr_por_cnt;
    always @(posedge clk_in)      // clk_in = 板载 27MHz（与参考实现的 free_clk 同源同频）
        if (ddr_por_cnt != 16'h2710) ddr_por_cnt <= ddr_por_cnt + 1'b1;
    wire ddr_rstn = (ddr_por_cnt == 16'h2710) & rst_board_n;   // 两者都"高=放开"

    // ============================================================================
    // ★ 2026-10-03 上板诊断件：**clk_in 域的读数**（SoC 被 `soc_resetn` 扣住时唯一能说话的出口）
    // ============================================================================
    // 背景：上板实测本设计 `ddr_init_done=0` ⇒ `soc_resetn=0` ⇒ glue（含控制台与两个加载器）
    //       **全在复位** ⇒ COM7 一个字都没有，只能靠 LED 推断（链条长：led[1]→C18→丝印 LED2→极性）。
    // 这里用 **`clk_in`（27MHz 板载晶振，不受 `soc_resetn` 影响）** 把三个关键状态直接打进
    // `uart_txd`：SoC 未放行时**夺线**，放行后让位给 SoC 的控制台。115200 8N1（234 拍/位 @27MHz）。
    //   ~55ms 一帧 **8** 字节：  R  D  <ddr>  P  <pll>  C  <core>  \n   (<> 里是 '0'/'1')
    //   · `<ddr>` = `ddr_init_done`（DDR IP 的 PHY 校准完成）
    //   · `<pll>` = `pll_lock_100m`（板级 PLL 锁定；它也是 `soc_resetn` 的另一半条件）
    //   · `<core>` = `core_clk`（DDR IP 输出 125MHz）**本帧周期内是否翻转过**
    //        ⇒ 用来把"ref_clk 没到 / PHY PLL 没锁（core 不动）"与"PHY 校准没完成（core 在动但 ddr=0）"分开
    //   ★ N5b：删掉了 N2 的 `<npu>` 字节（帧 **10 → 8** 字节）—— `npu_clk` 现在有真功能负载
    //     （NpuTop 整块跑它），不再需要"喂活"脚手架（完整理由见文件头【6】）。
    //   ⚠️ 这是**诊断件**：交付定稿时可删本块并把 `.uart_txd()` 直接接回 `uart_txd`（一行）。
    wire        soc_uart_txd;
    reg  [15:0] rp_baud;
    reg  [3:0]  rp_bit;
    reg  [9:0]  rp_sh;
    reg         rp_busy;
    reg  [20:0] rp_gap;
    reg  [20:0] rp_lim = 21'd2_000_000;   // 本字节发射前的等待上限：帧间长、字节间短
    reg  [2:0]  rp_byte;                  // ★ N5b：回到 3 bit（帧 8 字节，删掉了 N2 的 <npu> 字节）
    reg         rp_ck1, rp_ck2, rp_ck3, rp_ck_seen;
    reg  [7:0]  rp_data;
    always @(*) begin
        case (rp_byte)
            3'd0:    rp_data = "R";
            3'd1:    rp_data = "D";
            3'd2:    rp_data = 8'h30 + {7'b0, ddr_init_done};
            3'd3:    rp_data = "P";
            3'd4:    rp_data = 8'h30 + {7'b0, pll_lock_100m};
            3'd5:    rp_data = "C";
            3'd6:    rp_data = 8'h30 + {7'b0, rp_ck_seen};
            default: rp_data = 8'h0A;               // '\n'（= 第 7 字节）
        endcase
    end
    always @(posedge clk_in) begin
        rp_ck1 <= core_clk; rp_ck2 <= rp_ck1; rp_ck3 <= rp_ck2;   // 两级同步后看沿
        if (rp_ck3 != rp_ck2) rp_ck_seen <= 1'b1;
        if (rp_busy) begin
            if (rp_baud == 16'd233) begin              // 一位 = 234 拍 @27MHz ≈ 115200
                rp_baud <= 16'd0;
                if (rp_bit == 4'd9) begin              // 一字节发完（start + 8 data + stop）
                    rp_busy <= 1'b0; rp_bit <= 4'd0; rp_gap <= 21'd0;
                    if (rp_byte == 3'd7) begin         // 帧尾（N5b：9→7）⇒ 长间隔 + 清时钟观测
                        rp_byte <= 3'd0; rp_ck_seen <= 1'b0; rp_lim <= 21'd2_000_000;
                    end else begin                     // ⚠️ 必须回 idle 才装载下一字节（每字节都要重装 rp_sh）
                        rp_byte <= rp_byte + 3'd1;       rp_lim <= 21'd240;
                    end
                end else begin
                    rp_bit <= rp_bit + 4'd1;
                    rp_sh  <= {1'b0, rp_sh[9:1]};
                end
            end else rp_baud <= rp_baud + 16'd1;
        end else if (rp_gap >= rp_lim) begin           // 等够了就装载并开始本字节
            rp_gap  <= 21'd0;
            rp_sh   <= {1'b1, rp_data, 1'b0};          // stop | data | start（LSB 先出）
            rp_baud <= 16'd0; rp_bit <= 4'd0; rp_busy <= 1'b1;
        end else rp_gap <= rp_gap + 21'd1;
    end
    wire rp_txd = rp_busy ? rp_sh[0] : 1'b1;           // 空闲高
    // SoC 放行前由诊断件夺线：glue 在复位时它的 uart_txd 恒 0（线上是持续 break，一个字节都读不到）
    assign uart_txd = soc_resetn ? soc_uart_txd : rp_txd;

    // ============================================================================
    // PLL：27MHz → clkout0 100MHz（soc_clk）
    // ============================================================================
    // clkout1 按 plan Task 14 Step 3 保留；**本版不接**（理由见文件头【1】）。
    // ★ N2：clkout1 **也没有**被改去出 50MHz（算术上做不出精确 50.000，证明见文件头【6】）。
    pll_100m_125m u_pll (
        .clkout0 (soc_clk),
        .clkout1 (pll_clk_125m_unused),
        .clkin1  (clk_in),
        .lock    (pll_lock_100m)
    );

    // ============================================================================
    // CPU 独立时钟：27MHz → 第三颗 GTP_GPLL（pll_cpu）→ GTP_CLKBUFG → u_soc.cpu_clk
    //   VCO=1012.5MHz，RATIO0=10.125 ⇒ 100.000MHz（第一步与 soc_clk 同频，做功能等价）；
    //   第二步只把 RATIO0 改 9.375 / DUTY0 改 9 ⇒ 108.000MHz（SoC 仍 100MHz）。
    //   与 soc_clk 异步：fdc 里独立 create_clock + 异步组。
    // ============================================================================
    pll_cpu u_pll_cpu (
        .clkout0 (cpu_clk_raw),
        .clkin1  (clk_in),
        .lock    (pll_lock_cpu)
    );
    GTP_CLKBUFG u_cpuck_bufg (
        .CLKIN  (cpu_clk_raw),
        .CLKOUT (cpu_clk)
    );

    // ============================================================================
    // ★ N2b：`npu_clk` = 50.000MHz（**T-18c 起：56.250MHz**）—— **第二颗独立 PLL**（文件头【6】）
    //   第二颗 GTP_GPLL（`pll_50m`：VCO=675MHz、RATIO0=13.5 ⇒ 精确 50.000000MHz；
    //   **T-18c：RATIO0=12.0 ⇒ 675/12 = 精确 56.250000MHz**）
    //     → `GTP_CLKBUFG`（全局钟缓冲）→ u_soc.npu_clk。
    //   ⇒ 这是**独立钟**（另一颗振荡器、与 soc_clk 无固定关系）：fdc 里用
    //     `create_clock … -period 18.400` 声明（**不是** create_generated_clock；T-4 轮由 20.000 收紧），
    //     对象 = `u_pll_npu/u_gpll/CLKOUT0`（与 soc_clk 的 create_clock 落在 PLL 输出脚同姿）。
    //   ⚠️ 频率账见 `board/pll_50m.v` 文件头（PFD=27MHz ∈[10,450]、VCO=675MHz ∈[600,1200]，
    //      三处都在该 IP 的允许窗口内，`ui.tcl:pllCheck_adv`）。
    //   ⚠️ BUFG 必须显式例化：PDS 会在一根"由 PLL/触发器驱动、扇出到逻辑"的网上自动插 CLKBUFG，
    //      但**显式**插更可控，也让这条钟的缓冲有唯一确定的名字（照 liteeth_wrap 里
    //      `GTP_CLKBUFG_RXSHFT` 的既有实践）。
    // ============================================================================
    pll_50m u_pll_npu (
        .clkout0 (npu_clk_raw),
        .clkin1  (clk_in),
        .lock    ()                     // 本层不用它的 lock（与 N2 用 soc_resetn 无关；
                                        //  npu_clk 只喂"活体"脚手架，见文件头【6】）
    );
    GTP_CLKBUFG u_npuclk_bufg (
        .CLKIN  (npu_clk_raw),
        .CLKOUT (npu_clk)
    );

    // ============================================================================
    // ★ V1（Task 7）：LCD 像素时钟 = 第四颗板级 PLL（`board/pll_lcd.v`：27MHz → 51.923MHz）
    //   · 目的：1024x600@60 面板（H_TOTAL 1344 x V_TOTAL 635 x 60 ≈ 51.2MHz）的像素钟。
    //     厂家 cam2lcd_200mini 板级验收用的就是这颗数（VCO=1350MHz、RATIO0=26）。
    //   · 为什么要 GTP_CLKBUFG：与 npu_clk 同理由 —— PLL 输出必须过全局缓冲才进织内，
    //     显式例化让这条钟的缓冲有唯一确定的名字（fdc 的 `lcd_clk` 就建在 PLL 的输出脚上，
    //     BUFG 之后的同名网自动属于该时钟域）。
    //   · `lock` 只作观测（悬空不接任何逻辑）：**不**进 `soc_resetn` 的复位链 ——
    //     理由与既有实践一致：多一颗 PLL 就多一个 lock 条件会让"LCD 没接/没锁"反过来
    //     把 SoC 扣在复位（本板的 SoC 必须与屏是否插着无关）。`u_video.lcd_rstn` 取
    //     `soc_resetn`（见例化处），LCD 域因此与 SoC 同步放行。
    //   ⚠️ 时钟域关系：lcd_clk 与 soc_clk / cpu_clk / npu_clk / core_clk / clk_in **全部异步**
    //     （四颗互不同源的 PLL + DDR PHY 派生 + 板载晶振），fdc 的【V1】段逐条声明。
    // ============================================================================
    pll_lcd u_pll_lcd (
        .clkout0 (lcd_pclk_raw),
        .clkin1  (clk_in),
        .lock    (pll_lock_lcd)
    );
    GTP_CLKBUFG u_lcdclk_bufg (
        .CLKIN  (lcd_pclk_raw),
        .CLKOUT (lcd_clk)
    );

    // ========================================================================
    // 125MHz 差分参考时钟输入缓冲（照官方 4_10 demo；见文件头【2】）
    // ========================================================================
    GTP_INBUFGDS #(
        .IOSTANDARD ("DEFAULT"),
        .TERM_DIFF  ("ON")
    ) u_refclk_buf (
        .O  (ref_clk),
        .I  (ref_clk_p),
        .IB (ref_clk_n)
    );

    // ========================================================================
    // SoC：VexiiRiscv（黑盒核网表） + YeshenSocGlue 的组装层（board/yeshen_mini_soc.v）
    // ========================================================================
    // mem_* 是 **64bit AXI4 主口**（id 4bit），逐条对应 DDR3Bridge.io_axi_*（见下面例化的注释）
    wire        mem_ar_arvalid, mem_ar_arready;
    wire [3:0]  mem_ar_arid;
    wire [31:0] mem_ar_araddr;
    wire [7:0]  mem_ar_arlen;
    wire [2:0]  mem_ar_arsize;
    wire [1:0]  mem_ar_arburst;
    wire [2:0]  mem_ar_arlock;
    wire [3:0]  mem_ar_arcache;
    wire [2:0]  mem_ar_arprot;
    wire        mem_r_rvalid, mem_r_rready;
    wire [3:0]  mem_r_rid;
    wire [63:0] mem_r_rdata;
    wire [1:0]  mem_r_rresp;
    wire        mem_r_rlast;
    wire        mem_aw_awvalid, mem_aw_awready;
    wire [3:0]  mem_aw_awid;
    wire [31:0] mem_aw_awaddr;
    wire [7:0]  mem_aw_awlen;
    wire [2:0]  mem_aw_awsize;
    wire [1:0]  mem_aw_awburst;
    wire [1:0]  mem_aw_awlock;
    wire [3:0]  mem_aw_awcache;
    wire [2:0]  mem_aw_awprot;
    wire        mem_w_wvalid, mem_w_wready;
    wire [3:0]  mem_w_wid;
    wire [63:0] mem_w_wdata;
    wire [7:0]  mem_w_wstrb;
    wire        mem_w_wlast;
    wire        mem_b_bvalid, mem_b_bready;
    wire [3:0]  mem_b_bid;
    wire [1:0]  mem_b_bresp;

    wire        load_active;
    wire        cpu_reset;
    // ★ 2026-10-07：网口"PHY 的 RXC 在跳"指示（u_liteeth 内部 rgmii_clk 域引出）。
    //   **内部 wire，不落引脚** —— 只喂 led[3]，见文件末的 LED 段说明。
    wire        eth_rgmii_alive;

    // ========================================================================
    // ★ V1（Task 7）：VIDEO CSR 窗从口（u_soc.video_* ↔ video_regs.s_*）
    //   形态照 `u_soc.eth_*` 的既有写法：LiteEth / NPU / DMA 三个窗都是在板级顶层
    //   用同款 20 根 AxiLite 信号接一个"落地模块"，VIDEO 窗是第四个（Task 6 的胶合块解码）。
    //   命名 `u_soc_video_*` = "来自 u_soc 的 video 从口"，避免与视频数据通路的 v_* 混淆。
    // ========================================================================
    wire        u_soc_video_awvalid, u_soc_video_awready;
    wire [31:0] u_soc_video_awaddr;
    wire [2:0]  u_soc_video_awprot;
    wire        u_soc_video_wvalid, u_soc_video_wready;
    wire [31:0] u_soc_video_wdata;
    wire [3:0]  u_soc_video_wstrb;
    wire        u_soc_video_bvalid, u_soc_video_bready;
    wire [1:0]  u_soc_video_bresp;
    wire        u_soc_video_arvalid, u_soc_video_arready;
    wire [31:0] u_soc_video_araddr;
    wire [2:0]  u_soc_video_arprot;
    wire        u_soc_video_rvalid, u_soc_video_rready;
    wire [31:0] u_soc_video_rdata;
    wire [1:0]  u_soc_video_rresp;

    yeshen_mini_soc u_soc (
        .soc_clk     (soc_clk),
        .cpu_clk     (cpu_clk),
        .async_reset (soc_async_reset),

        // ---- ★ N2/N5b/T-18c：NPU 独立时钟（56.25MHz，T-18c 起）进 SoC（文件头【6】）----
        //   N5b：`npu_clk` 现在驱动 SoC 内整块 NpuTop + 三座桥的 npu 侧 + NpuResetSync 的 npu 域
        //   ⇒ 有真功能负载；`npu_clk_alive` 端口（"喂活"脚手架）已删。
        .npu_clk       (npu_clk),

        // ---- 内存主口（64bit AXI4）→ 直接引给下面 DDR3Bridge 的从口 ----
        .mem_ar_arid    (mem_ar_arid),
        .mem_ar_araddr  (mem_ar_araddr),
        .mem_ar_arlen   (mem_ar_arlen),
        .mem_ar_arsize  (mem_ar_arsize),
        .mem_ar_arburst (mem_ar_arburst),
        .mem_ar_arlock  (mem_ar_arlock),
        .mem_ar_arcache (mem_ar_arcache),
        .mem_ar_arprot  (mem_ar_arprot),
        .mem_ar_arvalid (mem_ar_arvalid),
        .mem_ar_arready (mem_ar_arready),
        .mem_r_rid      (mem_r_rid),
        .mem_r_rdata    (mem_r_rdata),
        .mem_r_rresp    (mem_r_rresp),
        .mem_r_rlast    (mem_r_rlast),
        .mem_r_rvalid   (mem_r_rvalid),
        .mem_r_rready   (mem_r_rready),
        .mem_aw_awid    (mem_aw_awid),
        .mem_aw_awaddr  (mem_aw_awaddr),
        .mem_aw_awlen   (mem_aw_awlen),
        .mem_aw_awsize  (mem_aw_awsize),
        .mem_aw_awburst (mem_aw_awburst),
        .mem_aw_awlock  (mem_aw_awlock),
        .mem_aw_awcache (mem_aw_awcache),
        .mem_aw_awprot  (mem_aw_awprot),
        .mem_aw_awvalid (mem_aw_awvalid),
        .mem_aw_awready (mem_aw_awready),
        .mem_w_wid      (mem_w_wid),
        .mem_w_wdata    (mem_w_wdata),
        .mem_w_wstrb    (mem_w_wstrb),
        .mem_w_wlast    (mem_w_wlast),
        .mem_w_wvalid   (mem_w_wvalid),
        .mem_w_wready   (mem_w_wready),
        .mem_b_bid      (mem_b_bid),
        .mem_b_bresp    (mem_b_bresp),
        .mem_b_bvalid   (mem_b_bvalid),
        .mem_b_bready   (mem_b_bready),

        // ---- 控制台 / GPIO ----
        .uart_txd   (soc_uart_txd),
        .uart_rxd   (uart_rxd),
        .gpio_in    (gpio_in),      // 8/9 CTP I2C；11 INT；12 KEY3
        .gpio_out   (gpio_out),     // 0..7 LED；8/9 SCL/SDA；10 RST
        .gpio_dir   (gpio_dir),
        .ctpIrq     (ctp_irq),      // PLIC 源 5（GT911）

        // ---- 装载链 ----
        .load_mode   (key1),        // 见文件头【4】
        .load_active (load_active),
        .sd_sck      (sd_sck),
        .sd_mosi     (sd_mosi),
        .sd_miso     (sd_miso),
        .sd_cs_n     (sd_cs_n),
        .cpu_reset   (cpu_reset),

        // ---- 以太网装载器：RGMII pads（观察量不引到引脚）----
        .eth_rgmii_rxc    (eth_rgmii_rxc),
        .eth_rgmii_rx_ctl (eth_rgmii_rx_ctl),
        .eth_rgmii_rxd    (eth_rgmii_rxd),
        .eth_rgmii_txc    (eth_rgmii_txc),
        .eth_rgmii_tx_ctl (eth_rgmii_tx_ctl),
        .eth_rgmii_txd    (eth_rgmii_txd),
        .eth_phy_rstn     (eth_phy_rstn),
        .eth_rgmii_alive  (eth_rgmii_alive),
        .eth_released     (),
        .eth_rx_bytes     (),
        .eth_wr_bytes     (),

        // ---- CsrTracer：不引到引脚（可悬空）----
        .tracer_valid   (),
        .tracer_payload (),

        // ---- ★ V1（Task 7）：VIDEO CSR 窗从口（glue.io_videoAxi_* 直通出来）----
        //   接收方是下面例化的 `video_regs u_video_regs`（1 KiB 窗，基址 0xF000_7400）。
        //   地址/数据都是 32 位（胶合块把窗内偏移放在低 10 位），故 s_awaddr/s_araddr 取 [11:0]。
        .video_awvalid (u_soc_video_awvalid),
        .video_awready (u_soc_video_awready),
        .video_awaddr  (u_soc_video_awaddr),
        .video_awprot  (u_soc_video_awprot),
        .video_wvalid  (u_soc_video_wvalid),
        .video_wready  (u_soc_video_wready),
        .video_wdata   (u_soc_video_wdata),
        .video_wstrb   (u_soc_video_wstrb),
        .video_bvalid  (u_soc_video_bvalid),
        .video_bready  (u_soc_video_bready),
        .video_bresp   (u_soc_video_bresp),
        .video_arvalid (u_soc_video_arvalid),
        .video_arready (u_soc_video_arready),
        .video_araddr  (u_soc_video_araddr),
        .video_arprot  (u_soc_video_arprot),
        .video_rvalid  (u_soc_video_rvalid),
        .video_rready  (u_soc_video_rready),
        .video_rdata   (u_soc_video_rdata),
        .video_rresp   (u_soc_video_rresp)
    );

    // ========================================================================
    // DDR3 IP 用户口线（网名与 u_ddr3 例化里的 axi_* 同名，便于与既有工程对照）
    // ⚠️ 必须在 DDR3Bridge 例化**之前**声明：Verilog 里未声明标识符出现在例化端口上会被
    //    隐式声明成 1bit wire，之后再写 [27:0] 的显式声明就是重复声明（编译期报错）。
    // ========================================================================
    wire [27:0]  ddr_axi_awaddr;
    wire [3:0]   ddr_axi_awlen;
    wire         ddr_axi_awvalid;
    wire         ddr_axi_awready;
    wire [255:0] ddr_axi_wdata;
    wire [31:0]  ddr_axi_wstrb;
    wire         ddr_axi_wready;
    wire [27:0]  ddr_axi_araddr;
    wire [3:0]   ddr_axi_arlen;
    wire         ddr_axi_arvalid;
    wire         ddr_axi_arready;
    wire [255:0] ddr_axi_rdata;
    wire         ddr_axi_rvalid;
    wire         ddr_axi_rlast;
    // ★ V1：桥侧"有写数据在手"的指示。DDR3Bridge 的简化 AXI **没有 WVALID 端口**
    //   （数据由内部 wCdc FIFO 常备、`io_ddrWReady` 高即采样，实读 rtl/DDR3Bridge.v:1830
    //    `wTake = io_ddrWReady & deq_valid & (|ipWrPend)`）。仲裁器对桥侧的授予条件写作
    //   `b_awvalid && b_wvalid`（防"没有数据也授予"），本层把 b_wvalid 接成**桥的 awvalid**：
    //   AW 一有效就授予，与"直连 IP"时的逐拍行为等价，且不会等一个永远不存在的 wvalid。
    wire         ddr_axi_wvalid;
    assign ddr_axi_wvalid = ddr_axi_awvalid;

    // ========================================================================
    // 内存桥：yeshen_mini_soc.mem_*（64bit AXI4 主）→ DDR3Bridge（64bit AXI4 从）
    // ========================================================================
    // 端口名逐字取自 `rtl/DDR3Bridge.v` 的模块头（`sed -n '/^module DDR3Bridge/,/^);/p'`）：
    //   io_axi_ar_arid/araddr/arlen/arsize/arburst/arlock(2bit)/arcache/arprot/arvalid/arready
    //   io_axi_r_rid/rdata(64)/rresp/rlast/rvalid/rready
    //   io_axi_aw_awid/awaddr/awlen/awsize/awburst/awlock(2bit)/awcache/awprot/awvalid/awready
    //   io_axi_w_wid/wdata(64)/wstrb(8)/wlast/wvalid/wready
    //   io_axi_b_bid/bresp/bvalid/bready
    //   io_ddrClk 侧：io_ddr_clk / io_ddr_rstn / io_ddrAwAddr(28)/AwLen(4)/AwValid/AwReady /
    //               io_ddrWData(256)/WStrb(32)/WReady / io_ddrArAddr/AwLen/ArValid/ArReady /
    //               io_ddrRData(256)/RValid/RLast
    // 与 `board/yeshen_mini_soc.v` 的 mem_* 是**一一同名**（只差 mem_ / io_axi_ 前缀），位宽逐条相同。
    DDR3Bridge u_bridge (
        .clock       (soc_clk),
        .reset       (soc_async_reset),      // 高有效（Chisel 隐式复位）
        .io_ddr_clk  (core_clk),             // ★ IP 输出的 125MHz（见文件头【1】）
        .io_ddr_rstn (ddr_init_done),        // 高有效：1 = DDR 初始化完成 = 可跑

        // ---- AXI4 从口（64bit）----
        .io_axi_ar_arid    (mem_ar_arid),
        .io_axi_ar_araddr  (mem_ar_araddr),
        .io_axi_ar_arlen   (mem_ar_arlen),
        .io_axi_ar_arsize  (mem_ar_arsize),
        .io_axi_ar_arburst (mem_ar_arburst),
        .io_axi_ar_arlock  (mem_ar_arlock),
        .io_axi_ar_arcache (mem_ar_arcache),
        .io_axi_ar_arprot  (mem_ar_arprot),
        .io_axi_ar_arvalid (mem_ar_arvalid),
        .io_axi_ar_arready (mem_ar_arready),
        .io_axi_r_rid      (mem_r_rid),
        .io_axi_r_rdata    (mem_r_rdata),
        .io_axi_r_rresp    (mem_r_rresp),
        .io_axi_r_rlast    (mem_r_rlast),
        .io_axi_r_rvalid   (mem_r_rvalid),
        .io_axi_r_rready   (mem_r_rready),
        .io_axi_aw_awid    (mem_aw_awid),
        .io_axi_aw_awaddr  (mem_aw_awaddr),
        .io_axi_aw_awlen   (mem_aw_awlen),
        .io_axi_aw_awsize  (mem_aw_awsize),
        .io_axi_aw_awburst (mem_aw_awburst),
        .io_axi_aw_awlock  (mem_aw_awlock),
        .io_axi_aw_awcache (mem_aw_awcache),
        .io_axi_aw_awprot  (mem_aw_awprot),
        .io_axi_aw_awvalid (mem_aw_awvalid),
        .io_axi_aw_awready (mem_aw_awready),
        .io_axi_w_wid      (mem_w_wid),
        .io_axi_w_wdata    (mem_w_wdata),
        .io_axi_w_wstrb    (mem_w_wstrb),
        .io_axi_w_wlast    (mem_w_wlast),
        .io_axi_w_wvalid   (mem_w_wvalid),
        .io_axi_w_wready   (mem_w_wready),
        .io_axi_b_bid      (mem_b_bid),
        .io_axi_b_bresp    (mem_b_bresp),
        .io_axi_b_bvalid   (mem_b_bvalid),
        .io_axi_b_bready   (mem_b_bready),

        // ---- DDR 侧简化 AXI（256bit）→ ★ V1 起先经 u_ddr_arb 的桥侧 b_*，再到 u_ddr3 ----
        .io_ddrAwAddr  (ddr_axi_awaddr),
        .io_ddrAwLen   (ddr_axi_awlen),
        .io_ddrAwValid (ddr_axi_awvalid),
        .io_ddrAwReady (ddr_axi_awready),
        .io_ddrWData   (ddr_axi_wdata),
        .io_ddrWStrb   (ddr_axi_wstrb),
        .io_ddrWReady  (ddr_axi_wready),
        .io_ddrArAddr  (ddr_axi_araddr),
        .io_ddrArLen   (ddr_axi_arlen),
        .io_ddrArValid (ddr_axi_arvalid),
        .io_ddrArReady (ddr_axi_arready),
        .io_ddrRData   (ddr_axi_rdata),
        .io_ddrRValid  (ddr_axi_rvalid),
        .io_ddrRLast   (ddr_axi_rlast)
    );

    // DDR3 IP 用户口线在**上面**（DDR3Bridge 例化之前）声明，见那段注释。
    // ★ V1 起：这批 `ddr_axi_*` 是 **桥 ↔ 仲裁器** 之间的网（不再是桥 ↔ IP）——
    //   桥的 `io_ddrR*` 已改由仲裁器的桥侧 `b_r*` 驱动（见上面的 u_ddr_arb 例化）。

    // ========================================================================
    // ★ V1（Task 7）：DDR 2:1 仲裁器 —— 桥（ID=0）与视频帧存（ID=1）共享 IP 用户口
    // ========================================================================
    // 侧别口径（见 board/cam/ddr_arbiter_2to1.v 文件头）：
    //   b_* = 桥侧   = `ddr_axi_*`（u_bridge.io_ddr*，简化 AXI：**无 wvalid / wusero_last / rready**）
    //   v_* = 视频侧 = u_video.ddr_*（同等简化 AXI，由厂家 fram_buf 原语驱动）
    //   m_* = IP 侧  = u_ddr3.axi_*（带 aruser_id / rid / wusero_last）
    // 仲裁规则（不在本层改，逐条抄组件文件头）：
    //   · 写：AW+W 成对串行，一次一笔 burst，**视频优先**；桥侧要求 awvalid && wvalid。
    //   · 读：**多未完成**（桥 ≤4 笔、视频 1 笔在飞；AR 一拍一笔交 IP，视频优先 +
    //         两方都有请求时轮转；R 按 rid 分流（1=视频，其它=桥））。旧版 AR 串行
    //         （单笔）把桥内 DEPTH=4 结构性压成 1 ⇒ NPU 32B 散读只能一笔一笔往返。
    //   · 写完成：IP 的 `axi_wusero_last` 只回送给该笔写的属主 ⇒ `v_wlast` **必须**
    //     接回 `u_video.ddr_wusero_last`（厂家 wr_ctrl 靠它推进/收尾 burst）。
    // 复位：`rstn(ddr_rstn)` = POR 计数 + 按键（与 u_ddr3.resetn 同源同极性，高=放开）。
    // ⚠️ 本模块是 ddr_clk（= core_clk）域：与 u_bridge.io_ddr_* / u_video.ddr_* 同域。
    // ========================================================================
    // IP 侧（→ u_ddr3.axi_*）：`m_*` 名字与仲裁器端口逐字相同，便于与组件文件头对照。
    wire [27:0]  m_awaddr;   wire [3:0]  m_awlen;   wire m_awvalid, m_awready;
    wire [255:0] m_wdata;    wire [31:0] m_wstrb;   wire m_wvalid, m_wready;
    wire         m_wusero_last;
    wire [27:0]  m_araddr;   wire [3:0]  m_arlen;   wire [3:0] m_aruser_id;
    wire         m_arvalid, m_arready;
    wire [255:0] m_rdata;    wire [3:0]  ddr_rid;   wire m_rlast, m_rvalid, m_rready;
    // 视频侧（u_video.ddr_* ↔ 仲裁器 v_*）
    wire [27:0]  v_awaddr;   wire [3:0]  v_awlen;   wire v_awvalid, v_awready;
    wire [255:0] v_wdata;    wire [31:0] v_wstrb;   wire v_wvalid, v_wready;
    wire         v_wusero_last;
    wire [27:0]  v_araddr;   wire [3:0]  v_arlen;   wire v_arvalid, v_arready;
    wire [255:0] v_rdata;    wire [3:0]  v_rid;     wire v_rlast, v_rvalid, v_rready;
    wire [31:0]  dbg_vid_ar_wait;      // 视频读请求等待拍数（→ video_regs.DBG[15:0]）
    wire         b_wlast_unused;       // 桥侧写完成：桥内部按 ipWrPend 记账，不需要

    ddr_arbiter_2to1 u_ddr_arb (
        .clk  (core_clk),
        .rstn (ddr_rstn),

        // ---- 桥侧（ID=0）→ DDR3Bridge.io_ddr* ----
        .b_awaddr  (ddr_axi_awaddr),
        .b_awlen   (ddr_axi_awlen),
        .b_awvalid (ddr_axi_awvalid),
        .b_awready (ddr_axi_awready),
        .b_wdata   (ddr_axi_wdata),
        .b_wstrb   (ddr_axi_wstrb),
        .b_wvalid  (ddr_axi_wvalid),
        .b_wready  (ddr_axi_wready),
        .b_araddr  (ddr_axi_araddr),
        .b_arlen   (ddr_axi_arlen),
        .b_arvalid (ddr_axi_arvalid),
        .b_arready (ddr_axi_arready),
        .b_rdata   (ddr_axi_rdata),
        .b_rid     (),
        .b_rlast   (ddr_axi_rlast),
        .b_rvalid  (ddr_axi_rvalid),
        .b_rready  (1'b1),              // 桥的 R 通道没有 rready（收到即入 FIFO）⇒ 恒接收

        // ---- 视频侧（ID=1）→ video_passthrough.ddr_* ----
        .v_awaddr  (v_awaddr),
        .v_awlen   (v_awlen),
        .v_awvalid (v_awvalid),
        .v_awready (v_awready),
        .v_wdata   (v_wdata),
        .v_wstrb   (v_wstrb),
        .v_wvalid  (v_wvalid),
        .v_wready  (v_wready),
        .v_araddr  (v_araddr),
        .v_arlen   (v_arlen),
        .v_arvalid (v_arvalid),
        .v_arready (v_arready),
        .v_rdata   (v_rdata),
        .v_rid     (v_rid),
        .v_rlast   (v_rlast),
        .v_rvalid  (v_rvalid),
        .v_rready  (v_rready),

        // ---- IP 侧（→ u_ddr3.axi_*，见下面 u_ddr3 的例化）----
        .m_awaddr     (m_awaddr),
        .m_awlen      (m_awlen),
        .m_awvalid    (m_awvalid),
        .m_awready    (m_awready),
        .m_wdata      (m_wdata),
        .m_wstrb      (m_wstrb),
        .m_wvalid     (m_wvalid),
        .m_wready     (m_wready),
        .m_wusero_last(m_wusero_last),
        .m_araddr     (m_araddr),
        .m_arlen      (m_arlen),
        .m_aruser_id  (m_aruser_id),
        .m_arvalid    (m_arvalid),
        .m_arready    (m_arready),
        .m_rdata      (m_rdata),
        .m_rid        (ddr_rid),
        .m_rlast      (m_rlast),
        .m_rvalid     (m_rvalid),
        .m_rready     (m_rready),

        .b_wlast      (b_wlast_unused),
        .v_wlast      (v_wusero_last),
        .dbg_v_ar_wait(dbg_vid_ar_wait)
    );

    // ========================================================================
    // ★ V1（Task 7）：视频直通链 —— 相机 → 裁列 → 帧存(DDR) → LCD → overlay
    // ========================================================================
    // 时钟/复位口径（逐条对应组件文件头的契约，**不要**"顺手改"）：
    //   sys_clk   = clk_in（27MHz）—— 厂家 SCCB/初始化状态机用的慢钟
    //   cam_rstn  = rst_board_n & pll_lock_lcd（低有效）—— **必须**带 PLL lock 门控：
//               厂家 camera.v 的 PWDN 5ms → RESET 1.3ms → 21ms 后 SCCB 序列要求上电有
//               一个复位脉冲；只接原始按键（上电即高）会跳过 5ms PWDN 延时、让传感器
//               在错误状态下被配置（V1 实测：暗红单-bit 图案）。
    //   ddr_clk   = core_clk（DDR IP 输出的 125MHz）—— 与 U_ddr_arb / u_ddr3 同域
    //   ddr_rstn  = ddr_init_done（高=可跑）—— 帧存只在 PHY 校准完成后才发 AXI
    //   lcd_clk   = lcd_clk（51.923MHz，u_pll_lcd 经 BUFG）
    //   lcd_rstn  = soc_resetn（SoC 放行即放行）
    // 仿真旁路 vin_*：板级恒 0（SIM_BYPASS_CAMERA=0 走真相机通路）。
    // overlay 写口：ovl_wr_clk = soc_clk（video_regs 同域），ovl_wr_rstn = soc_resetn。
    //   `ovl_active_bank` 是只读观测（video_regs 没有该输入，Task 4 的寄存器图里没有它）⇒ 悬空。
    // ========================================================================
    wire        vid_frame_toggle;      // ddr_clk 域：每帧翻转（→ video_regs.STATUS 帧序号）
    wire        vid_wr_bank;           // ddr_clk 域：本帧写 bank
    wire        vid_cam_init_done;     // ddr_clk 域：相机初始化完成（SCCB 配完）
    wire        vid_gui_mode;          // soc_clk 域：GUI_CTRL[0]（u_video_regs → u_video）
    wire        vid_gui_bank;          // soc_clk 域：GUI_CTRL[1]
    wire        ovl_wr_en, ovl_commit, ovl_en;
    wire [4:0]  ovl_wr_addr;
    wire [31:0] ovl_wr_data;
    wire [7:0]  ovl_count;

    wire cam_rstn = rst_board_n & pll_lock_lcd;   // 上电复位脉冲（厂家 rst_n = locked0 & rst_in 同义）

    // ========================================================================
    // ★ V1b（2026-10-27）：双目切换控制（soc_clk 域）
    //   key2（B22）→ `key_toggle u_key2`（电平持续计数消抖 + U6 闸门）→ 单拍 `key2_toggle`
    //   → `video_regs` 的 CAM_CTRL（写 1 翻转 sel；CAM_CTRL[0] 回读当前 sel）
    //   → `u_video.cam_sel`（cam_switch 在 clk0/clk1 之间做无毛刺时钟 mux，sel 是 2FF 异步穿越）
    //   环路观测：cam_ready = 所选相机 SCCB init_done（CAM_STATUS.READY）；
    //             cam_busy  = 切换/黑屏窗口进行中（CAM_STATUS.BUSY）。
    //   ⚠️ 复位口径与 u_video 的 lcd_rstn / u_video_regs.rstn 一致：都用 `soc_resetn`（1 = 运行）。
    // ========================================================================
    wire        cam_sel_w, cam_ready_w, cam_busy_w;
    wire        key2_toggle;

    key_toggle u_key2 (
        .clk   (soc_clk),
        .rstn  (soc_resetn),
        .key_n (key2),
        .pulse (key2_toggle)
    );

    video_passthrough u_video (
        .sys_clk        (clk_in),
        .cam_rstn       (cam_rstn),
        .ddr_clk        (core_clk),
        .ddr_rstn       (ddr_init_done),
        .lcd_clk        (lcd_clk),
        .lcd_rstn       (soc_resetn),
        .ddr_init_done  (ddr_init_done),

        // ---- 相机引脚（顶层直连）----
        .camera_clk_0   (camera_clk_0),
        .camera_data_0  (camera_data_0),
        .camera_href_0  (camera_href_0),
        .camera_vsync_0 (camera_vsync_0),
        .SCL_0          (SCL_0),
        .SDA_0          (SDA_0),
        .cam_rst_0      (cam_rst_0),

        // ---- ★ V1b：CAM1 引脚（顶层直连）+ 双目切换控制 ----
        .camera_clk_1   (camera_clk_1),
        .camera_data_1  (camera_data_1),
        .camera_href_1  (camera_href_1),
        .camera_vsync_1 (camera_vsync_1),
        .SCL_1          (SCL_1),
        .SDA_1          (SDA_1),
        .cam_rst_1      (cam_rst_1),
        .soc_clk        (soc_clk),
        .soc_rstn       (soc_resetn),      // 1 = 运行（与 u_video.lcd_rstn 同源）
        .cam_sel        (cam_sel_w),
        .cam_ready      (cam_ready_w),
        .switch_busy    (cam_busy_w),

        // ---- ★ Phase R：GUI 冻结 / GUI 读 bank（soc_clk 域；u_video 内部 2FF）----
        .gui_mode       (vid_gui_mode),
        .gui_bank       (vid_gui_bank),

        // ---- 仿真旁路（板级不用）：常数 0 ----
        .vin_clk        (1'b0),
        .vin_de         (1'b0),
        .vin_vsync      (1'b0),
        .vin_pix        (16'd0),

        // ---- 简化 AXI（ddr_clk 域）→ u_ddr_arb 视频侧 ----
        .ddr_awaddr     (v_awaddr),
        .ddr_awlen      (v_awlen),
        .ddr_awvalid    (v_awvalid),
        .ddr_awready    (v_awready),
        .ddr_wdata      (v_wdata),
        .ddr_wstrb      (v_wstrb),
        .ddr_wvalid     (v_wvalid),
        .ddr_wready     (v_wready),
        .ddr_wusero_last(v_wusero_last),   // ★ 仲裁器的 v_wlast 回送（写完成）
        .ddr_araddr     (v_araddr),
        .ddr_arlen      (v_arlen),
        .ddr_arvalid    (v_arvalid),
        .ddr_arready    (v_arready),
        .ddr_rdata      (v_rdata),
        .ddr_rid        (v_rid),
        .ddr_rlast      (v_rlast),
        .ddr_rvalid     (v_rvalid),
        .ddr_rready     (v_rready),

        // ---- LCD 引脚（顶层直连）----
        .lcd_pclk       (lcd_pclk),
        .lcd_de         (lcd_de),
        .lcd_hs         (lcd_hs),
        .lcd_vs         (lcd_vs),
        .lcd_pwm        (lcd_pwm),
        .lcd_r          (lcd_r),
        .lcd_g          (lcd_g),
        .lcd_b          (lcd_b),

        // ---- 帧状态（ddr_clk 域）→ video_regs（soc_clk 域，内部 2FF）----
        .frame_toggle   (vid_frame_toggle),
        .wr_bank        (vid_wr_bank),
        .cam_init_done  (vid_cam_init_done),

        // ---- overlay 写口（soc_clk 域）← video_regs ----
        .ovl_wr_clk     (soc_clk),
        .ovl_wr_rstn    (soc_resetn),
        .ovl_wr_en      (ovl_wr_en),
        .ovl_wr_addr    (ovl_wr_addr),
        .ovl_wr_data    (ovl_wr_data),
        .ovl_commit     (ovl_commit),
        .ovl_en         (ovl_en),
        .ovl_count      (ovl_count),
        .ovl_active_bank()                 // 只读观测，本版不引（video_regs 无此输入）
    );

    // ========================================================================
    // ★ V1（Task 7）：VIDEO CSR 窗落地（1 KiB，基址 0xF000_7400 由胶合块解码）
    // ========================================================================
    // 从口 = u_soc.video_*（上面已逐条映射）；地址取低 12 位（胶合块把窗内偏移放在低 10 位，
    // 高 22 位恒 0 ⇒ 取 [11:0] 与 1 KiB 窗完全匹配，且与组件文件头的 `s_awaddr[11:0]` 同宽）。
    // 帧状态跨域在 video_regs 内部做（frame_toggle 2FF + 边沿，见其文件头），本层不另加同步器。
    // ========================================================================
    video_regs u_video_regs (
        .clk   (soc_clk),
        .rstn  (soc_resetn),

        .s_awaddr  (u_soc_video_awaddr[11:0]),
        .s_awvalid (u_soc_video_awvalid),
        .s_awready (u_soc_video_awready),
        .s_wdata   (u_soc_video_wdata),
        .s_wstrb   (u_soc_video_wstrb),
        .s_wvalid  (u_soc_video_wvalid),
        .s_wready  (u_soc_video_wready),
        .s_bvalid  (u_soc_video_bvalid),
        .s_bready  (u_soc_video_bready),
        .s_bresp   (u_soc_video_bresp),
        .s_araddr  (u_soc_video_araddr[11:0]),
        .s_arvalid (u_soc_video_arvalid),
        .s_arready (u_soc_video_arready),
        .s_rdata   (u_soc_video_rdata),
        .s_rvalid  (u_soc_video_rvalid),
        .s_rready  (u_soc_video_rready),
        .s_rresp   (u_soc_video_rresp),

        // ---- 帧状态（ddr_clk 域，内部 2FF）----
        .frame_toggle (vid_frame_toggle),
        .wr_bank      (vid_wr_bank),
        .init_done    (vid_cam_init_done),
        .vid_stall    (dbg_vid_ar_wait[15:0]),

        // ---- overlay 写口（→ u_video，同 soc_clk 域）----
        .ovl_wr_en    (ovl_wr_en),
        .ovl_wr_addr  (ovl_wr_addr),
        .ovl_wr_data  (ovl_wr_data),
        .ovl_commit   (ovl_commit),
        .ovl_en       (ovl_en),
        .ovl_count    (ovl_count),

        // ---- ★ V1b：CAM_CTRL / CAM_STATUS 的双目切换侧（soc_clk 域）----
        .cam_sel_toggle (key2_toggle),     // KEY2 消抖单拍 → CAM_CTRL 写 1 翻转 sel
        .cam_rdy        (cam_ready_w),     // 所选相机 init_done（只读）
        .cam_busy       (cam_busy_w),      // 切换/黑屏进行中（只读）
        .cam_sel        (cam_sel_w),       // 当前 sel（→ u_video.cam_sel）

        // ---- ★ Phase R：GUI_CTRL（0x094）→ u_video（GUI 冻结 / 读 bank）----
        .gui_mode       (vid_gui_mode),
        .gui_bank       (vid_gui_bank)
    );

    // ========================================================================
    // 紫光同创 DDR3 IP（黑盒）
    // ========================================================================
    // 【端口契约】逐字取自 `third_party/ddr3_ip/ddr3_test/ddr3_test.v` 的模块头（IP 生成物）
    // 与 `example_design/rtl/test_ddr.v` 的例化（L746-860）、官方 4_10 demo（L288-...）：
    //   参数：MEM_ROW_WIDTH=15 / MEM_COLUMN_WIDTH=10 / MEM_BANK_WIDTH=3 / MEM_DQ_WIDTH=32 /
    //         MEM_DM_WIDTH=4 / MEM_DQS_WIDTH=4 / CTRL_ADDR_WIDTH=28
    //   用户口：axi_awaddr[27:0] axi_awuser_ap axi_awuser_id[3:0] axi_awlen[3:0] axi_awready
    //           axi_awvalid / axi_wdata[255:0] axi_wstrb[31:0] axi_wready axi_wusero_id[3:0]
    //           axi_wusero_last / axi_araddr[27:0] axi_aruser_ap axi_aruser_id[3:0]
    //           axi_arlen[3:0] axi_arready axi_arvalid / axi_rdata[255:0] axi_rid[3:0]
    //           axi_rlast axi_rvalid
    //   ⚠ 简化 AXI 特性（见 DDR3Bridge.scala 文件头）：W 通道无 wvalid（wready 高即采样）、
    //      R 通道无 rready；`axi_wstrb` 是 **32bit 逐字节掩码**、`axi_wdata` 是 **256bit**。
    //   debug/校准口一律照既有工程置常量（不接 UART 调试）。
    ddr3_test #(
        .MEM_ROW_WIDTH    (15),
        .MEM_COLUMN_WIDTH (10),
        .MEM_BANK_WIDTH   (3),
        .MEM_DQ_WIDTH     (32),
        .MEM_DM_WIDTH     (4),
        .MEM_DQS_WIDTH    (4),
        .CTRL_ADDR_WIDTH  (28)
    ) u_ddr3 (
        .ref_clk        (ref_clk),
        .resetn         (ddr_rstn),           // ★ POR 计数器（见上方"★ 2026-10-03"段），不是原始按键
        .core_clk       (core_clk),
        .pll_lock       (),                   // IP 内部 PHY 的锁定指示：板级不用（见上面⚠️）
        .phy_pll_lock   (),
        .gpll_lock      (),
        .rst_gpll_lock  (),
        .ddrphy_cpd_lock(),
        .ddr_init_done  (ddr_init_done),

        // 简化 AXI 写通道（★ V1：用户口从"桥直连"改为"u_ddr_arb 的 IP 侧 m_*"，见上）
        .axi_awaddr     (m_awaddr),
        .axi_awuser_ap  (1'b0),
        .axi_awuser_id  (4'h0),
        .axi_awlen      (m_awlen),
        .axi_awready    (m_awready),
        .axi_awvalid    (m_awvalid),

        .axi_wdata      (m_wdata),
        .axi_wstrb      (m_wstrb),
        .axi_wready     (m_wready),
        .axi_wusero_id  (),
        .axi_wusero_last(m_wusero_last),   // ★ 写完成回送 → 仲裁器按 last_sel 分发给桥/视频

        // 简化 AXI 读通道
        .axi_araddr     (m_araddr),
        .axi_aruser_ap  (1'b0),
        .axi_aruser_id  (m_aruser_id),     // ★ 仲裁器按属主置 0（桥）/ 1（视频）
        .axi_arlen      (m_arlen),
        .axi_arready    (m_arready),
        .axi_arvalid    (m_arvalid),

        .axi_rdata      (m_rdata),
        .axi_rid        (ddr_rid),         // ★ IP 回来的 rid → 仲裁器按 rid 分流 R
        .axi_rlast      (m_rlast),
        .axi_rvalid     (m_rvalid),

        // APB 配置（不使用）
        .apb_clk        (1'b0),
        .apb_rst_n      (1'b0),
        .apb_sel        (1'b0),
        .apb_enable     (1'b0),
        .apb_addr       (8'd0),
        .apb_write      (1'b0),
        .apb_ready      (),
        .apb_wdata      (16'd0),
        .apb_rdata      (),

        // DDR3 物理接口
        .mem_cs_n       (mem_cs_n),
        .mem_rst_n      (mem_rst_n),
        .mem_ck         (mem_ck),
        .mem_ck_n       (mem_ck_n),
        .mem_cke        (mem_cke),
        .mem_ras_n      (mem_ras_n),
        .mem_cas_n      (mem_cas_n),
        .mem_we_n       (mem_we_n),
        .mem_odt        (mem_odt),
        .mem_a          (mem_a),
        .mem_ba         (mem_ba),
        .mem_dqs        (mem_dqs),
        .mem_dqs_n      (mem_dqs_n),
        .mem_dq         (mem_dq),
        .mem_dm         (mem_dm),

        // Debug 控制（不使用，恒无效）
        .dbg_gate_start    (1'b0),
        .dbg_cpd_start     (1'b0),
        .dbg_ddrphy_rst_n  (1'b1),
        .dbg_gpll_scan_rst (1'b0),

        .samp_position_dyn_adj   (1'b0),
        .init_samp_position_even (32'd0),
        .init_samp_position_odd  (32'd0),
        .wrcal_position_dyn_adj  (1'b0),
        .init_wrcal_position     (32'd0),
        .force_read_clk_ctrl     (1'b0),
        .init_slip_step          (16'd0),
        .init_read_clk_ctrl      (12'd0),

        .debug_calib_ctrl     (),
        .dbg_slice_status     (),
        .dbg_slice_state      (),
        .debug_data           (),
        .dbg_dll_upd_state    (),
        .debug_gpll_dps_phase (),
        .dbg_rst_dps_state    (),
        .dbg_tran_err_rst_cnt (),
        .dbg_ddrphy_init_fail (),
        .debug_cpd_offset_adj (1'b0),
        .debug_cpd_offset_dir (1'b0),
        .debug_cpd_offset     (10'd0),
        .debug_dps_cnt_dir0   (),
        .debug_dps_cnt_dir1   (),
        .ck_dly_en            (1'b0),
        .init_ck_dly_step     (8'd0),
        .ck_dly_set_bin       (),
        .align_error          (),
        .debug_rst_state      (),
        .debug_cpd_state      ()
    );

    // ========================================================================
    // LED（2026-10-23：扩到 led[7:0]，语义见 y1/reports/led_diag_spec.md）
    //   硬件事实位：PLL / DDR / 装载器 / 网口；led[3..6] = GPIO[3:0]（Linux 可写）
    //   ⚠️ led[3] 原来是 eth_rgmii_alive；网口位**搬到 led[7]**，含义一字不改。
    // ========================================================================
    assign led[0] = pll_lock_100m;    // 板级 PLL 锁定
    assign led[1] = ddr_init_done;    // DDR 初始化完成
    assign led[2] = load_active;      // 装载器当主人（CPU 被扣复位）
    assign led[3] = gpio_out[0];      // 软件心跳（Linux 1 Hz 翻转；定住 = 内核挂）
    assign led[4] = gpio_out[1];      // y1cam 在跑
    assign led[5] = gpio_out[2];      // NPU 帧进度翻转
    assign led[6] = gpio_out[3];      // 网络就绪（eth0 operstate=up）
    // ★ 2026-10-07 改：原来 led[3] = uart_txd（空闲恒高 ⇒ 常亮，没信息量）。
    //   改成 **"网口 PHY 的 RXC 在跳" 指示**（`eth_rgmii_alive`，由 u_liteeth 内部 `rgmii_clk`
    //   域采到的 sticky 判据引出）：
    //     **常亮 = PHY 的 RXC 在翻转（时钟在跑）；常灭 = 时钟钉死。**
    //   这一条是整条网卡通路的**分水岭**，且不依赖登录、不依赖串口 —— 肉眼即可判。
    assign led[7] = eth_rgmii_alive;

endmodule
