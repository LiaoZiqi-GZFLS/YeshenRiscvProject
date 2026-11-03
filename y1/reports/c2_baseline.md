# C2.0 前置基线：既有 SoC 的判据与指纹

- 日期：2026-10-08
- 用途：C2.2 会改 `src/YeshenSocGlue.scala` ⇒ **重生成整块 SoC 网表**（设计文档 R3）。本文件是"after"要逐条对比的 **before**。

---

## 1. 台账闸门（J4）—— 修好之后才是有效基线

### 1.1 发现：**继承的开放缺陷（不是我引入的）**

C2.0 第一次跑 `scripts/check_addr_map.py` 就是红的：

```
FAIL: address ledger mismatch
  - NaxSocMini CLINT_BASE: file not found: rtl/NaxSocMini.v
```

十项检查里 **9 项通过、1 项因文件缺失而红**。根因：那一项指向 **Nax 时代的文件名** `rtl/NaxSocMini.v`，而本仓 `rtl/` 只有 `{DDR3Bridge.v, YeshenSocGlue.v, vexiiriscv/}` —— **Vexii 迁移后该文件就不存在了**。

⇒ **这个闸门从 Vexii 迁移起就一直是红的**（它只是"响亮地红"，而在这之前没有任务跑到它）。**这是继承缺陷，不是回归**；按纪律先如实记录、再修。

### 1.2 修法：**重定向到当前权威来源**（同脚本既有风格），不是删检查

脚本自己的 `CONSOLE_BASE` 那一项就是 grep `src/NaxMiniGlue.scala` 里的常量声明。CLINT 那一项本该同样 grep **当前胶合**的 `CLINT_BASE`（本仓 `src/YeshenSocGlue.scala:99` 确有 `val CLINT_BASE = 0xF0010000L`）。

改动 = **唯一一处**：

```diff
-check("NaxSocMini CLINT_BASE", "rtl/NaxSocMini.v",
-      r"addrKey & 32'hffff0000\)\s*==\s*32'h([0-9a-fA-F]+)\)", EXPECT["CLINT_BASE"],
-      "上游 NaxSoc 的 CLINT 解码（唯一一处 0xFFFF0000 掩码窗口）", radix=16)
+check("glue CLINT_BASE", "src/YeshenSocGlue.scala",
+      r"CLINT_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["CLINT_BASE"],
+      "YeshenSocGlue 的 CLINT 解码窗（Vexii 迁移后 CLINT 由胶合内的 ClintAlite 提供）")
```

（`EXPECT` 表**一字未动** —— 台账期望值本身没有错，错的是"谁去认领它"。）

### 1.3 修复后的**双向负对照**（证明重定向后的检查有牙，不是"找到个数字就算过"）

| 实验 | 期望 | 实测 |
|---|---|---|
| **正向**：期望值与源文件都对 | PASS | `PASS: address ledger consistent (10 sites reconciled)`，exit 0 ✔ |
| **负对照 A**：只把 `EXPECT["CLINT_BASE"]` 改成 `0xF0011000`（源文件不动） | 报红并点名 | `FAIL: glue CLINT_BASE: src/YeshenSocGlue.scala has 0xF0010000, ledger requires 0xF0011000`，exit 1 ✔ |
| **负对照 B**：只把**源文件**的常量改成 `0xF0012000`（期望值不动） | 报红并点名 | `FAIL: glue CLINT_BASE: src/YeshenSocGlue.scala has 0xF0012000, ledger requires 0xF0010000`，exit 1 ✔ |
| 还原源文件后重跑 | 回绿 | `PASS (10 sites reconciled)`，exit 0 ✔；源文件 md5 与备份一致（自证未留残改） |

⇒ 该检查**同时读源文件、比台账**，两个方向都能红。

> 注：负对照第一次我做到 `/tmp` 下失败了 —— 因为脚本的 `ROOT` 是从**脚本自身位置**推的，放到 `/tmp` 会让所有路径都找不到。那是**我的调用姿势**问题，不是检查没牙；已改为在仓内同层放副本。

### 1.4 修复后的基线值

```
PASS: address ledger consistent (10 sites reconciled)
```
**after** 必须同样是这一行（站点数从 9→10 是因为 CLINT 那项从"报缺失"变成"真读到了"）。

---

## 2. SoC 侧产物指纹（C2.2 改胶合后必须对比）

| 项 | before 值 |
|---|---|
| `rtl/YeshenSocGlue.v` | **md5 `9c9107b712fdaea08019487456519cc8`**，135,447 B，mtime 2026-10-07 23:10 |
| 最近一份 SoC devmap 日志 | `sim/reglogs/m_yeshen_devmap.log`（2026-10-07 20:52；其 LUT 14,130.5 / FF 17,124 / APM 4 / DRM 23.5 就是 SoC 资源基线） |
| 更早的同族日志 | `m8_devmap.log`（10-07 19:41）、`m7_devmap.log`（10-07 18:27） |

**C2.3 的要求**：改胶合后 `rtl/YeshenSocGlue.v` 的 md5 **必须变**（改了就该变）；**若没变 ⇒ 说明改动没进生成链，停下查**。

---

## 3. 本文件确立的回归纪律

C2.2 落地后，以下三样**必须重跑并与本文件逐条对比**，且要能区分"**我引入的回归**"与"**继承的缺陷**"：

1. `python scripts/check_addr_map.py` → 必须仍是 `PASS (10 sites reconciled)`；
2. `rtl/YeshenSocGlue.v` 的 md5 → 必须变（并记录 after 值）；
3. SoC devmap 的资源四项 → 与 `m_yeshen_devmap.log` 对比，**增加的部分要能归因到 NPU**。
