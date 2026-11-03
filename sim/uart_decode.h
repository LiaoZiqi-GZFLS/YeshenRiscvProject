// ===================== UART 线上解码器（tb 共用，M4/T2 新增）=====================
// 为什么需要它：控制台是**串行线**，判据必须从 `io_console_txd` 的波形里把字节解出来，
// 而不是"相信固件写了 THR"。位周期 P 由 DT 的 (clock-frequency, current-speed) 按 OpenSBI 的
// 同一条公式算出（`lib/utils/serial/uart8250.c:119-122`：
//     bdiv = (in_freq + 8*baud) / (16*baud)   ⇒   P = 16 * bdiv
// ），并用"最短低/高脉冲"做**自证**（防止解码器与 RTL 一起错）。
//
// 帧格式（复用既有 UARTTx，spec §5.5）：起始(低) + 8 数据(LSB 先) + 校验格 + 停止(高)
// = 11 个位元格。数据位 k（1..8）在中点采样：t0 + (k+0.5)*P；停止位在 t0 + 10.5*P。
//
// 用法：
//   UartDecoder d; d.P = 16 * 5;
//   uint8_t b; if (d.step(dut->io_console_txd, cyc, b)) { ... }
#pragma once
#include <cstdint>
#include <climits>
#include <string>

struct UartDecoder {
    long P = 80;                  // 位周期（拍）：16 * bdiv（DT 声明 1.152 Mbaud ⇒ bdiv=5）
    int  state = 0;               // 0=找起始沿, 1=帧内采样
    uint64_t t0 = 0, next_at = 0;
    int  k = 1;                   // 下一个要采的位：1..8 数据, 9 = 停止
    uint8_t acc = 0;
    int  frames = 0, stop_errors = 0;
    int  min_low = INT_MAX, min_high = INT_MAX;   // 波形自证
    int  last_level = 1; uint64_t last_edge = 0;
    std::string text;             // 解出的可打印字符（拼成整段输出）

    // 每拍调用一次（在 clk=0 相位、`eval()` 之后）；返回 true 表示本拍解出一个字节
    bool step(int level, uint64_t cyc, uint8_t& out) {
        if (level != last_level) {
            if (last_edge != 0) {                 // 首个边沿前的那段不算（可能是仿真起点）
                uint64_t w = cyc - last_edge;
                if (last_level == 0) { if ((int)w < min_low)  min_low  = (int)w; }
                else                 { if ((int)w < min_high) min_high = (int)w; }
            }
            last_edge = cyc; last_level = level;
            if (state == 0 && level == 0) {       // 起始位下降沿
                state = 1; t0 = cyc; k = 1; acc = 0;
                next_at = t0 + (uint64_t)((k + 0.5) * P);
            }
        }
        if (state == 1 && cyc >= next_at) {
            if (k <= 8) {
                if (level) acc |= (uint8_t)(1u << (k - 1));      // LSB 先
                k++;
                next_at = (k <= 8) ? t0 + (uint64_t)((k + 0.5) * P)
                                   : t0 + (uint64_t)(10.5 * P);  // 停止位
            } else {
                if (!level) stop_errors++;
                state = 0; frames++;
                // ⚠️ 必须**留下换行**（2026-09-20 实测修）：原来只收可打印字符（0x20..0x7E），
                // 于是 `text` 里一个 '\n' 都没有 ⇒ 调用方按行增量刷出（`console_flush_lines`
                // 找最后一个 '\n'）**永远刷不出任何东西**，卡死的运行在日志里就是一片空白——
                // 只有进程正常退出时打印的整段 dump 才有内容。判据（text_has）本身不受影响，
                // 因为它是按无换行的拼接串做子串匹配；受影响的是"卡死时的取证"。
                // 顺带留下 '\r'（0x0D）：控制台按 CRLF 输出，丢掉它会把行尾信息也抹掉。
                if ((acc >= 0x20 && acc < 0x7F) || acc == '\n' || acc == '\r')
                    text.push_back((char)acc);
                out = acc;
                return true;
            }
        }
        return false;
    }

    // 波形自证：**最短**低/高脉冲必须落在位周期的整数倍附近（±25%）。
    // ⚠️ 不能写死"等于 P"：一串同值位会把脉冲拉到 k*P（例如 0xF0 会连着 4 个 1）；
    //    但**非整数倍**的短脉冲（tick 级别的毛刺，如 P/4、P/2）必须被拒 —— 那正是
    //    "两个 tick 分频算错"的特征。
    static bool near_multiple(long w, long P) {
        long k = (w + P / 2) / P;
        if (k < 1) return false;
        return w > k * P - P / 4 && w < k * P + P / 4;
    }
    bool waveform_ok() const {
        return min_low != INT_MAX && min_high != INT_MAX &&
               near_multiple(min_low, P) && near_multiple(min_high, P);
    }
    bool text_has(const char* s) const { return text.find(s) != std::string::npos; }
};
