# YeshenGui

Debian-style LVGL 9.2 desktop for the Vexii RV32 Linux board. Phase S provides
a 1024x600 host simulator and an independent TF-card image built from the
read-only `VexiiYeshenLinux` inputs. It does not change RTL, the bitstream, or
the existing camera image.

## Status

- **Host simulator:** complete. Desktop, window manager, Files, System Info,
  Settings, Terminal with English OSK, 2048, Minesweeper, Snake, Games, and
  the demo/screenshot flow all run on the host.
- **Board application and image:** built and verified. Current image:
  `images/sd_gui.img` (YSLD, 8,357,376 bytes, sha256 `f4dfc96d…`) with a
  2.04 MiB rootfs and the Terminal-enabled yshell.
- **Board boot, LCD, UART keyboard, and camera switch:** the default
  freeze/bank pair booted on 2026-10-29; the LCD desktop and two camera/GUI
  switches were visually confirmed. FPS was not measured. The Terminal was
  also exercised on the board over the PTY (`/dev/pts/0`, `sh` child); the test
  was uploaded into RAM, not written to a spare card.
- **Phase R camera switch (offline + default board):** both variants PnR
  `All Constraints Met`. Freeze/bank pair: sbit `7092e495…` +
  `images/sd_gui.img` (`f4dfc96d…`). Second-framebuffer pair: sbit
  `4ada3e7b…` + `images/sd_gui2.img` (`2d250fcf…`). The second-framebuffer
  variant's board A/B test is still pending.
- **Touch + OSK (board debug 2026-10-29):** independent
  `YeshenGuiTouch` RTL, touch kernel/DTB, GT911 evdev input, hot corner/KEY3
  and the terminal OSK are implemented. Two board findings: the J26 panel
  has no SCL pull-up (RTL now drives CTP_SCL push-pull, sbit `85dbe37d…`),
  and the reference `S99leds.sh` clobbered CTP_RST/SCL/SDA (removed from the
  touch rootfs). A userspace scan reads GT911 ID `3931` at **0x14**, so the
  DTS uses `touchscreen@14`. The matching image (`a303229b…`) still needs a
  card write; the old `37d87e63…`/`f67b6f74…` pair is superseded.

## Host simulator (WSL)

Requirements: WSL/Ubuntu, `cmake`, a C compiler, `pkg-config`, SDL2, and WSLg
(or another X/Wayland display).

```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/build_host.sh

YESHENGUI_ASSET_DIR="$PWD/ui/assets" ./build/yshell_host
YESHENGUI_ASSET_DIR="$PWD/ui/assets" ./build/yshell_host --demo
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 25 \
    ./build/yshell_host --demo --screenshots build/shots_final
```

The screenshot tour exits 0 after its nine-step tour and writes `desktop.ppm`
and `window.ppm` (1024x600 P6) to the screenshot directory. A `--demo` run
without `--screenshots` keeps cycling until Ctrl+C; that is also how the board
demo is stopped. `YGUI-FPS <n>` liveness markers appear on stderr every 5 s;
`n` is the LVGL flush count in that window.

Host keyboard is available for debugging: Tab/arrows/Enter/Esc, `g`/`f`/`i`/`s`
for Games/Files/System/Settings, `1`/`2`/`3` for the games, `q` to close.

Run the core tests (games + terminal) with:

```bash
bash tests/run_tests.sh
```

## Terminal (Phase S6)

Press `t` or use the Terminal icon / Applications entry / taskbar button. It
runs a real `/bin/sh` on a PTY, 100×28 characters with 200 lines of scrollback
and minimal ANSI (CSI/OSC stripped; `TERM=dumb`). `Ctrl+W` closes the window;
while the terminal is focused every other key goes to the shell, so `c`, `t`,
`q` are ordinary text.

Host end-to-end smoke:

```bash
YESHENGUI_ASSET_DIR="$PWD/ui/assets" ./build/yshell_host \
    --terminal-test build/terminal.ppm
```

This opens the terminal, types `uname -a`, screenshots, and exits. The result
is [terminal.png](images/terminal.png). On the board the same binary was
exercised over a real PTY (`/dev/pts/0`, a `sh` child of `yshell`); the UART
keyboard types into the terminal and the LCD shows the output. That board test
used a RAM copy of the new yshell, not a card write.

### On-screen keyboard (English)

When the Terminal window has focus, an English LVGL keyboard appears at the
bottom and the terminal scroll area shrinks; the PTY window size is updated
with `TIOCSWINSZ` so the shell input line stays visible. The toolbar adds
`Hide`, `Ctrl+C`, `Tab`, `Esc`, and arrow keys; the keyboard's `1#`/`abc`/`ABC`
keys switch layouts. Hardware keys and OSK keys share
`terminal_handle_key()`.

Host end-to-end smoke (types `ls`, `uname`, `sleep 100`, presses the toolbar
`Ctrl+C`, screenshots, then hides the OSK):

```bash
YESHENGUI_ASSET_DIR="$PWD/ui/assets" ./build/yshell_host \
    --osk-test build/osk.ppm
```

The result is [osk.png](images/osk.png). The same path is wired to the
GT911/goodix evdev touch backend on the board (`platform/board_touch.c`).

## Board build

Run inside WSL from the repository root:

```bash
bash scripts/build_board_app.sh
bash scripts/build_board_image.sh
```

When the reference checkout's isolation baseline is stale, rebuild the default
pair from the existing `images/` snapshot without reading the reference:

```bash
GUI_VARIANT=default_snapshot bash scripts/build_board_image.sh
```

This path does not run or re-record `verify_isolation.sh`; it verifies the
snapshot's `images/inputs.sha256` and leaves the gui2 pair untouched.

The cross compiler actually installed here is
`riscv32-buildroot-linux-uclibc-gcc`; see `board/riscv32-toolchain.cmake`.
The staged binary is `board/rootfs_overlay/root/gui/yshell` (gitignored).
The image build copies the kernel, OpenSBI, DTB, and base rootfs read-only from
`../VexiiYeshenLinux`, applies the GUI overlay, and writes:

- `images/rootfs_gui.cpio.gz` (2,140,156 B, under the 7.5 MiB limit)
- `images/linux_gui.dtb` (reused `linux.dtb`; initrd `0x83000000..0x83800000`)
- `images/sd_gui.img` (YSLD, 8,357,376 bytes, 16,323 512-byte blocks,
  sha256 `f4dfc96d…`)

`images/` and the staged binary/assets are gitignored; do not commit them.

### Phase R second-framebuffer A/B variant

The default build above remains the freeze/bank pair (`images/sd_gui.img` +
bitstream `7092e495…`) and is untouched. The second-framebuffer pair lets the
camera keep writing while the GUI owns a separate 1024x720 RGB565 buffer at
`0x9200_0000` (video AXI word `0x0480_0000`, rows 60–659); `GUI_CTRL[0]` only
selects the LCD read source (1 = GUI, 0 = camera), latched at frame start.
Build it inside WSL with:

```bash
GUI_VARIANT=gui2 bash scripts/build_board_app.sh
GUI_VARIANT=gui2 bash scripts/build_board_image.sh
```

This stages `board/variants/gui2/yshell` (gitignored) and writes
`images/rootfs_gui2.cpio.gz`, `images/linux_gui2.dtb`, and
`images/sd_gui2.img` (YSLD, 8,350,720 bytes, 16,310 blocks). All outputs are gitignored; the
default `sd_gui.img` and overlay yshell are hashed before/after and stay
byte-identical. The variant build uses only the existing `images/` snapshot
inputs: the reference checkout has moved and its isolation baseline is
intentionally stale, so it is neither read nor re-recorded. Pair `sd_gui2.img`
only with the Task R8 `YeshenGuiRtl2` source-select bitstream (same
`yeshen_mini_board_top.sbit` file name; SHA recorded at R8), never with the
freeze/bank bitstream.

Offline R8 result (2026-10-28): `YeshenGuiRtl2` PnR reports
**`All Constraints Met`** (seed 5, Setup Slow +0.184 ns); the sbit is
9,188,552 B, sha256
`4ada3e7b0bdc1cdf5aa12abeb4106c457f8fae980a7788e89f4b8eeaff43fdcd`.
Resources are LUT 85,499 vs 85,596 and FF 115,869 vs 115,873 for the
freeze/bank R3 build, with DRM/APM/distributed RAM unchanged, so the second
framebuffer adds no line buffer or DRM. Pairs (after the 2026-10-28 rename
rebuild):
`sd_gui2.img` (`2d250fcf…`) + sbit `4ada3e7b…`; freeze/bank
`sd_gui.img` (`f4dfc96d…`) + sbit `7092e495…`. The default image was rebuilt
with `GUI_VARIANT=default_snapshot` (snapshot inputs only, reference not read).
The default freeze/bank pair was tested on the board on 2026-10-29 (LCD, UART,
Terminal, camera/GUI switch); the second-framebuffer variant's board A/B test is
still pending.

### Touch/OSK pair (`touch2`, goodix at 0x14)

The first board boot exposed that J26's CTP_SCL has no pull-up; the
known-good `hw_test_200mini` J26 variant drove SCL push-pull. The RTL now
does the same (`touch2` PnR, `All Constraints Met`). The reference
`S99leds.sh` also had to be removed: it writes the whole GPIO DATA_OUT and
cleared CTP_RST/SCL/SDA. A userspace scan with RST released reads GT911 ID
`3931` at 0x14, so the DTS uses `touchscreen@14`; 0x5D is NAK.

`YeshenGuiTouch` is an independent RTL copy that adds the GT911 4-wire pins
(`AE21/AD21/AF22/AE22`), KEY3 (`B20`), a 13-bit GPIO and PLIC source 5. Its
kernel/DTB and gpiochip/i2c-gpio/goodix drivers live in `../YeshenGuiKernel`
(independent copy; the reference Linux tree is untouched). Build the image
inside WSL:

```bash
bash scripts/build_board_app.sh            # touch backend, same yshell name
bash scripts/build_board_image_touch.sh    # never touches default/gui2
```

Outputs (all gitignored):

- `images/sd_gui_touch.img` YSLD, 8,430,080 B, sha256 `a303229b…`
- `images/rootfs_gui_touch.cpio.gz` 2,152,234 B, sha256 `4f37cf8e…`
- `images/linux_touch.dtb` 3,027 B, sha256 `c4a84264…`
- staged yshell 1,233,612 B, sha256 `5ce2f536…`

With this pair, run `/root/gui/yshell --touch-probe 20` from the UART shell
before starting the GUI; it prints the evdev abs range and every sample
(`TOUCH raw=… scaled=… pressed=…`, `TOUCH key3 press`) so the axis
orientation/offset can be checked and calibrated.

Pair it only with the `touch2` `YeshenGuiTouch` bitstream once its PnR
completes (`85dbe37d…`). The old `37d87e63…` sbit (open-drain SCL) does
**not** work with the panel and is superseded. The default and gui2 images/bitstreams remain
byte-identical; never mix pairs.

## Board run (default pair tested 2026-10-29)

1. Write `images/sd_gui.img` to a **different** TF card. Never overwrite the
   existing camera card or `VexiiYeshenLinux/sw/images/sd.img`.
2. Use the matching pair: `7092e495…` sbit + `sd_gui.img`, `4ada3e7b…` sbit +
   `sd_gui2.img`, or `85dbe37d…` sbit + `sd_gui_touch.img`. Do not mix pairs.
   Insert the card, connect UART at 115200 8N1, power on, and log in as
   `root` / `yeshen`.
3. Run:

   ```sh
   /root/gui/yshell          # interactive UART keyboard
   /root/gui/yshell --demo   # unattended tour; Ctrl+C to stop
   ```

   Press `t` for Terminal; `c` switches camera/GUI; `Ctrl+W` closes Terminal.
   With the touch pair, the Terminal also shows the English OSK: tap keys,
   `Hide`, or the keyboard close key; in camera mode touch and hold the
   top-left 64×64 corner for 2 s (or press KEY3) to return to the GUI.
4. With the Phase R bitstream the J10 camera can stay connected; the old
   "unplug J10" note applies only to the stock Phase S bitstream. If the
   desktop does not appear, record `BOARD-DISPLAY-BLOCKED`.

Full commands, marker interpretation, keyboard map, and the acceptance
checklist are in [`docs/phase-s-bringup.md`](docs/phase-s-bringup.md).

## Phase S scope and limitations

- Touch and the OSK exist only in the separate touch pair
  (`sd_gui_touch.img` + sbit `85dbe37d…`); the default and gui2 pairs have no
  touch path (GT911 on host is emulated by the SDL mouse).
- Camera switch is available with the Phase R bitstream; the stock Phase S
  note about unplugging J10 no longer applies to the freeze/bank pair.
- Terminal is implemented (`t`, Ctrl+W closes); the English on-screen keyboard
  appears with touch and is wired to the same key path.
- UART keyboard only: Tab/arrows/Enter/Esc, shortcuts, and game keys. `Shift+Tab`
  is not decoded by the UART backend.
- No RTL, bitstream, kernel, or reference-rootfs changes. The existing
  `VexiiYeshenLinux` checkout remains read-only; `scripts/verify_isolation.sh`
  checks its HEAD, status, index OIDs, and 52 key inputs.

## Documentation

- Design spec:
  [`docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md`](docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md)
- Implementation plan:
  [`docs/superpowers/plans/2026-10-28-phase-s-desktop.md`](docs/superpowers/plans/2026-10-28-phase-s-desktop.md)
- Technical report (Chinese):
  [`docs/YeshenGui-技术文档.md`](docs/YeshenGui-技术文档.md)
- Bring-up and acceptance:
  [`docs/phase-s-bringup.md`](docs/phase-s-bringup.md)

## Layout

- `ui/` - LVGL desktop, window manager, apps, games, themes, assets
- `platform/` - host SDL2 backend, board framebuffer backend, UART input
- `board/` - cross-build files, rootfs overlay, SD packer, isolation baseline
- `scripts/` - host/board builds, image build, asset generation, isolation
- `tests/` - deterministic game-core tests
- `tools/` - wallpaper and screenshot utilities
- `third_party/` - pinned LVGL 9.2 sources and configuration
