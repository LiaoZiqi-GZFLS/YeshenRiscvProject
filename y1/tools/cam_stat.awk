{
  for (i = 1; i <= NF; i++) {
    v = $i
    r = int(v / 2048); g = int(v / 32) % 64; b = v % 32
    sr += r; sg += g; sb += b
    if (v == 0) nz++
    x = idx % 640; y = int(idx / 640)
    t = int(y / 80) * 8 + int(x / 80)
    tr[t] += r; tg[t] += g; tb[t] += b
    idx++
  }
}
END {
  printf "N=%d ZERO=%d MEAN=%d,%d,%d\n", idx, nz, sr/idx, sg/idx, sb/idx
  for (ty = 0; ty < 8; ty++) {
    line = ""
    for (tx = 0; tx < 8; tx++) {
      t = ty * 8 + tx
      line = line sprintf("%d,%d,%d ", tr[t]/6400, tg[t]/6400, tb[t]/6400)
    }
    print line
  }
}
