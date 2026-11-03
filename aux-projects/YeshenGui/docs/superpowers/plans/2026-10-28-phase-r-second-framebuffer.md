# YeshenGui Phase R — Second Framebuffer + Read-Source Mux (A/B Variant)

**Goal:** Build an independent A/B variant where the camera keeps writing continuously and the GUI owns a separate DDR framebuffer; the LCD only switches its read source. Keep the existing freeze/bank bitstream (`7092e495…`) and `sd_gui.img` untouched.

**Base:** `YeshenGuiRtl` (the timing-clean freeze/bank variant, R3 `All Constraints Met`) is copied to **`YeshenGuiRtl2`**. Original `VexiiYeshenLinux` remains read-only.

**Architecture:**
- Camera keeps its existing two banks at `0x9000_0000` / `0x9100_0000`; no write freeze.
- A separate GUI buffer at **`0x9200_0000`**, 1024×720 RGB565 (1,474,560 B); `GUI_BASE_WORD = 0x0480_0000` at the video AXI boundary. App writes rows 60–659; LCD reads them.
- `GUI_CTRL` bit0 = `gui_src` (0=camera, 1=GUI); bit1 unused/reserved. No freeze.
- `rd_buf` read address mux: `src_sel ? (GUI_BASE_WORD + wr_cnt) : ({~wr_frame_cnt[0], wr_cnt} + FB_ADDR_WORD)`; latch `src_sel` at the true read-frame start (`wr_rst`) so source changes cannot tear mid-frame.
- `cam_black` remains masked in GUI mode; camera mode behavior unchanged.
- App build variant `BOARD_GUI_SECOND_BUF=1`: `board_fb.c` maps `0x9200_0000`, writes only that buffer, sets `GUI_CTRL` source select; no freeze; camera mode skips flush then redraws on return. New image `sd_gui2.img` and yshell variant; current `sd_gui.img`/`yshell` unchanged.
- `GUI_CTRL`/bitstream/image are a pair; do not mix the freeze/bank and second-buffer variants.

**Why:** camera AE/AGC/frame counter continue in GUI mode; camera owns its banks, GUI owns its buffer; a GUI fault cannot freeze the camera; switching back shows the latest camera frame. Cost: +1.47MB DDR; on-chip uses the shared `rd_buf` line buffer, so **no extra DRAM/DRM**; only a base register + read-address mux + source latch (tens of LUT/FF).

**Scope:** camera ↔ GUI source switch only; no simultaneous camera+GUI compositor; no touch/KEY3; CAM0 only; CAM1 held reset. The current freeze/bank bitstream remains the baseline.

---

## Task R5: Independent variant copy

- [x] Copy `YeshenGuiRtl` → `YeshenGuiRtl2` (source dirs only; exclude `sim/reglogs`, bitstreams, build DB). Preserve modes.
- [x] Patch every `set root`/absolute path in `YeshenGuiRtl2/pds/*.tcl` to `D:/code/PDS/YeshenGuiRtl2`; verify no path points at `VexiiYeshenLinux` or `YeshenGuiRtl`.
- [x] Verify the source list is still 112 files; all present; no original writes; `YeshenGui/scripts/verify_isolation.sh` PASS.
- [x] Do not run PDS/PnR.

**R5 result (offline):** copied source-only; Tcl roots point at `YeshenGuiRtl2`.
The PDS project has 113 source entries (normalized list byte-identical to
`YeshenGuiRtl`) and 239 `FILE` items including the DDR3 IP. The reference
checkout moved again after the R5 copy (now `582294d8`); its isolation baseline
is intentionally stale and no re-record was made. R5 wrote nothing to
`VexiiYeshenLinux`.

## Task R6: RTL source-select variant

- [x] `video_regs.v`: bit0 becomes `gui_src` (0=camera, 1=GUI buffer); bit1 reserved; keep readback/0x094.
- [x] `video_passthrough.v`: remove the camera write freeze gate (camera writes continuously); 2FF `gui_src` into `ddr_clk`/`lcd_clk`; keep `cam_black` masked in GUI mode; pass `src_sel` to `fram_buf`/`rd_buf`.
- [x] `fram_buf.v`/`rd_buf.v`: add `GUI_BASE_WORD=0x0480_0000` parameter; `rd_buf` read address mux as above; latch `src_sel` at `wr_rst`; camera mode keeps `~writer_bank`.
- [x] `yeshen_mini_board_top.v`: wire `gui_src`; no new pins.
- [x] Simulation: camera writes continue in GUI mode; source switch latches at frame start; camera mode unchanged; GUI read base = `0x9200_0000`; cam_black mask still works. Run existing gates + temporary source/bank tests; report.
- [x] Source list 112; no original writes.

**R6 result (offline):** all gates green, negative controls red; logs kept in
`sim/reglogs/r6_evidence/`.

| Gate | Result |
|---|---|
| T1 `tb_src_select` | PASS, frames=6, ar/frame=40 (camera bank, GUI base, mid-frame switch latched) |
| T2 `tb_src_cont` | PASS, cam_aw=20, cam_aw_gui=12, gui_aw=0, ar_cam=2644, ar_gui=9616, frame_togs=5, de_gui=38160, de_cam=0 |
| N1 mux stuck on camera | FAIL errs=80 (must be red) |
| N2 latch on `wr_trig` | FAIL errs=44 (must be red) |
| N3 re-introduce freeze | FAIL errs=3 (must be red) |
| U1 / U1b DDR arbiter | PASS / PASS (`MO_PEAK=4`) |
| U3 / U4 / U5 | OVERLAY PASS / VIDEO_REGS PASS / RESULT PASS |
| U1b / U5 negative | FAIL (must be red) |
| U2 video path | PASS, checked_px=2,368,008, mismatches=0, addr_errs=0 |

## Task R7: App/image variant

- [x] Add `BOARD_GUI_SECOND_BUF` compile flag; `platform/board_fb.c` maps `0x9200_0000`, writes only the GUI buffer; `platform_set_camera_mode(false)` writes `GUI_CTRL=0x1` source select, `true` writes 0; no freeze; `platform_flush` skips in camera mode and redraws on return.
- [x] Host build unchanged; board variant builds `yshell` (same name in a variant build dir), image `sd_gui2.img` with the variant yshell; current `sd_gui.img`/`yshell` untouched.
- [x] Build scripts accept a variant env (e.g. `GUI_VARIANT=gui2`) and write `images/rootfs_gui2.cpio.gz` / `images/sd_gui2.img`; verify YSLD/modes/isolation.
- [x] Host demo/tests pass; no board/PDS.

**R7 result (offline, pre-rename):** `GUI_VARIANT=gui2` builds `board/variants/gui2/yshell`
(ELF32 RISC-V, static, 1,200,500 B, sha256 `1315f5f2…`) with
`BOARD_GUI_SECOND_BUF=1`; default `board/rootfs_overlay/root/gui/yshell`
(`00c5a767…`) and `images/sd_gui.img` (`d40376e7…`) are unchanged. Variant pair:
`images/rootfs_gui2.cpio.gz` (2,133,765 B, 399 members), `images/linux_gui2.dtb`
(copy of `linux.dtb`, initrd `0x83000000..0x83800000`), `images/sd_gui2.img`
(8,351,232 B, 16,311 blocks, YSLD, sha256 `09d2b4c7…`). GUI buffer
`0x9200_0000` (video word `0x0480_0000`), rows 60–659; `GUI_CTRL[0]=1` selects
the GUI read source, camera writes continue. The variant image is used only
with the Task R8 `YeshenGuiRtl2` bitstream (same `yeshen_mini_board_top.sbit`
file name; SHA recorded at R8), never with the freeze/bank `7092e495…`. The
reference checkout has moved (82cef02 noted at R6; observed e1607f1 at R7) and
its isolation baseline is intentionally stale: R7 neither reads the reference
nor re-records the baseline.

## Task R8: PnR + A/B evidence

- [x] `dv_map`/`pnr`/`bitstream` in `YeshenGuiRtl2`; managed background; report `All Constraints Met`, per-domain slack, LUT/DRM/APM, sbit sha/size.
- [x] Compare against the freeze/bank R3 bitstream: resource delta, timing delta, camera-continuity semantics.
- [ ] Optional board test (same user window): flash variant sbit + `sd_gui2.img`; camera connected; GUI shows; camera frame counter continues in GUI; `c` switches; camera latest frame on return; no unplug. Current freeze/bank pair remains available for A/B.

**R8 result (offline, 2026-10-28):**

- **dev_map:** LUT 85,499/159,800 (54%), FF 115,869/319,600 (37%),
  DRM 305/415 (74%), APM 263/740 (36%), distributed RAM 8,079/39,500 (21%),
  IO 161/400 (41%).
- **PnR:** the first multi-seed run (seeds 0–3) was killed by a 7,200 s wrapper
  timeout after selecting seed 2 (`Setup(Slow) -0.064`, one vendor DDR3 PHY
  path). The single-seed rerun tried seed 4 (`-0.028`, not met) and seed 5
  (**`+0.184`, UserFilter 1**). `report_timing`: **`Design Summary : All
  Constraints Met`**. sbit **9,188,552 B**, sha256
  `4ada3e7b0bdc1cdf5aa12abeb4106c457f8fae980a7788e89f4b8eeaff43fdcd`,
  path `sim/reglogs/pds_devmap_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`.
- **Per-domain Setup(Slow) slack (freeze/bank R3 → variant):** soc 0.825→0.800,
  cpu 0.548→0.430, npu 0.303→0.184, camera 0.807→1.044, camwr 15.127→15.318,
  lcd 7.785→8.309, core 0.642→0.890, core→`phy_dq_sysclk_0` 0.481→0.233,
  core→`phy_dq_sysclk_1` 0.162→0.244, rgmii 2.864→3.962. All non-negative.
- **Resource delta:** LUT −97, FF −4, DRM/APM/distributed RAM/IO unchanged
  ⇒ no additional line buffer or DRM for the second framebuffer.
- **Semantics:** camera keeps writing in GUI mode (`cam_aw_gui=12`,
  `frame_togs=5`); GUI reads its own base (`ar_gui=9616`); source/bank latched
  at `wr_rst`; camera mode unchanged; `cam_black` still masked in GUI.
- **Pairs (pre-rename R8 build):** variant = `sd_gui2.img` (sha256 `09d2b4c7…`,
  8,351,232 B, yshell `1315f5f2…`) + sbit `4ada3e7b…`; freeze/bank =
  `sd_gui.img` (sha256 `d40376e7…`, 8,351,232 B) + sbit `7092e495…`. Never mix.
  Current post-rename hashes are in “Rename rebuild” below.
- **Board test:** the default freeze/bank pair was tested on 2026-10-29
  (LCD, UART, Terminal, camera/GUI switch). The second-framebuffer variant's
  board A/B test is still pending. The only TF card was temporarily overwritten
  with the GUI image; its Y1/camera image is backed up (`74b029c0…`) and the
  restore is pending.
- **Isolation:** reference `VexiiYeshenLinux` moved again (observed `903c787e`,
  concurrent eth session), baseline remains `212d3a2`; `verify_isolation.sh`
  therefore reports the moved HEAD/index. Neither this project nor R8 wrote the
  reference; no baseline re-record was made.

## Rename rebuild (2026-10-28)

The project and its RTL copies were renamed `VexiiGui*` → `YeshenGui*`. The
host simulator and both board apps/images were rebuilt; the two bitstreams are
unchanged (RTL comments only). Current artifacts:

| Artifact | Default (freeze/bank) | Variant (second framebuffer) |
|---|---|---|
| yshell | `1be37d31…`, 1,215,056 B (Terminal) | `d0025765…`, 1,200,500 B |
| rootfs | `rootfs_gui.cpio.gz` 2,140,156 B, 399 members | `rootfs_gui2.cpio.gz` 2,133,312 B, 399 members |
| image | `sd_gui.img` `f4dfc96d…`, 8,357,376 B (16,323 blocks) | `sd_gui2.img` `2d250fcf…`, 8,350,720 B (16,310 blocks) |
| sbit | `7092e495…`, 9,188,552 B | `4ada3e7b…`, 9,188,552 B |

The default image was rebuilt with `GUI_VARIANT=default_snapshot` from the
existing `images/` inputs (reference not read); the gui2 image uses its normal
snapshot path. Host build and `tests/run_tests.sh` pass; the host screenshot
shows `YeshenGui S1`. Both rootfs images contain the renamed yshell and no old
`VexiiGui` strings. Pairing remains: default = `sd_gui.img` + `7092e495…`;
variant = `sd_gui2.img` + `4ada3e7b…`.

**Terminal update (2026-10-29):** the default yshell/rootfs/image were rebuilt
with the Phase S6 PTY terminal (`1be37d31…`, 1,215,056 B; image `f4dfc96d…`,
8,357,376 B). The variant app/image are unchanged. Host `--terminal-test`
passes; on the board the terminal opened a real `/dev/pts/0` with a `sh` child
of `yshell`; UART typing and the LCD were confirmed. The board test used a RAM
copy of the new yshell, not a card write.

## Acceptance

- Camera writes/frame counter continue in GUI mode (unlike freeze/bank).
- GUI buffer isolated at `0x9200_0000`; source mux latched at frame start; no mid-frame tearing.
- On-chip: no extra `rd_buf` line buffer/DRM; only address mux/register/source latch.
- Bitstreams unchanged; images were rebuilt after the rename (see Rename rebuild); original Vexii zero changes; isolation baseline remains stale.
- Board behavior is a separate A/B item, not claimed before hardware.

## Risks

| Risk | Mitigation |
|---|---|
| Read-address mux wrong/aliasing | Simulation with camera/GUI sources; frame-start latch; check DDR addresses |
| DDR traffic in GUI (camera writes + LCD reads) | Camera ~44MB/s + LCD ~73MB/s; DDR ~500MB/s; measure arbiter/board |
| GUI buffer tear while drawing | Static desktop accepted; double GUI buffer/0x9300_0000 later if needed |
| Pairing mismatch | Distinct `sd_gui2.img`/yshell variant; never mix with freeze/bank |
| PnR timing/resource | Run dev_map/PnR; report actual; no false pass |
