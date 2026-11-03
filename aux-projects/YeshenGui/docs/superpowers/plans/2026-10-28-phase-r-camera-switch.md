# YeshenGui Phase R — GUI ↔ Camera Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hardware GUI ↔ camera display switch to the Vexii board so the Phase S desktop can run with the J10 camera connected (no unplugging), and `c`/a Camera button can switch to the live camera and back.

**Architecture:** Independent RTL copy of `VexiiYeshenLinux` HEAD `212d3a2` (camsw5; CAM1 kept in reset; CAM0 path). Add a `GUI_CTRL` register at VIDEO `0x094`: `gui_mode` freezes camera writes and makes the LCD read a selected GUI bank; `gui_bank` selects that bank. The board app sets GUI mode at startup and skips framebuffer flushes while camera mode is active; `c` (UART) and the Camera app/button toggle. Original Vexii stays untouched; the new bitstream and image are independent; touch/KEY3 are later Phase R work.

**Tech Stack:** Verilog RTL, PDS 2025.2 (`dev_map`/`pnr`/`gen_bit_stream`), RV32 `yshell`, WSL, `/dev/mem` VIDEO CSR, existing Phase S rootfs/image tooling.

**Base:** `VexiiYeshenLinux` HEAD `212d3a2` (camsw5; CAM1 held reset; CAM0). Original repo is read-only; all changes live in `D:\code\PDS\YeshenGuiRtl` (RTL) and `D:\code\PDS\YeshenGui` (app/image/docs).

**Scope:** GUI ↔ camera switch, CAM0 only, no touch, no CAM1 functional switch, no terminal. Phase S host UI is already accepted offline.

---

## File structure

```
D:\code\PDS\YeshenGuiRtl\          # independent RTL copy (new)
  rtl\ board\ constraints\ pds\ third_party\ ...
  # modified: board/cam/video_regs.v
  #           board/cam/video_passthrough.v
  #           board/cam/vendor/tutorial/fram_buf.v
  #           board/cam/vendor/tutorial/rd_buf.v
  #           board/yeshen_mini_board_top.v
  # PDS root patched to YeshenGuiRtl

D:\code\PDS\YeshenGui\            # software/image (existing phase-s)
  platform/platform.h            # + camera mode API
  platform/board_fb.c            # map VIDEO 0x094; set GUI mode; skip flush in camera mode
  platform/host_sdl.c            # no-op host stubs
  ui/app.c                       # `c` toggle; redraw on return
  ui/desktop.c                   # Camera app/Settings switch
  scripts/build_board_app.sh     # existing; rebuild
  scripts/build_board_image.sh   # existing; rebuild rootfs/sd_gui.img
```

---

## Task R0: Independent RTL copy + PDS root patch

**Files:** new `D:\code\PDS\YeshenGuiRtl\...`; no edits to `VexiiYeshenLinux`.

- [ ] **Step 1:** Record original HEAD/status and run `YeshenGui/scripts/verify_isolation.sh` (must PASS at `212d3a2`).
- [ ] **Step 2:** Inspect `VexiiYeshenLinux/pds/run_devmap_yeshen.tcl` and `run_pnr_yeshen.tcl` for their source list and `set root`/absolute paths.
- [ ] **Step 3:** Copy only the required `rtl/`, `board/`, `constraints/`, `pds/`, and referenced `third_party/` directories into `YeshenGuiRtl`; keep file modes. Do not copy `sw/images`, `sim/reglogs`, build outputs, or git metadata.
- [ ] **Step 4:** Patch every `set root` / absolute project path in the copied PDS scripts to `D:/code/PDS/YeshenGuiRtl`; verify all source-list files exist and no path points at `VexiiYeshenLinux`.
- [ ] **Step 5:** Run `verify_isolation.sh`; original repo must still PASS/unchanged. Commit the plan if not already committed; RTL copy is independent and can be untracked or its own repo.

**Acceptance:** copy source list complete; no original writes; PDS root points only at `YeshenGuiRtl`.

---

## Task R1: GUI_CTRL freeze / gui_bank RTL

**Files:** `YeshenGuiRtl/board/cam/video_regs.v`, `video_passthrough.v`, `vendor/tutorial/fram_buf.v`, `vendor/tutorial/rd_buf.v`, `board/yeshen_mini_board_top.v`.

- [ ] **Step 1:** `video_regs.v`: add RW `GUI_CTRL` at offset `0x094`; bit0 `gui_mode`, bit1 `gui_bank`; reset 0; readback; outputs to the top. Keep all existing registers unchanged.
- [ ] **Step 2:** `video_passthrough.v`: add `gui_mode`/`gui_bank` inputs. Synchronize `gui_mode` into the camera pixel/write domain (2FF) and gate the camera write (`wr_en`/`wr_fsync`) with `~gui_mode_sync`. Synchronize both into `ddr_clk` for the read-bank select. Also synchronize `gui_mode` into `lcd_clk` (2FF) and mask the camera-switch black at the LCD output (`lcd_black = cam_black & ~gui_mode_lcd`): the switch black starts asserted and only clears after camera-ready/frame events, but the freeze gates `frame_start`, so entering GUI mode earlier (or switching/unplugging while frozen) must not blank a selected GUI bank. Camera mode keeps the existing black behavior exactly.
- [ ] **Step 3:** `fram_buf.v`/`rd_buf.v`: replace the fixed `rd_buf.wr_bank(~wr_frame_cnt[0])` with `gui_mode ? gui_bank : ~wr_frame_cnt[0]`. Latch the selected bank in `rd_buf` at the read frame start (`wr_trig`), and use the latched value in `ddr_raddr` so a bank change does not tear mid-frame. The camera mode must keep the existing `~wr_bank` behavior.
- [ ] **Step 4:** `yeshen_mini_board_top.v`: wire `u_video_regs.gui_mode/gui_bank` to `u_video`. No new top-level pins; no original Vexii edits.
- [ ] **Step 5:** Static/simulation checks in the copy: `iverilog`/existing `sim/video/run_video_gates.sh` (or the project’s equivalent) with a freeze case — camera write stops when `gui_mode=1`, LCD selects `gui_bank`, camera resumes when cleared. Add a temporary (not source-list) `cam_black` mask case: `gui_mode=1` + `cam_black` forced 1 => LCD DE/colors not masked; `gui_mode=0` + `cam_black=1` => still blanks; negative control with the mask removed must fail. Report any gate that cannot run in the copy.

**Acceptance:** GUI mode freezes camera writes; LCD reads the selected GUI bank (latched at frame start); GUI mode is never blanked by the camera-switch black; camera mode resumes the existing path and black behavior; no original writes.

---

## Task R2: Board app camera mode + image rebuild

**Files:** `YeshenGui/platform/platform.h`, `platform/board_fb.c`, `platform/host_sdl.c`, `ui/app.c`, `ui/desktop.c`, plus rebuilt `yshell`/`sd_gui.img`.

- [ ] **Step 1:** Add to `platform.h`:
  ```c
  void platform_set_camera_mode(bool on);
  bool platform_camera_mode(void);
  ```
  Host (`host_sdl.c`): no-op / always false. Board (`board_fb.c`): map `/dev/mem` at the page-aligned `0xF0007000` and access `video_regs` at offset **`0x494`** (the VIDEO CSR window is `0xF000_7400`, 1 KiB; GUI_CTRL is at CPU `0xF000_7494`). `platform_set_camera_mode(false)` = GUI mode (`GUI_CTRL=0x1 | bank<<1`), `true` = camera mode (`GUI_CTRL=0`). Keep a `g_camera_mode` flag.
- [ ] **Step 2:** In `board_fb.c` `platform_init`, initialize the VIDEO map and set **GUI mode** before the first frame. In `platform_flush`, skip writes when `g_camera_mode` is true. On return to GUI, the app invalidates/redraws.
- [ ] **Step 3:** In `ui/app.c`, add global `c` shortcut: toggle camera mode; when returning to GUI, `lv_obj_invalidate(lv_screen_active()); lv_refr_now(NULL);`. Keep `#ifdef UI_HOST` screenshot guard; host `c` is a no-op or opens the Camera info card.
- [ ] **Step 4:** In `ui/desktop.c`, make the Camera app (and Settings Camera switch row) call `platform_set_camera_mode(true)` and show a short “press c to return” note; no Phase R placeholder remains. On host, show “camera switch is board-only” and do not crash.
- [ ] **Step 5:** Rebuild host (`scripts/build_host.sh`), board app (`scripts/build_board_app.sh`), and image (`scripts/build_board_image.sh`). The new `sd_gui.img` must contain the new `yshell`; verify magic/size/isolation. Do not flash yet.

**Acceptance:** host build/demo still pass; board app/image rebuilt; camera mode flag/flush behavior implemented; no original Vexii writes.

---

## Task R3: dev_map → PnR → bitstream

**Files:** `YeshenGuiRtl` PDS scripts/reports; new bitstream in `YeshenGuiRtl`.

- [ ] **Step 1:** Run `dev_map` in `YeshenGuiRtl` (managed background; save log). Check 0 DRC/0 errors and resource table.
- [ ] **Step 2:** Run `pnr` with the project’s normal seeds/tags; managed background. Judge by completion marker + `.sbit` existence + exit code + `All Constraints Met`; report the per-domain slack and resource numbers. Never call a negative-slack run “pass”.
- [ ] **Step 3:** If PnR cannot close (likely because camsw5 was already marginal), report the numbers and stop; fall back to the known-good single-camera base only after user approval. Do not weaken constraints silently.
- [ ] **Step 4:** Generate the `.sbit`; record its sha256/size; keep the original Vexii bitstream untouched.

**Acceptance:** new `.sbit` exists; timing/resource evidence recorded; no original writes.

---

## Task R4: Board flash + GUI/camera acceptance

**Prerequisite:** user-provided board window, spare TF card, camera J10 connected; original bitstream backed up.

- [ ] **Step 1:** Flash the new bitstream (JTAG) and write the new `sd_gui.img` to a spare TF card; do not overwrite the original camera card. Record sha256 of both.
- [ ] **Step 2:** Boot with J10 **connected**. The GUI must appear without unplugging. Check `YGUI-BOOT`/`YGUI-FB-OK`/`YGUI-FPS`; camera frames must be frozen (frame counter stops) in GUI mode.
- [ ] **Step 3:** Press `c` over UART: camera mode (camera live, GUI flush skipped). Press `c` again: GUI returns and redraws. Verify no unplug, no camera overwrite, no crash; repeat 3×.
- [ ] **Step 4:** Negative controls: camera connected + GUI mode => no camera overwrite; camera mode => live camera; old bitstream (if tested) => GUI overwritten (expected); no false pass. Record `BOARD-GUI-CAM-OK` or the exact failure.
- [ ] **Step 5:** Restore the original bitstream/image if requested. Report board evidence, timing, and remaining Phase R work (touch/KEY3/CAM1).

**Acceptance:** GUI visible with camera connected; `c` switches both ways; no unplug; evidence recorded.

---

## Risks

| Risk | Mitigation |
|---|---|
| camsw5 PnR was already marginal (`seed2 Setup(Slow) -0.046`) | Report exact slack; do not call it pass; fall back to known-good single-camera base with user approval |
| Freeze mid-frame leaves a partial bank | Freeze before drawing/after a complete frame; GUI app draws both banks; final display uses `gui_bank` |
| `cam_switch` black never clears while frozen | Mask the camera-switch black with `~gui_mode` in `lcd_clk`; camera mode unchanged |
| Bank switch tears | Latch selected bank at read frame start (`wr_trig`) |
| App flush still overwrites camera | `platform_flush` skips in camera mode; `c` return triggers full redraw |
| Board occupied / card overwritten | User window; spare card; original `sd.img` hash check; never blind-flash |
| CAM1 | Kept in reset as in `212d3a2`; GUI/camera switch is CAM0 only for this slice |
| Touch/KEY3 | Not in this slice; later Phase R work |

---

## Out of scope

- Touch/GT911, KEY3 physical switch, CAM1 functional switching.
- Terminal/OSK (S6).
- Any change to `VexiiYeshenLinux` sources, images, bitstreams, or git state.
