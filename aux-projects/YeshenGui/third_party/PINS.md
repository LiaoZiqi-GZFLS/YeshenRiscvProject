# Third-party pins

| Package | Version | Source | Commit |
|---|---|---|---|
| LVGL | v9.2.0 | https://github.com/lvgl/lvgl.git | `aa7446344c6ec7631112ef031983ef24077e24d5` (`v9.2.0^{commit}`; enforced by `scripts/fetch_lvgl.sh`) |

`scripts/fetch_lvgl.sh` refuses to write `third_party/lvgl.commit` unless the
tag and `HEAD` both resolve to this exact OID and the tracked tree is clean.
A moved upstream tag or a dirty checkout is reported instead of silently
recording a new pin.

`third_party/lvgl.commit` records the last successful verification. A failed
run leaves any existing file untouched, so treat it as stale after a failure
and re-run the fetch script before relying on it.
