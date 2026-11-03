#!/usr/bin/env python3
"""结构判据：同一个设计的网表集合里**不得有重名 module 定义**。

为什么需要它（Y1-DMA Phase-2b 的实测教训）：
  PDS 的 `compile` 按**整个设计**（所有 add_design 进来的源文件）建模块符号表，
  同名 module 出现两次即报
    `E: Verilog-4146: [...] Duplicate module name 'DdrMaster' is not allowed.`
    `E: Parsing ERROR.` -> `Run process "Compile" failed, exit code: 1.`
  本次的现场：`y1/gen/DmaEngine.v` 内联了一份 `module DdrMaster`（每个通道一台），
  而 `y1/gen/NpuTop.v` 也内联了一份 `module DdrMaster` —— 两份 SpinalHDL 网表各自
  单文件落盘时**各自合法**，进同一个设计就撞名。
  **根因是 SpinalHDL 的"子组件内联"**：顶层组件把子组件展平进同一个 .v，子组件的
  模块名 = 它的类自动命名（无工程级唯一性）。修法与先例见 NpuMemCdc/NpuAxiLiteCdc
  （把子组件定义名参数化，`setDefinitionName`）。

★ 这是**整套设计**的判据，不是单文件的。单文件内部若有同名重复（例如生成期意外）
  本脚本同样会报出来（同一文件也算重名）。

用法（默认从 PnR tcl 反推源清单，最耐久；也可显式给文件）：
  check_dup_modules.py                       # 默认 --tcl y1/pds/pnr_c4a.tcl
  check_dup_modules.py --tcl <some.tcl>
  check_dup_modules.py <a.v> <b.v> ...       # 显式清单
退出码: 0 = PASS（无重名）；1 = FAIL（有重名）；2 = 输入/解析问题。

解析口径（与 check_dangling.py 同源，先剥 `/* */` 与 `//`）：
  * 定义：行首 `module <name>`（SystemVerilog 的 `module x #(` / `module x (` 都命中）。
  * 只统计**定义**，不看例化 —— 本判据问的是"模块名有没有被定义两次"。

tcl 反推口径：把 `add_design "..."` 的引号串与 `glob -nocomplain "PATTERN"` 的 pattern
  里的 `$root/$board_dir/$rtl_dir/$ip_dir` 变量替换掉（这几个变量在 tcl 里 `set` 出来），
  含 `*` 的做 glob 展开；只保留实际存在的文件。
"""
import argparse
import glob as globmod
import os
import re
import sys
import collections

RE_MODULE_DEF = re.compile(r"^\s*module\s+([A-Za-z_][\w$]*)", re.M)
RE_SET_VAR = re.compile(r'^\s*set\s+(\w+)\s+"([^"]*)"\s*$', re.M)
RE_ADD_DESIGN = re.compile(r'add_design\s+"([^"]+)"')
RE_GLOB = re.compile(r'glob\s+-nocomplain\s+"([^"]+)"')


def strip_comments(txt):
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
    txt = re.sub(r"//[^\n]*", "", txt)
    return txt


def modules_in(path):
    """返回该文件里出现的所有 module 定义名（含重复出现的次数）。"""
    raw = open(path, encoding="utf-8", errors="replace").read()
    return RE_MODULE_DEF.findall(strip_comments(raw))


def sources_from_tcl(tcl_path):
    raw = open(tcl_path, encoding="utf-8", errors="replace").read()
    var = dict(RE_SET_VAR.findall(raw))

    def subst(s):
        # tcl 变量可互相引用（`set board_dir "$root/board"`）⇒ 迭代展开到不动点。
        for _ in range(8):
            def rep(m):
                return var.get(m.group(1), m.group(0))
            new = re.sub(r"\$(\w+)", rep, s)
            if new == s:
                break
            s = new
        return s

    files = []
    for pat in RE_ADD_DESIGN.findall(raw) + RE_GLOB.findall(raw):
        p = subst(pat)
        if "*" in p or "?" in p:
            files.extend(sorted(globmod.glob(p)))
        else:
            files.append(p)
    # 去重保序
    seen, uniq = set(), []
    for f in files:
        if f not in seen:
            seen.add(f)
            uniq.append(f)
    return uniq


def resolve(paths, root):
    out = []
    for p in paths:
        p = p.replace("\\", "/")
        if not os.path.isabs(p):
            p = os.path.join(root, p)
        if os.path.isfile(p):
            out.append(os.path.normpath(p))
    return out


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.dirname(os.path.dirname(here))          # repo root
    default_tcl = os.path.join(default_root, "y1", "pds", "pnr_c4a.tcl")
    ap.add_argument("--tcl", default=None,
                    help="从 PnR tcl 反推源清单（默认 %s）" % default_tcl)
    ap.add_argument("--root", default=default_root,
                    help="相对路径的根（默认 %s）" % default_root)
    ap.add_argument("files", nargs="*", help="显式源文件清单（给了就不看 tcl）")
    a = ap.parse_args(argv)

    if a.files:
        files = resolve(a.files, a.root)
        srcdesc = "explicit list (%d given)" % len(a.files)
    else:
        tcl = a.tcl or default_tcl
        if not os.path.isfile(tcl):
            print("FATAL: 找不到 tcl: %s" % tcl)
            return 2
        files = sources_from_tcl(tcl)
        srcdesc = "tcl: %s" % tcl

    if not files:
        print("FATAL: 源清单为空")
        return 2

    owner = collections.defaultdict(list)     # module name -> [file, ...]
    total_defs = 0
    for f in files:
        try:
            names = modules_in(f)
        except OSError as e:
            print("FATAL: 读不了 %s: %s" % (f, e))
            return 2
        total_defs += len(names)
        for n in names:
            owner[n].append(f)

    print("source set: %s" % srcdesc)
    print("files: %d | module definitions: %d | distinct module names: %d"
          % (len(files), total_defs, len(owner)))

    dups = {n: fs for n, fs in owner.items() if len(fs) > 1}
    if not dups:
        print("--- no duplicate module names ---")
        print("RESULT: PASS")
        return 0

    print("--- DUPLICATE MODULE NAMES ---")
    for n in sorted(dups):
        print("  %-28s x%d" % (n, len(dups[n])))
        for f in dups[n]:
            print("      %s" % f)
    print("RESULT: FAIL (%d duplicated module name(s))" % len(dups))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
