# YeshenGui Touch Input — Design Spec (Phase R Touch)

Date: 2026-10-29  
Status: **implemented offline + host-tested; board test pending (T5)**  
Base: `YeshenGui` (terminal-enabled app) + `YeshenGuiRtl` (freeze/bank, board-tested)  
Scope: GT911 capacitive touch → Linux input → LVGL pointer; camera-return touch corner
and KEY3; English on-screen keyboard (OSK) as the follow-up UI layer.

---

## 0. One sentence

Add the GT911 4-wire touch panel to an independent `YeshenGuiTouch` RTL variant and
a new kernel/DTB, expose it through a native Linux input stack
(`gpiochip + i2c-gpio + goodix + evdev`), then connect it to LVGL, the camera
hot-corner/KEY3 return, and the terminal OSK.

---

## 1. Why now / current state

- Terminal (Phase S6 partial) is implemented and board-tested: real `/bin/sh` on
  `/dev/pts/0`, 100×28, 200-line scrollback; the LCD and UART keyboard were
  confirmed. See `2026-10-28-debian-style-touch-gui-design.md` §9.1.
- Default freeze/bank pair (`7092e495…` + `sd_gui.img` `f4dfc96d…`) booted on the
  board; camera/GUI switch `c` was visually confirmed (2026-10-29).
- The current board kernel has **no touch path**: `/proc/config.gz` shows
  `# CONFIG_I2C is not set`, `# CONFIG_GPIOLIB is not set`,
  `# CONFIG_INPUT_EVDEV is not set`; there is no `/dev/i2c*`, `/dev/input` or
  `/sys/class/gpio`.
- The current RTL has no CTP pins. The GPIO block is 8-bit and its `interrupt`
  output is unconnected (`YeshenSocGlue.scala` §2b); PLIC sources 1–4 are already
  used by console, Ethernet, NPU and DMA (`PlicAlite.scala`, `NDEV = 4`).
- So touch is **not** a UI-only change: it needs RTL pins + a fifth interrupt
  source + a kernel rebuild + drivers/DTS. This spec makes that cost explicit.

---

## 2. Authoritative hardware facts

Source of truth: `D:\code\PDS\docs\盘古676-200mini-硬件约束与上板测试报告.md`
(the J26 40-pin table and §4.1 screen mapping; the report's 33/33 pin derivation),
plus `hw_test_200mini/rtl/hwtest_top.v` / `hwtest_omni_top.v` (GT911 probe).

### 2.1 Screen / touch connector

The screen is the 40-pin **J26** connector (J10 is the camera). J26 pins 33–36
are the CTP group:

| Signal | J26 pin | FPGA ball | Direction | Electrical |
|---|---|---|---|---|
| CTP_INT | 33 | **AE21** | input | active low, 3.3V |
| CTP_RST | 34 | **AD21** | output | active low, 3.3V |
| CTP_SCL | 35 | **AF22** | inout | open-drain, 3.3V, pull-up |
| CTP_SDA | 36 | **AE22** | inout | open-drain, 3.3V, pull-up |

Do **not** use the older memory ordering (INT/RST/SCL/SDA = AE21/AD21/AF22/AE22
is the correct mapping; verify against the J26 table before any FDC edit).
The report's screen I2C note applies: screen/camera I2C are open-drain with
pull-ups; SCCB/touch bus ≤100 kHz is the safe bring-up rate.

### 2.2 GT911

- Capacitive 5-point controller on the screen; the hardware probe read product
  ID `3931` ("911") at 0x5D/0x14; both addresses must be tried after reset.
- INT is active low; RST is active low; the address is selected by the INT level
  during reset (mainline `goodix` handles the GT911 sequence).
- Panel resolution 1024×600; report coordinates are panel coordinates. Axis
  orientation and any offset must be measured, not assumed.

### 2.3 Keys

| Signal | Ball | Direction | Note |
|---|---|---|---|
| KEY1 | C23 | input | boot strap; already used |
| KEY2 | B22 | input | camera CAM0/CAM1 toggle; already used |
| KEY3 | A22 | input | free; silkscreen KEY3 is **not wired** in this RTL |
| KEY4 | **B20** | input | wired camera-return fallback (active low) |

The current top wires KEY1 (load strap) and KEY2 (camera toggle) only. KEY4 is a
new input; it must be debounced (level-duration counter, not an edge latch — the
same pattern as `key_toggle.v`).

### 2.4 Board boot/kernel facts observed 2026-10-29

- Linux 5.10.1, RV32, uClibc; `/dev/ptmx` and devpts work; the terminal test
  created `/dev/pts/0` and a `sh` child.
- `CONFIG_UNIX98_PTYS=y`, `CONFIG_DEVTMPFS=y`; I2C/GPIOLIB/INPUT_EVDEV off.
- PLIC: 1=ttyS0, 2=eth0, 3=NPU, 4=DMA; timer is RISC-V local IRQ 5 (not PLIC).
- GPIO: 32-bit register file, but the SoC glue exposes only 8 bits; low 8 are
  board LEDs. `gpio_in` is tied to 0 and the GPIO `interrupt` output is
  unconnected.

---

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| T1 | **Native Linux input stack is the target** | Matches the earlier D6 decision: `gpiochip` + `i2c-gpio` + mainline `goodix` + `evdev`; the UI sees a normal pointer. |
| T2 | A **hardware smoke probe** precedes the native stack | Read the GT911 ID and coordinates with the smallest possible bitstream/userspace probe first; do not build the full stack on an unverified pin map. |
| T3 | Base RTL = **`YeshenGuiRtl` freeze/bank** | It is the board-tested camera-switch variant; the second-framebuffer A/B stays orthogonal. |
| T4 | New RTL copy **`YeshenGuiTouch`** | Never modify `YeshenGuiRtl`, `YeshenGuiRtl2`, or `VexiiYeshenLinux`; copy the needed sources and patch `set root`. |
| T5 | New kernel Image + DTB are required | I2C/GPIOLIB/INPUT_EVDEV/GOODIX are off in the current kernel; rootfs-only changes cannot create `/dev/input/eventX`. |
| T6 | GPIO block widened from 8 to 13 bits; PLIC gets source 5 | Keep LED bits 0–7; add CTP bits 8–11 and KEY4 bit 12; wire a new level IRQ to PLIC source 5. |
| T7 | CTP_INT has a dedicated PLIC source; KEY4 uses `gpio-keys-polled` | The GT911 IRQ must wake `goodix`; KEY3 is low-rate and can poll, avoiding a second IRQ source. |
| T8 | KEY4 (B20) is the hardware camera-return fallback; silkscreen KEY3 (A22) is not wired; the top-left long press is the touch path | Matches the earlier UX decision; both must return to GUI and redraw. |
| T9 | OSK is English only, shown when the terminal is focused | Reuse the terminal and the existing focus model; no CJK/IME; see §9.2 of the base spec. |

---

## 4. Architecture

### 4.1 RTL (`YeshenGuiTouch`)

1. Copy `YeshenGuiRtl` source dirs to `YeshenGuiTouch`; patch PDS `set root`;
   keep the freeze/bank `GUI_CTRL` and camera path unchanged.
2. Add top-level ports and FDC constraints:
   `ctp_int` (AE21, input), `ctp_rst` (AD21, output),
   `ctp_scl`/`ctp_sda` (AF22/AE22, inout, open-drain).
3. Widen the GPIO path from 8 to 13 bits (`YeshenSocGlue.scala` in a **copied**
   Chisel source + regenerate the netlist; or an equivalent Verilog block):
   - bits 0–7: existing LEDs
   - bit 8: CTP_SCL, bit 9: CTP_SDA, bit 10: CTP_RST, bit 11: CTP_INT
   - bit 12: KEY4 (B20); silkscreen KEY3=A22 is not wired
   - SCL/SDA are open-drain in the top (`oe ? 0 : z`); RST push-pull;
     INT/KEY4 inputs pass through 2FF synchronizers.
4. Extend `PlicAlite` `NDEV` from 4 to 5 and add `gpioIrq`/source 5. The source
   must be level-semantics (the CTP INT is active low and deasserts after the
   GT911 is read); invert/register it appropriately before the PLIC.
5. KEY4: `key_toggle`-style debounce (level-duration) into the GPIO input bit
   and/or a `gpio-keys-polled` node in the DTB.
6. PnR: new pins, new netlist; require `All Constraints Met`; record
   LUT/DRM/APM and sbit sha; keep `7092e495`/`4ada3e7b` untouched.
7. Simulation gates: GPIO register read/write for bits 8–12; PLIC source-5
   assert/claim/complete; KEY4 debounce; CTP pin open-drain model; no camera/GUI
   regression (existing video gates).

### 4.2 Kernel / DTB

Build a **new Image** from a copy of the reference kernel/buildroot workspace
(never edit `VexiiYeshenLinux`). Config fragment at minimum:

```
CONFIG_I2C=y
CONFIG_I2C_GPIO=y
CONFIG_GPIOLIB=y
CONFIG_GPIO_CDEV=y
CONFIG_INPUT=y
CONFIG_INPUT_EVDEV=y
CONFIG_TOUCHSCREEN_GOODIX=y
CONFIG_OF=y
CONFIG_DEVTMPFS=y
CONFIG_UNIX98_PTYS=y
```

DTB additions (names/addresses to be confirmed against the SoC map):

- `ctp_gpio`: `compatible = "yeshen,ctp-gpio"`, `reg = <0xF0002000 …>`,
  `gpio-controller`, `#gpio-cells = <2>`, `ngpios = <13>`;
  the driver supports open-drain output (SCL/SDA), push-pull RST, input INT/KEY3.
- `i2c_ctp`: `compatible = "i2c-gpio"`, `sda-gpios = <&ctp_gpio 9 …>`,
  `scl-gpios = <&ctp_gpio 8 …>`, `i2c-gpio,delay-us = <5>` (≈100 kHz),
  child `touch@5d`.
- `touch@5d`: `compatible = "goodix,gt911"`, `reg = <0x5d>`,
  `interrupt-parent = <&plic>`, `interrupts = <5 …>`,
  `reset-gpios = <&ctp_gpio 10 GPIO_ACTIVE_LOW>`,
  `touchscreen-size-x = <1024>`, `touchscreen-size-y = <600>`.
- `gpio-keys-polled` for KEY3 (bit 12), poll interval 20 ms, `linux,code = <KEY_...>`
  (choose an unused key code; document it).
- Update `riscv,ndev`/PLIC source count to 5 and the DTS interrupt map.

The **new Image/DTB** must be paired with the new rootfs and `YeshenGuiTouch`
bitstream; the existing 7092e495/4ada3e7b pairs remain untouched.

### 4.3 Kernel driver(s)

- **`yeshen-ctp-gpio`**: a small platform gpiochip for the widened register
  block. It exposes 13 lines; implements `get`, `set`, `direction_input`,
  `direction_output`, and `set_config(PIN_CONFIG_DRIVE_OPEN_DRAIN)` for the
  I2C lines. No GPIO IRQ domain is required for the native path (CTP INT is a
  direct PLIC source; KEY3 is polled).
- **`i2c-gpio`**: mainline; uses the open-drain SCL/SDA lines; 100 kHz.
- **`goodix`**: mainline GT911 driver; IRQ from PLIC source 5; reset GPIO;
  reports `EV_ABS ABS_X/Y`, `EV_KEY BTN_TOUCH`, and multitouch slots for the
  5-point panel.
- **`gpio-keys-polled`**: KEY3; no extra PLIC source.
- A small static `touch_probe` in the GUI project prints evdev events for
  bring-up; `evtest` is optional (busybox does not provide it).

### 4.4 App / UI

- `platform_poll_touch`: open `/dev/input/eventX` (goodix), read nonblocking,
  track `ABS_X/ABS_Y` + `BTN_TOUCH` (and the first multitouch slot), map/clamp
  to 1024×600, return pressed; no touch → false (host uses SDL mouse).
- `platform_poll_key`: merge UART keys and KEY3 evdev (`EV_KEY`); KEY3 toggles
  camera mode exactly like `c`.
- Camera return:
  - touch hot corner: top-left 64×64, long press ≥2 s → GUI mode + redraw;
  - KEY3: same action; debounce at the driver/RTL;
  - `c` remains the UART/software shortcut.
- Terminal/OSK:
  - OSK is an LVGL keyboard at the bottom; show when Terminal is focused;
    hide on close/`Hide`;
  - the terminal content shrinks and `TIOCSWINSZ` is updated so the shell
    input line stays visible;
  - OSK key events map to `ui_key_t` and call `terminal_handle_key`; hardware
    keys and OSK share the same path;
  - English only; Shift/Ctrl/Tab/Esc/Backspace/Enter/Space/arrows; no CJK.

---

## 5. Work breakdown and gates

| Phase | Work | Gate |
|---|---|---|
| T0 | Hardware smoke: CTP pins/FDC, GT911 ID/coordinates via a minimal probe (existing hw test or a probe bitstream) | ID `3931` at 0x5D/0x14; INT/RST levels; no pin conflict |
| T1 | `YeshenGuiTouch` RTL: CTP pins, GPIO widen, PLIC source 5, KEY3, open-drain; simulation | GPIO/PLIC/key/simulation gates; camera unchanged |
| T2 | Kernel copy + config + DTS + gpiochip/i2c-gpio/goodix/gpio-keys; new Image/DTB/rootfs/SD | boot; `goodix` binds; `/dev/input/eventX` exists; `touch_probe` shows coordinates |
| T3 | LVGL pointer mapping; click/drag/gesture; hot corner + KEY3; camera/GUI | UI touch acceptance below |
| T4 | OSK + terminal integration | OSK acceptance below |
| T5 | PnR/bitstream, image, isolation, docs | `All Constraints Met`; original Vexii zero changes; pairs recorded |

---

## 6. Acceptance

1. `touch_probe` (or `evtest`) shows `ABS_X` 0..1023, `ABS_Y` 0..599,
   `BTN_TOUCH` transitions; touch releases cleanly; no stuck touch.
2. Tap desktop icons, open/close applications, drag a window, scroll Files,
   play 2048/Minesweeper/Snake with touch.
3. Camera/GUI: touch hot corner ≥2 s and KEY3 both return to GUI; the LCD
   redraws; camera mode still works; `c` still works.
4. OSK: from the terminal, touch-type `ls`, `uname -a`, `ip addr`; Ctrl+C
   interrupts `sleep 100` (or a long command); arrows/history; no soft lock;
   hide/show doesn't cover the input line.
5. Kernel: `goodix` binds, no interrupt storm; `i2c-gpio` at ~100 kHz;
   KEY3 produces the expected key event.
6. RTL: `All Constraints Met`; pin report shows only AE21/AD21/AF22/AE22 added;
   no camera/GUI regression; bitstream/image pairs recorded.
7. Isolation: `VexiiYeshenLinux` zero writes (HEAD/status/index/artifacts);
   all new work in `YeshenGuiTouch` / a copied kernel workspace.

---

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Pin/ball mistake or 3.3V/pull-up issue | T0 probe; use the J26 table; PDS pin report; do not guess from memory |
| GPIO/PLIC change breaks timing or the camera | RTL copy; simulation; PnR All Met; keep freeze/bank path unchanged; A/B the old bitstream |
| PLIC source 5 conflict/IRQ storm | Verify PLIC NDEV/claim; level semantics; CTP read clears INT; scope the IRQ count |
| Kernel config/DTS/goodix mismatch | Copy the reference kernel; config fragment; test `goodix` bind; fall back to a user-space GT911 probe only for bring-up |
| New Image size / initrd window | Measure; use the existing 16 MiB DTB window if needed; do not recompile the reference |
| I2C bit-bang timing/address | 100 kHz; try 0x5D/0x14 after reset; scope SCL/SDA; pull-ups |
| Coordinate orientation/offset | Measure with `touch_probe`; mapping table in `platform_poll_touch`; clamp; calibrate 3 points |
| Hot corner / KEY3 conflicts | Define 64×64 top-left, 2 s; KEY3 debounce; no terminal text interference |
| OSK covers the input line / soft lock | Resize terminal content + `TIOCSWINSZ`; hide button; watchdog/test |
| Reference contamination | Everything in copies; `verify_isolation.sh` + hashes; never edit `VexiiYeshenLinux` |

---

## 8. Open decisions for the user

1. **Approve the new kernel Image/DTB** (native stack). If not, the only
   alternative is a user-space GT911 bit-bang/polling probe (not the chosen
   native architecture) and the touch path would remain custom.
2. Base on **freeze/bank** (recommended) or merge the touch work into the
   second-framebuffer variant as well.
3. Confirm **KEY3 = B20**, active low, and its Linux key code.
4. Single-touch mapping vs exposing GT911 5-point multitouch to LVGL.
5. OSK details: key size, Shift/Ctrl behavior, hide gesture, terminal resize.
6. Whether the first board gate should use the existing `hw_test_200mini`
   probe or a new minimal `YeshenGuiTouch` probe bitstream.

---

## 9. Non-goals

- No camera/NPU RTL changes beyond the CTP/KEY3/PLIC additions.
- No CJK/IME, no audio, no Wi-Fi/Bluetooth.
- No full ANSI/curses terminal changes; the terminal remains line-oriented.
- No simultaneous camera+GUI compositor; the freeze/bank switch remains the
  camera mechanism.

---

## 10. References

- Hardware pins/connector: `docs/盘古676-200mini-硬件约束与上板测试报告.md`
  (J26 table, §4.1 screen mapping, §4.3 on-board keys).
- GT911 probe: `hw_test_200mini/rtl/hwtest_top.v`,
  `hw_test_200mini/rtl/hwtest_omni_top.v` (0x5D/0x14, `3931`).
- Current SoC: `VexiiYeshenLinux/src/YeshenSocGlue.scala` (GPIO 8-bit,
  PLIC sources), `src/peripheral/PlicAlite.scala` (`NDEV = 4`),
  `src/peripheral/GPIO.scala` (32-bit registers, interrupt regs).
- Current board top/FDC: `VexiiYeshenLinux/board/yeshen_mini_board_top.v`,
  `constraints/yeshen_mini.fdc`.
- Base GUI: `docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md`
  (§9.1 terminal result; §9.2 OSK), `YeshenGui/README.md`.
- Isolation / copy rules: `YeshenGui/scripts/verify_isolation.sh`,
  `feedback-isolate-experiment-workspace`.

---

## 11. Implementation results (2026-10-29)

### T0 — hardware gate

- CTP pins confirmed from the official J26 table: `CTP_INT=AE21`,
  `CTP_RST=AD21`, `CTP_SCL=AF22`, `CTP_SDA=AE22` (pins 33–36); KEY3 = `B20`.
- GT911 previously probed at `0x5D`/`0x14`, ID `0x3931` by
  `hw_test_200mini`. Touch remains a hardware assumption until the T5 board
  probe; orientation/offset calibration is measured there.

### T1 — independent RTL (`YeshenGuiTouch`)

- Independent copy of `YeshenGuiRtl` (345 files, 21 MB); the original
  `VexiiYeshenLinux` checkout was not modified.
- `PlicAlite.scala`: `NDEV = 5`, new `ctpIrq` input mapped to source 5,
  priority reads extended to 5. `YeshenSocGlue.scala`: GPIO widened 8 → 13
  bits, `ctpIrq` exported; glue Verilog regenerated.
- Board top: CTP pins with 2-FF sync (INT), open-drain SCL/SDA, reset; KEY3
  input; PLIC source 5 wired. The FDC diff against freeze/bank adds **only**
  `key3` (B20) and `ctp_int/rst/scl/sda` (AE21/AD21/AF22/AE22); no other pin
  moves. INT is input-only on this revision (`ctp_irq = ~INT` for the
  level-high PLIC); GT911 relies on the board's 0x5D strap, matching the
  earlier `hw_test_200mini` probe.
- dev_map: LUT 85,915.5 (54%), FF 115,919 (37%), DRM 305 (74%), APM 263
  (36%), distributed RAM 8,079 (21%), IO 166 (42%). Versus freeze/bank R3:
  LUT +319.5, FF +46, IO +5 (four CTP + KEY3), DRM/APM/distributed RAM
  unchanged — the touch path adds only pads/sync/register logic.
- PnR (strategy 1, seed 1): **`All Constraints Met`**, Setup Slow +0.066 ns;
  sbit 9,188,552 B sha256
  `37d87e635ad959a8b6a1de5067fb5f0342c99d00329122bc8002cbe56d8438bb`.
  Per-domain WNS: soc 0.444, cpu 0.436, npu 0.283, camera 0.552, camwr
  15.621, lcd 6.650, core 0.652, core→`phy_dq_sysclk_0` 0.066,
  core→`phy_dq_sysclk_1` 0.335, rgmii 2.868 (all non-negative).
- The PnR ran on a `C:` copy because `D:` was full; the sbit and `.rtr`
  were copied back under the `YeshenGuiTouch` tree.

### T2 — independent kernel/DTB

- Work tree `YeshenGuiKernel` (copy of the Linux source under
  `$HOME/vexii-gui-build/linux-touch` for the build), reference untouched.
- Config fragment enables `I2C`, `I2C_GPIO`, `GPIOLIB`, `INPUT_EVDEV`,
  `INPUT_GPIO_KEYS_POLLED`, `TOUCHSCREEN_GOODIX`; DTS adds
  `gpio@f0002000` (`yeshen,ctp-gpio`, 13 lines, open-drain), `i2c-ctp`
  (`i2c-gpio`, SCL gpio 8 / SDA gpio 9), `goodix@5d` (IRQ 5,
  `irq-gpios` 11, `reset-gpios` 10) and `key3` (gpio 12, `KEY_F13`).
  PLIC `riscv,ndev = 5`.
- Custom `gpio-yeshen-ctp.c` minimal gpiochip exports direction/value and
  emulates open-drain for `i2c-gpio`.
- Artifacts: `out/Image.touch` 6,139,476 B sha
  `64798e934161859d64e315ada5d16fc6ce4d5a410a3dda40c8ba1092d1108a2b`;
  `out/linux_touch.dtb` 2,955 B sha
  `e75a5dfd07b50d99818d55f6622890c983f9221898cd8e0a561467b52cbb5a6d`.
  DTB check: `ndev=5`, gpio 13 lines, i2c-gpio, goodix `reg=0x5d`,
  `interrupts=5`, `irq-gpios` active-high (logical 0 → physical low selects
  0x5D; active-low would have selected 0x14), key3 gpio 12, initrd
  `0x83000000..0x83800000`.

### T3 — app/UI touch path

- `platform/board_touch.c`: scans `/dev/input/event*` for an ABS device
  (goodix) and for `KEY_F13` (gpio-keys), reads `ABS_X/Y`,
  `ABS_MT_POSITION_X/Y`, `BTN_TOUCH`, `ABS_MT_TRACKING_ID`; scales raw
  min/max to 1024×600 via `EVIOCGABS`; `board_key3_poll()` emits
  `UI_KEY_KEY3`.
- Hot corner: board-only 64×64 top-left object, 2 s press returns to GUI
  (`platform_set_camera_mode(false)` + full redraw); KEY3 does the same but
  never enters camera mode.
- Calibration aid: `yshell --touch-probe <seconds>` prints the evdev abs range
  and every raw/scaled sample plus KEY3 presses to stdout (UART).
- Both host and board builds pass; board yshell is built by
  `scripts/build_board_app.sh` (includes `board_touch.c`).

### T4 — English OSK + terminal

- `terminal.c` embeds an LVGL keyboard at the bottom of the terminal window;
  shown when Terminal gains focus, hidden on focus loss, `Hide`, or the
  keyboard close key. The text area shrinks and `TIOCSWINSZ` is updated
  (rows ~14 while visible) so the shell input line stays visible.
- Toolbar: `Hide`, `Ctrl+C`, `Tab`, `Esc`, `Up`, `Down`, `Left`, `Right`.
  Keyboard keys map to the same `terminal_handle_key()` path as hardware
  keys; layout switches (`1#`/`abc`/`ABC`) are consumed without leaking a
  character (fixed via event button id + mode tracking).
- Host smoke `--osk-test`: types `ls`, `uname`, `sleep 100` through the
  actual keyboard widget, presses the toolbar `Ctrl+C` (screen shows `^C`
  and a fresh prompt), takes a screenshot (`images/osk.png`), then `Hide`
  and asserts the OSK is gone. Core tests still pass.

### T5 — image pair (board test pending)

- `scripts/build_board_image_touch.sh` builds from the `images/` snapshot +
  `YeshenGuiKernel/out` + the touch yshell, and hashes the default/gui2
  pairs before/after (they stay byte-identical).
- Touch pair:
  - `images/sd_gui_touch.img` YSLD 8,430,080 B (16,465 blocks) sha256
    `46f857a2e8ed32525e2d52a99dd5eccd6575cd2701dd6c6868374cafad1ce5ac`
  - `images/rootfs_gui_touch.cpio.gz` 2,152,228 B sha
    `5fc9fe7ddac3db43695561e261fe00fadf5d42ccadca43459ccf395302d5ce97`
  - `images/linux_touch.dtb` 2,955 B sha `3a6cd41a…`
  - `images/Image.touch` 6,139,476 B sha `43ad1434…`
  - yshell 1,233,612 B sha
    `5ce2f536be697fcc54363663717517c4e484ede89d0d967c050088dd8f849264`
  - bitstream `85dbe37d…` (`touch2`; above). Never mix with the freeze/bank
    or gui2 pairs. `37d87e63…` is the superseded first attempt.
- Board attempt 2026-10-29 (same window as the card write):
  - `sd_gui_touch.img` was written to the only TF card and read back
    `CARD VERIFY PASS` (SHA `f67b6f74…`); the camera backup `74b029c0…`
    remains intact.
  - `37d87e63…` was flashed over JTAG (`done bit = 1`) and the board cold
    booted. The touch kernel boots, `gpio-keys` is present as
    `/dev/input/event0`, but **goodix fails**: `i2c test failed attempt 1/2:
    -6`, `I2C communication failure: -6`, no touch event node.
  - `i2c-gpio` is registered (`using lines 508 (SDA) and 507 (SCL)`).
    `devmem 0xF0002000` reads 0; manually releasing both lines (DIR
    0x3FF/DATA_OUT 0x300) still reads 0. Root cause: the J26 panel has **no
    SCL pull-up**; the known-good `hw_test_200mini` variant C (screen J26,
    GT911 `3931`) drove **CTP_SCL push-pull** and SDA open-drain. Our board
    top used open-drain for both, so SCL never rose.
  - Fix applied to `YeshenGuiTouch/board/yeshen_mini_board_top.v`:
    `assign ctp_scl = gpio_dir[8] ? gpio_out[8] : 1'bz;` (SDA unchanged,
    open-drain). A fresh dev_map/PnR is running under tag `touch2`; the
    `37d87e63…` sbit is **superseded and must not be used for touch**.
  - KEY3 also reads 0 at GPIO bit 12 in this revision; re-check after the SCL
    fix. If it remains 0, verify the B20 pin/pull and active polarity before
    blaming the OSK layer.
- Board attempt #2 (same day, push-pull SCL sbit `touch2`):
  - PnR `All Constraints Met` (strategy 1, seed 1; min Setup Slow +0.215 ns,
    core→phy0; sbit 9,188,552 B sha
    `85dbe37df9f71387a7b18dbe302b0474e421b16332f18cb9bdfbb83ccb5eea02`).
  - Still `goodix -6`. Root cause #2: the reference `S99leds.sh` writes the
    **whole** GPIO DATA_OUT every second, clearing CTP_RST/SCL/SDA (bits
    8–10); the panel was held in reset. A userspace `/dev/mem` bit-bang
    scanner (`tools/touch_scan.c`, SCL push-pull / SDA open-drain) with
    RST released found **ACK only at 0x14** and read GT911 ID `3931` there;
    0x5D is NAK. The FPGA INT pin is input-only, so the panel's INT-high
    strap selects 0x14.
  - Fix #2: DTS `touchscreen@14` / `reg = <0x14>`; the touch image removes
    `S99leds.sh` (the default/gui2 images keep it).
- Board attempt #3 (0x14 image):
  - Still `-6`. `gpio_sample` (a /dev/mem edge counter) showed **zero SCL/SDA
    edges during a goodix transfer**, and GPIO DIR went back to 0. Root
    cause #3: gpiolib **emulates `GPIO_OPEN_DRAIN` by switching the line to
    input for a high level** (`gpio_set_open_drain_value_commit`), so an
    open-drain SCL is never driven high; this panel has no SCL pull-up.
  - Fix #3: DTS `scl-gpios` drops `GPIO_OPEN_DRAIN` (push-pull; SDA keeps
    it). The gpiochip driver now releases CTP_RST in `yg_probe` (the board
    top drives `ctp_rst` from DATA_OUT[10] even when DIR=0, so a reset-low
    panel never ACKs).
- Board attempt #4 (still `-6`):
  - `i2c-gpio` **ignores the GPIO specifier's OPEN_DRAIN flag** and uses the
    `i2c-gpio,scl-open-drain` / `i2c-gpio,sda-open-drain` properties; without
    them it enforces open-drain and switches SCL to input for a high level.
  - Fix #4: add both properties (driver treats the lines as ordinary
    outputs; the board top already implements push-pull SCL / open-drain
    SDA), matching the userspace scanner that ACKs at 0x14. New DTB
    `c4a84264…` (3,027 B), Image `1f6e8055…`, rootfs `4f37cf8e…`, SD image
    `a303229b…` (16,465 blocks). The `touch2` sbit is unchanged.
- Remaining board gate: write the new image (card move), run
  `yshell --touch-probe 20` to measure orientation/offset, then touch UI,
  hot corner/KEY3, OSK typing and Ctrl+C on the LCD.
- Isolation: `VexiiYeshenLinux` remains unmodified; its HEAD/index baseline
  is still stale from concurrent sessions and was not re-recorded.
