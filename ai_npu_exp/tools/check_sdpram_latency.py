import re, sys
sys.stdout.reconfigure(errors="replace")
# usage: check_sdpram_latency.py <verilog> <expected_TOTAL_latency>
#
# 契约：doutb(t) = mem[addrb(t - expected)]，total = 1（存储器同步读自带的一拍）
#                                                 + doutPipe_<n> 的级数。
# 判两件事：
#   1) 资源结构（硬失败）：module sdpram 体内必须有 ram_style = "block"，且**不能**有
#      ram_style = "distributed"。distributed 意味着 LUTRAM —— 4.7Mbit 权重 RAM 装不下，
#      无论延迟对不对都必须 FAIL。
#   2) 总延迟：detected = 1 + 不同 doutPipe_<n> 索引的个数，与 expected 相等。
path, exp = sys.argv[1], int(sys.argv[2])
txt = open(path, encoding="utf-8", errors="replace").read()
m = re.search(r"module\s+sdpram\b(.*?)\bendmodule", txt, re.S)
if not m:
    print("FAIL: cannot find the sdpram module body"); sys.exit(2)
body = m.group(1)

styles = re.findall(r'ram_style\s*=\s*"([^"]*)"', body)
has_block = ("block" in styles)
has_distributed = ("distributed" in styles)

idx = sorted({int(i) for i in re.findall(r"doutPipe_(\d+)", body)})
detected = 1 + len(idx)
print(f"expected={exp} detected={detected} indices={idx} ram_style={styles}")

lat_ok = (detected == exp) and (idx == list(range(exp - 1)))
res_ok = has_block and not has_distributed

if has_distributed:
    print('RESULT: FAIL (resource: ram_style = "distributed" present -- this can never be BRAM)')
elif not has_block:
    print('RESULT: FAIL (resource: no ram_style = "block" in the module body)')
elif not lat_ok:
    print("RESULT: FAIL (latency: detected != expected)")
else:
    print("RESULT: PASS")

sys.exit(0 if (res_ok and lat_ok) else 1)
