# Touch/OSK board bring-up (T5)

Status: **touch works (2026-10-30).** Return key is physical **KEY4 (B20)**; the
silkscreen KEY3 (A22) is **not wired** in this RTL. **Flash touch2 and do not
press reset** (reset clears the bitstream; SdLoader auto-reboots after
cfg_program). goodix is at 0x14; S99leds must
not run.** The first two board boots failed with `-6`: (1) J26 has no SCL
pull-up, so CTP_SCL must be push-pull (fixed in `touch2` sbit
`85dbe37d…`); (2) the reference `S99leds.sh` writes the whole GPIO
DATA_OUT each second and clears CTP_RST/SCL/SDA, holding the panel in
reset; (3) gpiolib emulates `GPIO_OPEN_DRAIN` by switching the line to
**input** for a high level, so an open-drain SCL never rises. With RST
released, a userspace `/dev/mem` scan ACKs **only at 0x14** and reads
GT911 ID `3931` (0x5D is NAK); the FPGA INT pin is input-only, so the
panel straps 0x14. DTS now uses `touchscreen@14`, `scl-gpios` without
OPEN_DRAIN, and the gpiochip releases CTP_RST in probe; the touch rootfs
removes `S99leds.sh`. The new image still needs a card write.

Run only inside a user-provided board window. The camera card backup
(`build/tf_camera_backup_full.img`, sha256 `74b029c0…`) must remain intact.

## Pair (never mix)

| Part | Value |
|---|---|
| Bitstream | `YeshenGuiTouch` sbit `85dbe37d…` (9,188,552 B), `All Constraints Met`, min Setup Slow +0.215 ns |
| SD image | `images/sd_gui_touch.img` (8,430,080 B, sha256 `a303229b…`) |
| Rootfs | `images/rootfs_gui_touch.cpio.gz` (2,152,234 B, sha256 `4f37cf8e…`) |
| DTB | `images/linux_touch.dtb` (3,027 B, sha256 `c4a84264…`) |
| Kernel | `images/Image.touch` (6,139,476 B, sha256 `1f6e8055…`) |
| App | yshell 1,233,612 B, sha256 `5ce2f536…` |

Default (`sd_gui.img` + `7092e495…`) and gui2 (`sd_gui2.img` + `4ada3e7b…`)
pairs are unchanged and must not be used with this kernel/bitstream.

## 1. Flash the touch bitstream

Use the normal `cdt_js` + `cdt_cfg_shell` flow. The sbit is stored under the
`touch2` tag; the tcl defaults to `m9`, so set the tag explicitly:

```bat
C:\Pango\PDS_2025.2-ads\bin\cdt_js.exe -port 62000
C:\Pango\PDS_2025.2-ads\bin\cdt_cfg_shell.exe -file D:/code/PDS/YeshenGuiTouch/pds/flash_yeshen.tcl
```

with `YESHENMINI_TAG=touch2` and `YESHENMINI_JTAG_PORT=62000` in the
environment (absolute tcl path; relative paths have failed before). Expected:
`configure situation`/`done bit`; after power-on the LCD shows the desktop
(pair sbit `85dbe37d…`).

## 2. Write the card (only with the camera backup verified)

Put the card in the reader, then inside WSL:

```bash
cd /mnt/d/code/PDS/YeshenGui
TF_DEV=/dev/sdc bash scripts/write_tf_touch.sh
```

The script refuses to run unless the card size is 7,761,920 KB, the camera
backup hash is `74b029c0…`, and the touch image hash is `a303229b…`; it
read-backs the written 16,465 blocks before reporting
`TF_TOUCH_WRITE_OK`.

## 3. Boot and confirm the input stack

1. Insert the card, connect UART (115200 8N1), power on, log in `root` /
   `yeshen`.
2. Check:

```sh
dmesg | grep -i -E 'goodix|gpio-keys|i2c-gpio|ctp'
ls -l /dev/input
cat /sys/class/input/event*/device/name
```

Expected: a `Goodix Capacitive TouchScreen` event node and a `KEY3 camera
return` node; no interrupt storm. Expected address is **0x14** (ID `3931`); 0x5D is NAK on this panel.
If goodix still reports `I2C communication failure`, first confirm the
rootfs has no `S99leds.sh` and that `devmem 0xF0002004` keeps bit 10 high.

## 4. Calibrate with `--touch-probe`

```sh
/root/gui/yshell --touch-probe 20
```

Touch the four corners, the centre, then KEY3. Record the UART lines:

```text
TOUCH abs x=… y=… keys=1
TOUCH raw=… scaled=… pressed=1
TOUCH key3 press
```

Check that `scaled` maps the physical corners to 0..1023 / 0..599 in the
expected orientation. If X/Y are swapped or mirrored, the mapping goes in
`platform/board_touch.c` (`platform_poll_touch`) — do not patch RTL for a
coordinate transform.

## 5. GUI acceptance

```sh
/root/gui/yshell
```

- Touch desktop icons: Files, System, Settings, Games, Terminal open.
- Terminal focus shows the OSK; tap `l`,`s`,`1#` (for digits), Enter; run
  `uname -a`; use `Ctrl+C` on `sleep 100`; `Hide` hides the OSK; hardware
  UART keys still type into the shell.
- Press `c` (UART) to enter camera mode; the LCD shows the camera. Touch and
  hold the top-left 64×64 area for 2 s → GUI returns and redraws. Repeat with
  KEY3. KEY3 in GUI mode must do nothing (it never enters camera mode).
- No mid-frame tearing, no unplug of J10.

## 6. Restore the camera card

Put the card back in the reader:

```bash
wsl bash /d/code/PDS/YeshenGui/build/restore_tf.sh
```

Expected: `TF_RESTORE_OK 74b029c0…` with the same 20,935 blocks.

## Board session record

| Field | Value |
|---|---|
| Date / operator | |
| Touch sbit sha256 | `85dbe37d…` |
| `sd_gui_touch.img` sha256 | `a303229b…` |
| `dmesg` goodix / event nodes | |
| Probe raw/scaled (corners/centre) | |
| OSK / Ctrl+C / Hide | |
| Camera `c` + hot corner + KEY3 | |
| Restore result | |
