# 厂家视频资产（只读复制件）

来源：`D:/code/PDS/cam2lcd_200mini`（cam2lcd2 交付，2026-10-04，板级验收通过）。
复制日期：2026-10-19。参考仓库保持零改动（复制前后 sha256 全量对比一致）。

允许的本地改动（且仅此一处）：
- `vendor/tutorial/rd_buf.v`：新增 `ROW_OFFSET` 参数（显示窗口起始行 60）。
- `vendor/tutorial/fram_buf.v`：透传 `ROW_OFFSET`。
- `vendor/camera/data_init.v`：手动增益 1x→8x（暗环境演示提亮；寄存器 0x350B 0x10→0x80）。

其余文件逐字节与来源一致。11 条历史根因（整流级/负边沿采样/短行回滚/消隐判帧尾/
DUTYx==RATIOx/双 bank 反相读等）见来源 `DELIVERY_REPORT.md` §4，**不得"顺手清理"**。
