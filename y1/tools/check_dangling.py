#!/usr/bin/env python3
"""B9b 结构判据：网表里不得有「被例化但没有模块定义」的悬空实例。

为什么需要它（B9 的教训）：
  `tools/check_no_xilinx.sh` 是**按名字**判的（`xpm_*` / `dsp_macro` / `mult_gen` /
  `blk_mem_gen` / `c_addsub` / `axis_dwidth_converter` / `create_ip` / `get_ips`）。
  而 SpinalHDL 对 BlackBox **只发实例、且用 `componentName` 当模块名**
  （`AddZero addZero_0 (...)`），**从不写 IP 的本名** ⇒ 名字判据看不见「只发实例、
  没有模块体」的悬空黑盒。B9 结束时正是这种状态：113 处实例 / 0 份定义，判据却 PASS。
  本判据改为**结构口径**：把「模块定义集合」与「被例化的模块名集合」各自解析出来，
  凡「被例化 ∉ 已定义」即悬空 ⇒ FAIL。它对 `componentName` 命名的黑盒同样有效。

用法: check_dangling.py <verilog_file> [<verilog_file> ...]
退出码: 0 = PASS（零悬空）；1 = FAIL（有悬空）；2 = 输入/解析问题。

解析口径（只认「真代码」，先剥 `/* */` 与 `//`）：
  * 定义：行首 `module <name>`；模块名进 defined 集合。
  * 例化：
      - `  <mod> <inst> (`                  （普通例化，SpinalHDL 的产物长这样）
      - `  <mod> #(`                        （带参数例化，如 xpm_cdc_gray #(...)）
    只匹配行首标识符开头的行，且把 Verilog 关键字（assign/if/wire/...）排除，
    避免把 `assign x = f(a);`、`if (...) begin`、`reg [3:0] y;` 之类误判为例化。
  * `endmodule` 之外的任何「未定义模块名」都算悬空。
"""
import re
import sys
import collections

# Verilog-2001 / SystemVerilog 关键字里**可能出现在行首**、且会被「<ident> <ident> (」误命中者。
KEYWORDS = {
    "assign", "always", "always_comb", "always_ff", "always_latch", "initial",
    "if", "else", "case", "casex", "casez", "endcase", "begin", "end",
    "wire", "reg", "logic", "bit", "signed", "unsigned", "integer", "genvar",
    "real", "time", "realtime", "byte", "shortint", "int", "longint",
    "input", "output", "inout", "parameter", "localparam", "defparam", "specparam",
    "module", "endmodule", "generate", "endgenerate", "for", "while", "repeat",
    "function", "endfunction", "task", "endtask", "specify", "endspecify",
    "default", "return", "forever", "do", "break", "continue", "typedef", "enum",
    "struct", "union", "packed", "supply0", "supply1", "tri", "triand", "trior",
    "wand", "wor", "buf", "not", "and", "nand", "or", "nor", "xor", "xnor",
    "table", "endtable", "primitive", "endprimitive", "assert", "assume",
    "property", "endproperty", "typedef_struct", "import", "export", "package",
}

RE_MODULE_DEF = re.compile(r"^\s*module\s+([A-Za-z_][\w$]*)", re.M)
RE_INST_NAMED = re.compile(r"^\s*([A-Za-z_][\w$]*)\s+([A-Za-z_][\w$]*)\s*\(")
RE_INST_PARAM = re.compile(r"^\s*([A-Za-z_][\w$]*)\s*#\s*\(")


def strip_comments(txt: str) -> str:
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
    txt = re.sub(r"//[^\n]*", "", txt)
    return txt


def analyse(path: str):
    raw = open(path, encoding="utf-8", errors="replace").read()
    txt = strip_comments(raw)
    defined = set(RE_MODULE_DEF.findall(txt))
    inst = collections.Counter()
    for line in txt.splitlines():
        m = RE_INST_NAMED.match(line)
        if m:
            mod, _inst = m.group(1), m.group(2)
            if mod in KEYWORDS:
                continue
            inst[mod] += 1
            continue
        m = RE_INST_PARAM.match(line)
        if m:
            mod = m.group(1)
            if mod in KEYWORDS:
                continue
            inst[mod] += 1
    return defined, inst


def main(argv):
    if len(argv) < 2:
        print("usage: check_dangling.py <verilog_file> [...]")
        return 2
    ok_all = True
    for path in argv[1:]:
        try:
            defined, inst = analyse(path)
        except OSError as e:
            print(f"FATAL: 读不了 {path}: {e}")
            return 2
        dangling = {k: v for k, v in inst.items() if k not in defined}
        total_dangling = sum(dangling.values())
        print(f"file: {path}")
        print(f"defined modules: {len(defined)} | distinct instantiated: {len(inst)}")
        if dangling:
            print("--- INSTANTIATED BUT UNDEFINED (dangling) ---")
            for name in sorted(dangling):
                print("  %-28s x%d" % (name, dangling[name]))
        else:
            print("--- no dangling instances ---")
        print(f"total dangling instances: {total_dangling}")
        if total_dangling == 0:
            print("RESULT: PASS")
        else:
            print("RESULT: FAIL")
            ok_all = False
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
