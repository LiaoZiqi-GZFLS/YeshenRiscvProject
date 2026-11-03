# Phase S Bring-up and Acceptance

This document is the operational bring-up and acceptance record for Phase S
(host simulator + independent board image). It does not change RTL, the
bitstream, the camera image, or the reference checkout.

**Status:** host simulator and offline image build verified. Board boot,
display, UART keyboard, and performance acceptance are **pending**; they must
be run with the board owner in a dedicated board window. No TF card was written
and no board was flashed while preparing this document.

Reference baseline: `VexiiYeshenLinux` HEAD `212d3a2`, recorded in
`board/vexii_baseline.*`. The reference checkout is read-only for this project.

## 1. Host simulator

Run inside WSL (Ubuntu) from the repository root:

```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/build_host.sh
```

Requirements: `cmake`, a C compiler, `pkg-config`, SDL2, and WSLg (or another
X/Wayland display) for the 1024x600 window. LVGL 9.2 is pinned in
`third_party/` by `scripts/fetch_lvgl.sh`.

Interactive run:

```bash
YESHENGUI_ASSET_DIR="$PWD/ui/assets" ./build/yshell_host
```

Automated tour with screenshots:

```bash
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 25 \
    ./build/yshell_host --demo --screenshots build/shots_final
echo "exit=$?"
```

Expected:
- Exit status `0`; the demo completes in about 11 s (nine 1.2 s steps), well
  before the 25 s timeout.
- `build/shots_final/desktop.ppm` and `build/shots_final/window.ppm` exist,
  are P6 1024x600, and are larger than 100 KB (each is 1,843,216 bytes when
  written by the current build).
- The demo opens Files, 2048, Minesweeper, Snake, System Info, Settings, the
  Games launcher, and returns to the desktop.
- At least one `YGUI-FPS <n>` marker appears on stderr, followed by
  `YGUI-EXIT` when the demo ends. Example from the last offline run:

  ```text
  YGUI-FPS 85
  YGUI-FPS 86
  YGUI-EXIT
  ```

`build/` is gitignored; screenshots and logs are not committed.

Game-core tests (host):

```bash
bash tests/run_tests.sh
```

Expected: `test_game2048: PASS`, `test_minesweeper: PASS`,
`test_snake: PASS`, then `all game core tests: PASS`.

## 2. Board application and image

Run inside WSL from the repository root:

```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/build_board_app.sh
bash scripts/build_board_image.sh
```

The actual cross compiler in this workspace is
`$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc`.
The older `riscv64-buildroot-linux-uclibc-gcc` name in the design spec does not
exist here; `board/riscv32-toolchain.cmake` fails rather than falling back to a
host or riscv64 compiler. `YSHELL_RV32_CC` may override the path explicitly.

`scripts/build_board_app.sh` stages `board/rootfs_overlay/root/gui/yshell`
(gitignored). Current offline result: ELF32 RISC-V, RVC, soft-float ABI,
statically linked, 1,200,332 bytes.

`scripts/build_board_image.sh`:
1. runs `scripts/verify_isolation.sh` before the build;
2. copies the known-good kernel/OpenSBI/DTB/base rootfs from the read-only
   reference into `images/`;
3. unpacks the base rootfs in WSL-native storage, strips
   `S99y1cam.sh` from the staging copy only, applies the GUI overlay, and
   restores root/`/root` modes;
4. repacks `images/rootfs_gui.cpio.gz` and checks member modes/owners;
5. reuses `linux.dtb` when the rootfs fits, otherwise builds the 16 MiB initrd
   variant;
6. writes `images/sd_gui.img` with `board/mk_sd_gui.py`;
7. runs isolation again and re-checks the reference `sd.img` hash.

Current offline result (2026-10-29 terminal rebuild):

| Item | Value |
|---|---|
| `images/sd_gui.img` | 8,357,376 bytes = 16,323 blocks = 7.97 MiB; magic `YSLD`; sha256 `f4dfc96d…` |
| Load table | `fw_jump.bin` @ `0x80000000` blk 1..262; `Image` @ `0x82000000` blk 263..12137; DTB @ `0x82F80000` blk 12138..12142; rootfs @ `0x83000000` blk 12143..16322 |
| `images/rootfs_gui.cpio.gz` | 2,140,156 bytes = 2.04 MiB (limit 7.5 MiB = 7,864,320) |
| DTB | `linux.dtb` reused; initrd window `0x83000000..0x83800000` (8 MiB) |
| rootfs members | 399 |
| `/` / `/root` | `0755` / `0700` |
| `/init` | `0755`, root |
| `/bin/sh` | symlink to `busybox` |
| `/root/gui/yshell` | `0755`, root |
| `/root/gui/assets/*.bin` | `0644`, root |
| `/etc/init.d/S99gui.sh` | `0755`, root |
| `/etc/init.d/S99y1cam.sh` | absent from the staging rootfs |

The embedded `yshell` hash was checked against the staged overlay binary:
both are `1be37d3131f56615b0585e8eabdf8819d53d1e56938d84b187b6f771689f7ad0`.
The default image was rebuilt after the YeshenGui rename and the Terminal
addition with `GUI_VARIANT=default_snapshot` (snapshot inputs only; the
reference tree was not read). Image outputs are gitignored; do not commit them.

## 3. Writing the spare TF card

> **Use a different TF card.** Do not overwrite the existing camera card and
> never write `VexiiYeshenLinux/sw/images/sd.img`. The reference `sd.img` and
> the bitstream are part of the read-only isolation baseline.

`images/sd_gui.img` is a raw disk image (SdLoader table at LBA 0), not a
filesystem. Windows may offer to format the card after writing; cancel that
prompt.

Record the image hash before writing:

```bash
sha256sum images/sd_gui.img
# f4dfc96d16f5d7eade3a442ea221ca1027e9ba1aac905d8d84d686bb1d268fcf (2026-10-29 terminal rebuild)
```

Linux / WSL with the spare card exposed as a block device (for example
`/dev/sdX`; confirm with `lsblk -o NAME,SIZE,MODEL,MOUNTPOINT`):

```bash
sudo umount /dev/sdX* 2>/dev/null || true
sudo dd if=images/sd_gui.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Windows: use Win32DiskImager or balenaEtcher, select only the spare card,
choose `images/sd_gui.img`, and write. Verify the read-back hash if the tool
offers it, or read the first 16,323 blocks back and compare sha256.

The card must be inserted in the board's TF module (J25 on the reference
carrier). The existing camera card is not touched by this procedure.

## 4. Boot and run

1. Use the existing, already-validated bitstream. Do not rebuild RTL or create
   a new `.sbit` for Phase S. If the board was powered off and its SRAM
   configuration was lost, reload the same existing bitstream through the
   normal flow; that is not an RTL change.
2. Insert the spare `sd_gui.img` card, connect the USB-UART, and power on.
   The reference setup uses COM7 at **115200 8N1** (`console=ttyS0,115200`).
3. Wait for `login:` and log in as `root` / `yeshen` (same credentials as the
   existing camera image; verified against the delivered rootfs shadow hash).
4. Run either mode:

   ```sh
   /root/gui/yshell          # interactive; UART keyboard
   /root/gui/yshell --demo   # unattended tour; Ctrl+C to stop
   ```

5. In another serial session (or after exiting), confirm the process and the
   markers:

   ```sh
   ps | grep '[y]shell'
   dmesg | grep -E 'YGUI-(BOOT|FB-OK|FPS|EXIT)'
   ```

The default boot keeps getty on `ttyS0` and does **not** start the GUI.
`/etc/init.d/S99gui.sh` only auto-starts `yshell --demo` when
`/etc/y1gui.autostart` exists; do not create that flag for acceptance because
the GUI and the getty would compete for the serial port.

## 5. Markers and how to read them

`platform_log` writes to stderr on the host and to `/dev/kmsg` on the board.
On the board the kernel console normally echoes these lines to UART; they can
also be read with `dmesg`.

| Marker | Emitted when | Meaning |
|---|---|---|
| `YGUI-BOOT` | `platform_init` on the board | `/dev/mem` opened and both framebuffer banks mapped; process is alive |
| `YGUI-FB-OK` | first successful board flush | Framebuffer writes are landing in DDR; LCD should be able to scan the GUI |
| `YGUI-FPS <n>` | every 5 s in the interactive/demo loop | `n` = successful LVGL flush count in the preceding 5 s window |
| `YGUI-EXIT` | normal exit of the interactive/demo loop | `platform_shutdown` is about to unmap/close; emitted on Ctrl+C, window close, or the host screenshot tour finishing; not emitted by the single-shot `--screenshot` path |

Note that `--demo` without `--screenshots` keeps cycling (the demo-done flag is
only set by the screenshot tour); stop it with Ctrl+C, which emits
`YGUI-EXIT`.

`YGUI-FPS` is deliberately a liveness/throughput counter, not a benchmark.
`n` is per **5-second window**, so `n / 5` is the approximate flush rate.
LVGL only flushes dirty regions, so a mostly static desktop can show fewer
flushes than the renderer is capable of. For the design targets, use
`n >= 150` as the 30 fps static equivalent and `n >= 50` as the 10 fps drag
equivalent, and judge continuous animation/dragging separately. If the board
is below target, reduce animation/wallpaper complexity rather than treating
the marker as a failure of the image.

Host example: `YGUI-FPS 85` and `YGUI-FPS 86` were observed during the demo
screenshot run (about 17 flushes/s with mostly static, changing windows). This
is host liveness evidence, not a board FPS claim.

Optional autostart also logs `YGUI-AUTOSTART pid=<pid>` to kmsg, but only when
`/etc/y1gui.autostart` exists. It is not used by the default acceptance flow.

## 6. Display test (J10 camera unplugged)

The camera write path overwrites the framebuffer. **A display result with the
J10 camera connected is invalid** and must never be reported as a Phase S pass.

1. Power off the board.
2. Unplug the J10 camera module.
3. Boot the spare card, log in, and run `/root/gui/yshell` (or `--demo`).
4. Confirm `YGUI-BOOT` and `YGUI-FB-OK`, then observe the LCD.

The GUI writes 1024x600 RGB565 into rows 60..659 of both banks
(`0x90000000` and `0x91000000`), stride 2048 bytes. Phase S writes both banks
and has no bank flip, so tearing is possible and is not a failure.

If the LCD does not show the desktop:
- record `BOARD-DISPLAY-BLOCKED` exactly, together with the serial log,
  image/card identification, and a photo;
- defer display acceptance to Phase R;
- keep the host simulator as the Phase S UI acceptance vehicle.

Do not claim display success with the camera connected, and do not silently
change RTL or the bitstream to work around a blocked display.

## 7. UART keyboard

`yshell` opens `/dev/ttyS0` raw (or `$UI_TTY`) while it runs; Ctrl+C is a key
event, not a process signal. On exit the saved termios state is restored.

| Key | Action |
|---|---|
| `Tab` | move focus forward |
| Arrow keys | move selection/focus; change direction in 2048 and Snake |
| `Enter` | activate the focused control; reveal in Minesweeper |
| `Esc` | close the focused window / back out |
| `g` / `f` / `i` / `s` | open Games / Files / System Info / Settings |
| `1` / `2` / `3` | open 2048 / Minesweeper / Snake |
| `q` | close the focused window |
| `f` (Minesweeper focused) | flag/unflag the cursor cell (the Files shortcut is suppressed there) |
| `p` (Snake focused) | pause/resume |
| Ctrl+C | exit `yshell` |

Phase S limitations:
- no touch and no mouse on the board (touch is Phase R);
- no camera switch or camera preview (Phase R);
- no terminal and no on-screen keyboard (S6); Ctrl+C therefore exits `yshell`
  instead of sending 0x03 to a PTY;
- no `Shift+Tab`: the UART decoder recognizes `ESC [ A/B/C/D` only, and
  `ESC [ Z` degrades to Esc followed by `Z`; use `Tab`/arrows instead;
- the UART is a single raw console: expect keys to be consumed by the GUI
  while it runs, and keep the serial cable/terminal at 115200 8N1.

## 8. Acceptance checklist (spec §11.4)

Offline items are checked from the Task 15 builds/runs. Board items stay
unchecked until the actual board window.

- [x] Host simulator runs at 1024x600; desktop, three applications, and three
      games are reachable. Evidence: `--demo --screenshots` exited 0, wrote
      both 1024x600 PPMs, and toured Files/2048/Minesweeper/Snake/System
      Info/Settings/Games.
- [x] Game-core unit tests are green; negative controls go red.
      `bash tests/run_tests.sh` printed PASS for all three. Temporary-copy
      mutations (2048 merge disabled, Minesweeper start mine forced, Snake
      wall check disabled) all aborted on assertions (exit 134); the repo was
      not modified.
- [ ] Board `sd_gui.img` boots and `/root/gui/yshell` emits `YGUI-BOOT`.
      **Pending board window.**
- [ ] With J10 unplugged, the LCD shows the desktop (or record
      `BOARD-DISPLAY-BLOCKED` and defer display to Phase R).
      **Pending board window.**
- [x] This project wrote nothing to `VexiiYeshenLinux`; HEAD, status, index
      OIDs, and the 52 key-input artifact hashes match the S0 baseline.
      `scripts/verify_isolation.sh` printed PASS at HEAD `212d3a2` before and
      after the image build. Re-run this check during the board window.
- [x] The existing `sd.img` and bitstream were not overwritten.
      `VexiiYeshenLinux/sw/images/sd.img` sha256 is unchanged at
      `6b832eae245e0b8c4a8193c364e6b13e8a61d2a15791f5a7a7a8522b5ef5c8d2`;
      the bitstream hashes are covered by the isolation manifest.
- [x] Touch is explicitly Phase R and is not claimed usable in Phase S.

## 9. Isolation and baseline discipline

Run before and after any board/image work:

```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/verify_isolation.sh
```

Expected:

```text
PASS: key inputs unchanged for .../VexiiYeshenLinux (HEAD, status, index OIDs, key artifacts)
```

The check is read-only (`GIT_OPTIONAL_LOCKS=0`) and requires all six
`sw/images` key inputs plus every `deliver/sbits/*.sbit`. Baseline HEAD is
`212d3a2`. If the reference moved or another session changed it, **stop and
report**; do not revert concurrent work and do not re-record the baseline
without explicit user confirmation. `scripts/build_board_image.sh` also
refuses to finish if the reference `sw/images/sd.img` hash changes during the
build.

## 10. Board session record (fill in during the window)

| Field | Value |
|---|---|
| Date / operator | |
| Spare card label / capacity | |
| `images/sd_gui.img` sha256 | |
| Existing bitstream reused? | yes / no (no RTL change) |
| `YGUI-BOOT` seen | yes / no |
| `YGUI-FB-OK` seen | yes / no |
| `YGUI-FPS` samples | |
| `YGUI-EXIT` seen | yes / no |
| J10 unplugged display result | desktop / `BOARD-DISPLAY-BLOCKED` |
| UART keyboard result | |
| `ps` shows `yshell` | yes / no |
| `verify_isolation.sh` | PASS / FAIL |
| Logs/photos | `docs/acceptance/...` |

No board item in this document is accepted until that record is complete and
the user confirms the result.
