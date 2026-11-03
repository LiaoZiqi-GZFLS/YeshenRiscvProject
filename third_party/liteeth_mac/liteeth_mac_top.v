/* Machine-generated using Migen */
module liteeth_mac_top(
	input clock_pads_rx,
	input clock_pads_tx,
	input clock_pads_gtx,
	output reg [7:0] pads_tx_data,
	output reg pads_tx_en,
	input [7:0] pads_rx_data,
	input pads_rx_dv,
	input pads_rx_er,
	input [29:0] bus_rx_adr,
	input [31:0] bus_rx_dat_w,
	output [31:0] bus_rx_dat_r,
	input [3:0] bus_rx_sel,
	input bus_rx_cyc,
	input bus_rx_stb,
	output bus_rx_ack,
	input bus_rx_we,
	input [2:0] bus_rx_cti,
	input [1:0] bus_rx_bte,
	output bus_rx_err,
	input [29:0] bus_tx_adr,
	input [31:0] bus_tx_dat_w,
	output [31:0] bus_tx_dat_r,
	input [3:0] bus_tx_sel,
	input bus_tx_cyc,
	input bus_tx_stb,
	output bus_tx_ack,
	input bus_tx_we,
	input [2:0] bus_tx_cti,
	input [1:0] bus_tx_bte,
	output bus_tx_err,
	input [29:0] wb_csr_adr,
	input [31:0] wb_csr_dat_w,
	output reg [31:0] wb_csr_dat_r,
	input [3:0] wb_csr_sel,
	input wb_csr_cyc,
	input wb_csr_stb,
	output reg wb_csr_ack,
	input wb_csr_we,
	input [2:0] wb_csr_cti,
	input [1:0] wb_csr_bte,
	input wb_csr_err,
	output irq,
	input sys_clk,
	input sys_rst
);

wire eth_rx_clk;
wire eth_rx_rst;
wire eth_tx_clk;
wire eth_tx_rst;
wire sink_valid;
reg sink_ready = 1'd0;
wire sink_first;
wire sink_last;
wire [7:0] sink_payload_data;
wire sink_payload_last_be;
wire sink_payload_error;
reg source_valid = 1'd0;
wire source_ready;
reg source_first = 1'd0;
wire source_last;
reg [7:0] source_payload_data = 8'd0;
reg source_payload_last_be = 1'd0;
reg source_payload_error = 1'd0;
reg dv_d = 1'd0;
wire sys_rst_1;
reg [1:0] resetsync0_sr = 2'd0;
wire resetsync0_reset_out;
reg [1:0] resetsync1_sr = 2'd0;
wire resetsync1_reset_out;
wire core_sink_valid;
wire core_sink_ready;
wire core_sink_first;
wire core_sink_last;
wire [31:0] core_sink_payload_data;
wire [3:0] core_sink_payload_last_be;
wire [3:0] core_sink_payload_error;
wire core_source_valid;
wire core_source_ready;
wire core_source_first;
wire core_source_last;
wire [31:0] core_source_payload_data;
wire [3:0] core_source_payload_last_be;
wire [3:0] core_source_payload_error;
reg core_status = 1'd1;
wire core_we;
reg core_re = 1'd0;
wire core_tx_padding_sink_valid;
reg core_tx_padding_sink_ready;
wire core_tx_padding_sink_first;
wire core_tx_padding_sink_last;
wire [31:0] core_tx_padding_sink_payload_data;
wire [3:0] core_tx_padding_sink_payload_last_be;
wire [3:0] core_tx_padding_sink_payload_error;
reg core_tx_padding_source_valid;
wire core_tx_padding_source_ready;
reg core_tx_padding_source_first;
reg core_tx_padding_source_last;
reg [31:0] core_tx_padding_source_payload_data;
reg [3:0] core_tx_padding_source_payload_last_be;
reg [3:0] core_tx_padding_source_payload_error;
reg [15:0] core_tx_padding_counter = 16'd0;
wire core_tx_padding_counter_done;
wire core_tx_crc_sink_valid;
reg core_tx_crc_sink_ready;
wire core_tx_crc_sink_first;
wire core_tx_crc_sink_last;
wire [31:0] core_tx_crc_sink_payload_data;
wire [3:0] core_tx_crc_sink_payload_last_be;
wire [3:0] core_tx_crc_sink_payload_error;
reg core_tx_crc_source_valid;
wire core_tx_crc_source_ready;
reg core_tx_crc_source_first;
reg core_tx_crc_source_last;
reg [31:0] core_tx_crc_source_payload_data;
reg [3:0] core_tx_crc_source_payload_last_be;
reg [3:0] core_tx_crc_source_payload_error;
reg [31:0] core_tx_crc_crc_packet = 32'd0;
reg [3:0] core_tx_crc_last_be = 4'd0;
wire [31:0] core_tx_crc_data;
wire [3:0] core_tx_crc_be;
reg [31:0] core_tx_crc_value;
reg core_tx_crc_error;
wire [7:0] core_tx_crc_liteethmaccrcengine0_data;
wire [31:0] core_tx_crc_liteethmaccrcengine0_crc_prev;
reg [31:0] core_tx_crc_liteethmaccrcengine0_crc_next;
wire [15:0] core_tx_crc_liteethmaccrcengine1_data;
wire [31:0] core_tx_crc_liteethmaccrcengine1_crc_prev;
reg [31:0] core_tx_crc_liteethmaccrcengine1_crc_next;
wire [23:0] core_tx_crc_liteethmaccrcengine2_data;
wire [31:0] core_tx_crc_liteethmaccrcengine2_crc_prev;
reg [31:0] core_tx_crc_liteethmaccrcengine2_crc_next;
wire [31:0] core_tx_crc_liteethmaccrcengine3_data;
wire [31:0] core_tx_crc_liteethmaccrcengine3_crc_prev;
reg [31:0] core_tx_crc_liteethmaccrcengine3_crc_next;
reg [31:0] core_tx_crc_reg = 32'd4294967295;
reg core_tx_crc_ce;
reg core_tx_crc_reset;
wire core_tx_crc_sink_sink_valid;
wire core_tx_crc_sink_sink_ready;
wire core_tx_crc_sink_sink_first;
wire core_tx_crc_sink_sink_last;
wire [31:0] core_tx_crc_sink_sink_payload_data;
wire [3:0] core_tx_crc_sink_sink_payload_last_be;
wire [3:0] core_tx_crc_sink_sink_payload_error;
wire core_tx_crc_source_source_valid;
wire core_tx_crc_source_source_ready;
wire core_tx_crc_source_source_first;
wire core_tx_crc_source_source_last;
wire [31:0] core_tx_crc_source_source_payload_data;
wire [3:0] core_tx_crc_source_source_payload_last_be;
wire [3:0] core_tx_crc_source_source_payload_error;
wire core_tx_crc_pipe_valid_sink_valid;
wire core_tx_crc_pipe_valid_sink_ready;
wire core_tx_crc_pipe_valid_sink_first;
wire core_tx_crc_pipe_valid_sink_last;
wire [31:0] core_tx_crc_pipe_valid_sink_payload_data;
wire [3:0] core_tx_crc_pipe_valid_sink_payload_last_be;
wire [3:0] core_tx_crc_pipe_valid_sink_payload_error;
reg core_tx_crc_pipe_valid_source_valid = 1'd0;
wire core_tx_crc_pipe_valid_source_ready;
reg core_tx_crc_pipe_valid_source_first = 1'd0;
reg core_tx_crc_pipe_valid_source_last = 1'd0;
reg [31:0] core_tx_crc_pipe_valid_source_payload_data = 32'd0;
reg [3:0] core_tx_crc_pipe_valid_source_payload_last_be = 4'd0;
reg [3:0] core_tx_crc_pipe_valid_source_payload_error = 4'd0;
wire core_tx_preamble_sink_valid;
reg core_tx_preamble_sink_ready;
wire core_tx_preamble_sink_first;
wire core_tx_preamble_sink_last;
wire [31:0] core_tx_preamble_sink_payload_data;
wire [3:0] core_tx_preamble_sink_payload_last_be;
wire [3:0] core_tx_preamble_sink_payload_error;
reg core_tx_preamble_source_valid;
wire core_tx_preamble_source_ready;
reg core_tx_preamble_source_first;
reg core_tx_preamble_source_last;
reg [31:0] core_tx_preamble_source_payload_data;
wire [3:0] core_tx_preamble_source_payload_last_be;
reg [3:0] core_tx_preamble_source_payload_error;
reg [63:0] core_tx_preamble_preamble = 64'd15372286728091293013;
reg core_tx_preamble_count = 1'd0;
wire core_tx_cdc_sink_sink_valid;
wire core_tx_cdc_sink_sink_ready;
wire core_tx_cdc_sink_sink_first;
wire core_tx_cdc_sink_sink_last;
wire [31:0] core_tx_cdc_sink_sink_payload_data;
wire [3:0] core_tx_cdc_sink_sink_payload_last_be;
wire [3:0] core_tx_cdc_sink_sink_payload_error;
wire core_tx_cdc_source_source_valid;
wire core_tx_cdc_source_source_ready;
wire core_tx_cdc_source_source_first;
wire core_tx_cdc_source_source_last;
wire [31:0] core_tx_cdc_source_source_payload_data;
wire [3:0] core_tx_cdc_source_source_payload_last_be;
wire [3:0] core_tx_cdc_source_source_payload_error;
wire core_tx_cdc_cdc_sink_valid;
wire core_tx_cdc_cdc_sink_ready;
wire core_tx_cdc_cdc_sink_first;
wire core_tx_cdc_cdc_sink_last;
wire [31:0] core_tx_cdc_cdc_sink_payload_data;
wire [3:0] core_tx_cdc_cdc_sink_payload_last_be;
wire [3:0] core_tx_cdc_cdc_sink_payload_error;
wire core_tx_cdc_cdc_source_valid;
wire core_tx_cdc_cdc_source_ready;
wire core_tx_cdc_cdc_source_first;
wire core_tx_cdc_cdc_source_last;
wire [31:0] core_tx_cdc_cdc_source_payload_data;
wire [3:0] core_tx_cdc_cdc_source_payload_last_be;
wire [3:0] core_tx_cdc_cdc_source_payload_error;
wire core_tx_cdc_cdc_asyncfifo_we;
wire core_tx_cdc_cdc_asyncfifo_writable;
wire core_tx_cdc_cdc_asyncfifo_re;
wire core_tx_cdc_cdc_asyncfifo_readable;
wire [41:0] core_tx_cdc_cdc_asyncfifo_din;
wire [41:0] core_tx_cdc_cdc_asyncfifo_dout;
wire core_tx_cdc_cdc_graycounter0_ce;
(* no_retiming = "true" *) reg [11:0] core_tx_cdc_cdc_graycounter0_q = 12'd0;
wire [11:0] core_tx_cdc_cdc_graycounter0_q_next;
reg [11:0] core_tx_cdc_cdc_graycounter0_q_binary = 12'd0;
reg [11:0] core_tx_cdc_cdc_graycounter0_q_next_binary;
wire core_tx_cdc_cdc_graycounter1_ce;
(* no_retiming = "true" *) reg [11:0] core_tx_cdc_cdc_graycounter1_q = 12'd0;
wire [11:0] core_tx_cdc_cdc_graycounter1_q_next;
reg [11:0] core_tx_cdc_cdc_graycounter1_q_binary = 12'd0;
reg [11:0] core_tx_cdc_cdc_graycounter1_q_next_binary;
wire [11:0] core_tx_cdc_cdc_produce_rdomain;
wire [11:0] core_tx_cdc_cdc_consume_wdomain;
wire [10:0] core_tx_cdc_cdc_wrport_adr;
wire [41:0] core_tx_cdc_cdc_wrport_dat_r;
wire core_tx_cdc_cdc_wrport_we;
wire [41:0] core_tx_cdc_cdc_wrport_dat_w;
wire [10:0] core_tx_cdc_cdc_rdport_adr;
wire [41:0] core_tx_cdc_cdc_rdport_dat_r;
wire [31:0] core_tx_cdc_cdc_fifo_in_payload_data;
wire [3:0] core_tx_cdc_cdc_fifo_in_payload_last_be;
wire [3:0] core_tx_cdc_cdc_fifo_in_payload_error;
wire core_tx_cdc_cdc_fifo_in_first;
wire core_tx_cdc_cdc_fifo_in_last;
wire [31:0] core_tx_cdc_cdc_fifo_out_payload_data;
wire [3:0] core_tx_cdc_cdc_fifo_out_payload_last_be;
wire [3:0] core_tx_cdc_cdc_fifo_out_payload_error;
wire core_tx_cdc_cdc_fifo_out_first;
wire core_tx_cdc_cdc_fifo_out_last;
wire core_tx_converter_sink_valid;
wire core_tx_converter_sink_ready;
wire core_tx_converter_sink_first;
wire core_tx_converter_sink_last;
wire [31:0] core_tx_converter_sink_payload_data;
wire [3:0] core_tx_converter_sink_payload_last_be;
wire [3:0] core_tx_converter_sink_payload_error;
wire core_tx_converter_source_valid;
wire core_tx_converter_source_ready;
wire core_tx_converter_source_first;
wire core_tx_converter_source_last;
wire [7:0] core_tx_converter_source_payload_data;
wire core_tx_converter_source_payload_last_be;
wire core_tx_converter_source_payload_error;
wire core_tx_converter_converter_sink_valid;
wire core_tx_converter_converter_sink_ready;
wire core_tx_converter_converter_sink_first;
wire core_tx_converter_converter_sink_last;
reg [39:0] core_tx_converter_converter_sink_payload_data;
wire core_tx_converter_converter_source_valid;
wire core_tx_converter_converter_source_ready;
wire core_tx_converter_converter_source_first;
wire core_tx_converter_converter_source_last;
reg [9:0] core_tx_converter_converter_source_payload_data;
wire core_tx_converter_converter_source_payload_valid_token_count;
reg [1:0] core_tx_converter_converter_mux = 2'd0;
wire core_tx_converter_converter_first;
wire core_tx_converter_converter_last;
wire core_tx_converter_source_source_valid;
wire core_tx_converter_source_source_ready;
wire core_tx_converter_source_source_first;
wire core_tx_converter_source_source_last;
wire [9:0] core_tx_converter_source_source_payload_data;
wire core_tx_last_be_sink_sink_valid;
wire core_tx_last_be_sink_sink_ready;
wire core_tx_last_be_sink_sink_first;
wire core_tx_last_be_sink_sink_last;
wire [7:0] core_tx_last_be_sink_sink_payload_data;
wire core_tx_last_be_sink_sink_payload_last_be;
wire core_tx_last_be_sink_sink_payload_error;
wire core_tx_last_be_source_source_valid;
wire core_tx_last_be_source_source_ready;
wire core_tx_last_be_source_source_first;
wire core_tx_last_be_source_source_last;
wire [7:0] core_tx_last_be_source_source_payload_data;
wire core_tx_last_be_source_source_payload_last_be;
wire core_tx_last_be_source_source_payload_error;
wire core_tx_last_be_last_handler_sink_valid;
reg core_tx_last_be_last_handler_sink_ready;
wire core_tx_last_be_last_handler_sink_first;
wire core_tx_last_be_last_handler_sink_last;
wire [7:0] core_tx_last_be_last_handler_sink_payload_data;
wire core_tx_last_be_last_handler_sink_payload_last_be;
wire core_tx_last_be_last_handler_sink_payload_error;
reg core_tx_last_be_last_handler_source_valid;
wire core_tx_last_be_last_handler_source_ready;
reg core_tx_last_be_last_handler_source_first;
reg core_tx_last_be_last_handler_source_last;
reg [7:0] core_tx_last_be_last_handler_source_payload_data;
reg core_tx_last_be_last_handler_source_payload_last_be;
reg core_tx_last_be_last_handler_source_payload_error;
wire core_tx_gap_sink_valid;
reg core_tx_gap_sink_ready;
wire core_tx_gap_sink_first;
wire core_tx_gap_sink_last;
wire [7:0] core_tx_gap_sink_payload_data;
wire core_tx_gap_sink_payload_last_be;
wire core_tx_gap_sink_payload_error;
reg core_tx_gap_source_valid;
wire core_tx_gap_source_ready;
reg core_tx_gap_source_first;
reg core_tx_gap_source_last;
reg [7:0] core_tx_gap_source_payload_data;
reg core_tx_gap_source_payload_last_be;
reg core_tx_gap_source_payload_error;
reg [3:0] core_tx_gap_counter = 4'd0;
reg [31:0] core_preamble_errors_status = 32'd0;
wire core_preamble_errors_we;
reg core_preamble_errors_re = 1'd0;
reg [31:0] core_crc_errors_status = 32'd0;
wire core_crc_errors_we;
reg core_crc_errors_re = 1'd0;
wire core_rx_last_be_sink_valid;
wire core_rx_last_be_sink_ready;
wire core_rx_last_be_sink_first;
wire core_rx_last_be_sink_last;
wire [7:0] core_rx_last_be_sink_payload_data;
wire core_rx_last_be_sink_payload_last_be;
wire core_rx_last_be_sink_payload_error;
wire core_rx_last_be_source_valid;
wire core_rx_last_be_source_ready;
wire core_rx_last_be_source_first;
wire core_rx_last_be_source_last;
wire [7:0] core_rx_last_be_source_payload_data;
reg core_rx_last_be_source_payload_last_be;
wire core_rx_last_be_source_payload_error;
wire core_rx_converter_sink_valid;
wire core_rx_converter_sink_ready;
wire core_rx_converter_sink_first;
wire core_rx_converter_sink_last;
wire [7:0] core_rx_converter_sink_payload_data;
wire core_rx_converter_sink_payload_last_be;
wire core_rx_converter_sink_payload_error;
wire core_rx_converter_source_valid;
wire core_rx_converter_source_ready;
wire core_rx_converter_source_first;
wire core_rx_converter_source_last;
reg [31:0] core_rx_converter_source_payload_data;
reg [3:0] core_rx_converter_source_payload_last_be;
reg [3:0] core_rx_converter_source_payload_error;
wire core_rx_converter_converter_sink_valid;
wire core_rx_converter_converter_sink_ready;
wire core_rx_converter_converter_sink_first;
wire core_rx_converter_converter_sink_last;
wire [9:0] core_rx_converter_converter_sink_payload_data;
wire core_rx_converter_converter_source_valid;
wire core_rx_converter_converter_source_ready;
reg core_rx_converter_converter_source_first = 1'd0;
reg core_rx_converter_converter_source_last = 1'd0;
reg [39:0] core_rx_converter_converter_source_payload_data = 40'd0;
reg [2:0] core_rx_converter_converter_source_payload_valid_token_count = 3'd0;
reg [1:0] core_rx_converter_converter_demux = 2'd0;
wire core_rx_converter_converter_load_part;
reg core_rx_converter_converter_strobe_all = 1'd0;
wire core_rx_converter_source_source_valid;
wire core_rx_converter_source_source_ready;
wire core_rx_converter_source_source_first;
wire core_rx_converter_source_source_last;
wire [39:0] core_rx_converter_source_source_payload_data;
wire core_rx_cdc_sink_sink_valid;
wire core_rx_cdc_sink_sink_ready;
wire core_rx_cdc_sink_sink_first;
wire core_rx_cdc_sink_sink_last;
wire [31:0] core_rx_cdc_sink_sink_payload_data;
wire [3:0] core_rx_cdc_sink_sink_payload_last_be;
wire [3:0] core_rx_cdc_sink_sink_payload_error;
wire core_rx_cdc_source_source_valid;
wire core_rx_cdc_source_source_ready;
wire core_rx_cdc_source_source_first;
wire core_rx_cdc_source_source_last;
wire [31:0] core_rx_cdc_source_source_payload_data;
wire [3:0] core_rx_cdc_source_source_payload_last_be;
wire [3:0] core_rx_cdc_source_source_payload_error;
wire core_rx_cdc_cdc_sink_valid;
wire core_rx_cdc_cdc_sink_ready;
wire core_rx_cdc_cdc_sink_first;
wire core_rx_cdc_cdc_sink_last;
wire [31:0] core_rx_cdc_cdc_sink_payload_data;
wire [3:0] core_rx_cdc_cdc_sink_payload_last_be;
wire [3:0] core_rx_cdc_cdc_sink_payload_error;
wire core_rx_cdc_cdc_source_valid;
wire core_rx_cdc_cdc_source_ready;
wire core_rx_cdc_cdc_source_first;
wire core_rx_cdc_cdc_source_last;
wire [31:0] core_rx_cdc_cdc_source_payload_data;
wire [3:0] core_rx_cdc_cdc_source_payload_last_be;
wire [3:0] core_rx_cdc_cdc_source_payload_error;
wire core_rx_cdc_cdc_asyncfifo_we;
wire core_rx_cdc_cdc_asyncfifo_writable;
wire core_rx_cdc_cdc_asyncfifo_re;
wire core_rx_cdc_cdc_asyncfifo_readable;
wire [41:0] core_rx_cdc_cdc_asyncfifo_din;
wire [41:0] core_rx_cdc_cdc_asyncfifo_dout;
wire core_rx_cdc_cdc_graycounter0_ce;
(* no_retiming = "true" *) reg [11:0] core_rx_cdc_cdc_graycounter0_q = 12'd0;
wire [11:0] core_rx_cdc_cdc_graycounter0_q_next;
reg [11:0] core_rx_cdc_cdc_graycounter0_q_binary = 12'd0;
reg [11:0] core_rx_cdc_cdc_graycounter0_q_next_binary;
wire core_rx_cdc_cdc_graycounter1_ce;
(* no_retiming = "true" *) reg [11:0] core_rx_cdc_cdc_graycounter1_q = 12'd0;
wire [11:0] core_rx_cdc_cdc_graycounter1_q_next;
reg [11:0] core_rx_cdc_cdc_graycounter1_q_binary = 12'd0;
reg [11:0] core_rx_cdc_cdc_graycounter1_q_next_binary;
wire [11:0] core_rx_cdc_cdc_produce_rdomain;
wire [11:0] core_rx_cdc_cdc_consume_wdomain;
wire [10:0] core_rx_cdc_cdc_wrport_adr;
wire [41:0] core_rx_cdc_cdc_wrport_dat_r;
wire core_rx_cdc_cdc_wrport_we;
wire [41:0] core_rx_cdc_cdc_wrport_dat_w;
wire [10:0] core_rx_cdc_cdc_rdport_adr;
wire [41:0] core_rx_cdc_cdc_rdport_dat_r;
wire [31:0] core_rx_cdc_cdc_fifo_in_payload_data;
wire [3:0] core_rx_cdc_cdc_fifo_in_payload_last_be;
wire [3:0] core_rx_cdc_cdc_fifo_in_payload_error;
wire core_rx_cdc_cdc_fifo_in_first;
wire core_rx_cdc_cdc_fifo_in_last;
wire [31:0] core_rx_cdc_cdc_fifo_out_payload_data;
wire [3:0] core_rx_cdc_cdc_fifo_out_payload_last_be;
wire [3:0] core_rx_cdc_cdc_fifo_out_payload_error;
wire core_rx_cdc_cdc_fifo_out_first;
wire core_rx_cdc_cdc_fifo_out_last;
wire core_rx_preamble_sink_valid;
reg core_rx_preamble_sink_ready;
wire core_rx_preamble_sink_first;
wire core_rx_preamble_sink_last;
wire [31:0] core_rx_preamble_sink_payload_data;
wire [3:0] core_rx_preamble_sink_payload_last_be;
wire [3:0] core_rx_preamble_sink_payload_error;
reg core_rx_preamble_source_valid;
wire core_rx_preamble_source_ready;
reg core_rx_preamble_source_first;
reg core_rx_preamble_source_last;
wire [31:0] core_rx_preamble_source_payload_data;
wire [3:0] core_rx_preamble_source_payload_last_be;
reg [3:0] core_rx_preamble_source_payload_error;
reg core_rx_preamble_error;
reg [63:0] core_rx_preamble_preamble = 64'd15372286728091293013;
wire core_pulsesynchronizer0_i;
wire core_pulsesynchronizer0_o;
reg core_pulsesynchronizer0_toggle_i = 1'd0;
wire core_pulsesynchronizer0_toggle_o;
reg core_pulsesynchronizer0_toggle_o_r = 1'd0;
wire core_liteethmaccrc32checker_sink_sink_valid;
reg core_liteethmaccrc32checker_sink_sink_ready;
wire core_liteethmaccrc32checker_sink_sink_first;
wire core_liteethmaccrc32checker_sink_sink_last;
wire [31:0] core_liteethmaccrc32checker_sink_sink_payload_data;
wire [3:0] core_liteethmaccrc32checker_sink_sink_payload_last_be;
wire [3:0] core_liteethmaccrc32checker_sink_sink_payload_error;
reg core_liteethmaccrc32checker_source_source_valid;
wire core_liteethmaccrc32checker_source_source_ready;
wire core_liteethmaccrc32checker_source_source_first;
reg core_liteethmaccrc32checker_source_source_last;
wire [31:0] core_liteethmaccrc32checker_source_source_payload_data;
reg [3:0] core_liteethmaccrc32checker_source_source_payload_last_be;
reg [3:0] core_liteethmaccrc32checker_source_source_payload_error;
reg core_liteethmaccrc32checker_error;
wire [31:0] core_liteethmaccrc32checker_crc_data;
wire [3:0] core_liteethmaccrc32checker_crc_be;
reg [31:0] core_liteethmaccrc32checker_crc_value;
reg core_liteethmaccrc32checker_crc_error0;
wire [7:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data;
wire [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev;
reg [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next;
wire [15:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data;
wire [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev;
reg [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next;
wire [23:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data;
wire [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev;
reg [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next;
wire [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data;
wire [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev;
reg [31:0] core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next;
reg [31:0] core_liteethmaccrc32checker_crc_reg = 32'd4294967295;
reg core_liteethmaccrc32checker_crc_ce;
reg core_liteethmaccrc32checker_crc_reset;
reg core_liteethmaccrc32checker_syncfifo_sink_valid;
wire core_liteethmaccrc32checker_syncfifo_sink_ready;
wire core_liteethmaccrc32checker_syncfifo_sink_first;
wire core_liteethmaccrc32checker_syncfifo_sink_last;
wire [31:0] core_liteethmaccrc32checker_syncfifo_sink_payload_data;
wire [3:0] core_liteethmaccrc32checker_syncfifo_sink_payload_last_be;
wire [3:0] core_liteethmaccrc32checker_syncfifo_sink_payload_error;
wire core_liteethmaccrc32checker_syncfifo_source_valid;
reg core_liteethmaccrc32checker_syncfifo_source_ready;
wire core_liteethmaccrc32checker_syncfifo_source_first;
wire core_liteethmaccrc32checker_syncfifo_source_last;
wire [31:0] core_liteethmaccrc32checker_syncfifo_source_payload_data;
wire [3:0] core_liteethmaccrc32checker_syncfifo_source_payload_last_be;
wire [3:0] core_liteethmaccrc32checker_syncfifo_source_payload_error;
wire core_liteethmaccrc32checker_syncfifo_syncfifo_we;
wire core_liteethmaccrc32checker_syncfifo_syncfifo_writable;
wire core_liteethmaccrc32checker_syncfifo_syncfifo_re;
wire core_liteethmaccrc32checker_syncfifo_syncfifo_readable;
wire [41:0] core_liteethmaccrc32checker_syncfifo_syncfifo_din;
wire [41:0] core_liteethmaccrc32checker_syncfifo_syncfifo_dout;
reg [1:0] core_liteethmaccrc32checker_syncfifo_level = 2'd0;
reg core_liteethmaccrc32checker_syncfifo_replace = 1'd0;
reg core_liteethmaccrc32checker_syncfifo_produce = 1'd0;
reg core_liteethmaccrc32checker_syncfifo_consume = 1'd0;
reg core_liteethmaccrc32checker_syncfifo_wrport_adr;
wire [41:0] core_liteethmaccrc32checker_syncfifo_wrport_dat_r;
wire core_liteethmaccrc32checker_syncfifo_wrport_we;
wire [41:0] core_liteethmaccrc32checker_syncfifo_wrport_dat_w;
wire core_liteethmaccrc32checker_syncfifo_do_read;
wire core_liteethmaccrc32checker_syncfifo_rdport_adr;
wire [41:0] core_liteethmaccrc32checker_syncfifo_rdport_dat_r;
wire [31:0] core_liteethmaccrc32checker_syncfifo_fifo_in_payload_data;
wire [3:0] core_liteethmaccrc32checker_syncfifo_fifo_in_payload_last_be;
wire [3:0] core_liteethmaccrc32checker_syncfifo_fifo_in_payload_error;
wire core_liteethmaccrc32checker_syncfifo_fifo_in_first;
wire core_liteethmaccrc32checker_syncfifo_fifo_in_last;
wire [31:0] core_liteethmaccrc32checker_syncfifo_fifo_out_payload_data;
wire [3:0] core_liteethmaccrc32checker_syncfifo_fifo_out_payload_last_be;
wire [3:0] core_liteethmaccrc32checker_syncfifo_fifo_out_payload_error;
wire core_liteethmaccrc32checker_syncfifo_fifo_out_first;
wire core_liteethmaccrc32checker_syncfifo_fifo_out_last;
reg core_liteethmaccrc32checker_fifo_reset;
wire core_liteethmaccrc32checker_fifo_in;
wire core_liteethmaccrc32checker_fifo_out;
wire core_liteethmaccrc32checker_fifo_full;
reg [3:0] core_liteethmaccrc32checker_last_be = 4'd0;
reg core_liteethmaccrc32checker_crc_error1 = 1'd0;
wire core_bufferizeendpoints_sink_sink_valid;
wire core_bufferizeendpoints_sink_sink_ready;
wire core_bufferizeendpoints_sink_sink_first;
wire core_bufferizeendpoints_sink_sink_last;
wire [31:0] core_bufferizeendpoints_sink_sink_payload_data;
wire [3:0] core_bufferizeendpoints_sink_sink_payload_last_be;
wire [3:0] core_bufferizeendpoints_sink_sink_payload_error;
wire core_bufferizeendpoints_source_source_valid;
wire core_bufferizeendpoints_source_source_ready;
wire core_bufferizeendpoints_source_source_first;
wire core_bufferizeendpoints_source_source_last;
wire [31:0] core_bufferizeendpoints_source_source_payload_data;
wire [3:0] core_bufferizeendpoints_source_source_payload_last_be;
wire [3:0] core_bufferizeendpoints_source_source_payload_error;
wire core_bufferizeendpoints_pipe_valid_sink_valid;
wire core_bufferizeendpoints_pipe_valid_sink_ready;
wire core_bufferizeendpoints_pipe_valid_sink_first;
wire core_bufferizeendpoints_pipe_valid_sink_last;
wire [31:0] core_bufferizeendpoints_pipe_valid_sink_payload_data;
wire [3:0] core_bufferizeendpoints_pipe_valid_sink_payload_last_be;
wire [3:0] core_bufferizeendpoints_pipe_valid_sink_payload_error;
reg core_bufferizeendpoints_pipe_valid_source_valid = 1'd0;
wire core_bufferizeendpoints_pipe_valid_source_ready;
reg core_bufferizeendpoints_pipe_valid_source_first = 1'd0;
reg core_bufferizeendpoints_pipe_valid_source_last = 1'd0;
reg [31:0] core_bufferizeendpoints_pipe_valid_source_payload_data = 32'd0;
reg [3:0] core_bufferizeendpoints_pipe_valid_source_payload_last_be = 4'd0;
reg [3:0] core_bufferizeendpoints_pipe_valid_source_payload_error = 4'd0;
wire core_pulsesynchronizer1_i;
wire core_pulsesynchronizer1_o;
reg core_pulsesynchronizer1_toggle_i = 1'd0;
wire core_pulsesynchronizer1_toggle_o;
reg core_pulsesynchronizer1_toggle_o_r = 1'd0;
wire core_rx_padding_sink_valid;
wire core_rx_padding_sink_ready;
wire core_rx_padding_sink_first;
wire core_rx_padding_sink_last;
wire [31:0] core_rx_padding_sink_payload_data;
wire [3:0] core_rx_padding_sink_payload_last_be;
wire [3:0] core_rx_padding_sink_payload_error;
wire core_rx_padding_source_valid;
wire core_rx_padding_source_ready;
wire core_rx_padding_source_first;
wire core_rx_padding_source_last;
wire [31:0] core_rx_padding_source_payload_data;
wire [3:0] core_rx_padding_source_payload_last_be;
wire [3:0] core_rx_padding_source_payload_error;
wire wishbone_interface_sink_valid;
wire wishbone_interface_sink_ready;
wire wishbone_interface_sink_first;
wire wishbone_interface_sink_last;
wire [31:0] wishbone_interface_sink_payload_data;
wire [3:0] wishbone_interface_sink_payload_last_be;
wire [3:0] wishbone_interface_sink_payload_error;
wire wishbone_interface_source_valid;
wire wishbone_interface_source_ready;
wire wishbone_interface_source_first;
wire wishbone_interface_source_last;
wire [31:0] wishbone_interface_source_payload_data;
wire [3:0] wishbone_interface_source_payload_last_be;
wire [3:0] wishbone_interface_source_payload_error;
wire wishbone_interface_writer_sink_sink_valid;
reg wishbone_interface_writer_sink_sink_ready = 1'd1;
wire wishbone_interface_writer_sink_sink_first;
wire wishbone_interface_writer_sink_sink_last;
wire [31:0] wishbone_interface_writer_sink_sink_payload_data;
wire [3:0] wishbone_interface_writer_sink_sink_payload_last_be;
wire [3:0] wishbone_interface_writer_sink_sink_payload_error;
wire [1:0] wishbone_interface_writer_slot_status;
wire wishbone_interface_writer_slot_we;
reg wishbone_interface_writer_slot_re = 1'd0;
wire [10:0] wishbone_interface_writer_length_status;
wire wishbone_interface_writer_length_we;
reg wishbone_interface_writer_length_re = 1'd0;
reg [31:0] wishbone_interface_writer_errors_status = 32'd0;
wire wishbone_interface_writer_errors_we;
reg wishbone_interface_writer_errors_re = 1'd0;
wire wishbone_interface_writer_irq;
wire wishbone_interface_writer_available_status;
wire wishbone_interface_writer_available_pending;
wire wishbone_interface_writer_available_trigger;
reg wishbone_interface_writer_available_clear;
wire wishbone_interface_writer_available0;
wire wishbone_interface_writer_status_status;
wire wishbone_interface_writer_status_we;
reg wishbone_interface_writer_status_re = 1'd0;
wire wishbone_interface_writer_available1;
wire wishbone_interface_writer_pending_status;
wire wishbone_interface_writer_pending_we;
reg wishbone_interface_writer_pending_re = 1'd0;
reg wishbone_interface_writer_pending_r = 1'd0;
wire wishbone_interface_writer_available2;
reg wishbone_interface_writer_enable_storage = 1'd0;
reg wishbone_interface_writer_enable_re = 1'd0;
reg wishbone_interface_writer_write;
reg [1:0] wishbone_interface_writer_slot = 2'd0;
reg [10:0] wishbone_interface_writer_length = 11'd0;
reg [3:0] wishbone_interface_writer_length_inc;
reg wishbone_interface_writer_stat_fifo_sink_valid;
wire wishbone_interface_writer_stat_fifo_sink_ready;
reg wishbone_interface_writer_stat_fifo_sink_first = 1'd0;
reg wishbone_interface_writer_stat_fifo_sink_last = 1'd0;
reg [1:0] wishbone_interface_writer_stat_fifo_sink_payload_slot;
reg [10:0] wishbone_interface_writer_stat_fifo_sink_payload_length;
wire wishbone_interface_writer_stat_fifo_source_valid;
wire wishbone_interface_writer_stat_fifo_source_ready;
wire wishbone_interface_writer_stat_fifo_source_first;
wire wishbone_interface_writer_stat_fifo_source_last;
wire [1:0] wishbone_interface_writer_stat_fifo_source_payload_slot;
wire [10:0] wishbone_interface_writer_stat_fifo_source_payload_length;
wire wishbone_interface_writer_stat_fifo_syncfifo_we;
wire wishbone_interface_writer_stat_fifo_syncfifo_writable;
wire wishbone_interface_writer_stat_fifo_syncfifo_re;
wire wishbone_interface_writer_stat_fifo_syncfifo_readable;
wire [14:0] wishbone_interface_writer_stat_fifo_syncfifo_din;
wire [14:0] wishbone_interface_writer_stat_fifo_syncfifo_dout;
reg [2:0] wishbone_interface_writer_stat_fifo_level = 3'd0;
reg wishbone_interface_writer_stat_fifo_replace = 1'd0;
reg [1:0] wishbone_interface_writer_stat_fifo_produce = 2'd0;
reg [1:0] wishbone_interface_writer_stat_fifo_consume = 2'd0;
reg [1:0] wishbone_interface_writer_stat_fifo_wrport_adr;
wire [14:0] wishbone_interface_writer_stat_fifo_wrport_dat_r;
wire wishbone_interface_writer_stat_fifo_wrport_we;
wire [14:0] wishbone_interface_writer_stat_fifo_wrport_dat_w;
wire wishbone_interface_writer_stat_fifo_do_read;
wire [1:0] wishbone_interface_writer_stat_fifo_rdport_adr;
wire [14:0] wishbone_interface_writer_stat_fifo_rdport_dat_r;
wire [1:0] wishbone_interface_writer_stat_fifo_fifo_in_payload_slot;
wire [10:0] wishbone_interface_writer_stat_fifo_fifo_in_payload_length;
wire wishbone_interface_writer_stat_fifo_fifo_in_first;
wire wishbone_interface_writer_stat_fifo_fifo_in_last;
wire [1:0] wishbone_interface_writer_stat_fifo_fifo_out_payload_slot;
wire [10:0] wishbone_interface_writer_stat_fifo_fifo_out_payload_length;
wire wishbone_interface_writer_stat_fifo_fifo_out_first;
wire wishbone_interface_writer_stat_fifo_fifo_out_last;
wire [31:0] wishbone_interface_writer_wr_data;
reg [8:0] wishbone_interface_writer_memory0_adr;
wire [31:0] wishbone_interface_writer_memory0_dat_r;
reg wishbone_interface_writer_memory0_we;
reg [31:0] wishbone_interface_writer_memory0_dat_w;
reg [8:0] wishbone_interface_writer_memory1_adr;
wire [31:0] wishbone_interface_writer_memory1_dat_r;
reg wishbone_interface_writer_memory1_we;
reg [31:0] wishbone_interface_writer_memory1_dat_w;
reg [8:0] wishbone_interface_writer_memory2_adr;
wire [31:0] wishbone_interface_writer_memory2_dat_r;
reg wishbone_interface_writer_memory2_we;
reg [31:0] wishbone_interface_writer_memory2_dat_w;
reg [8:0] wishbone_interface_writer_memory3_adr;
wire [31:0] wishbone_interface_writer_memory3_dat_r;
reg wishbone_interface_writer_memory3_we;
reg [31:0] wishbone_interface_writer_memory3_dat_w;
reg wishbone_interface_reader_source_source_valid;
wire wishbone_interface_reader_source_source_ready;
reg wishbone_interface_reader_source_source_first = 1'd0;
reg wishbone_interface_reader_source_source_last;
wire [31:0] wishbone_interface_reader_source_source_payload_data;
reg [3:0] wishbone_interface_reader_source_source_payload_last_be;
reg [3:0] wishbone_interface_reader_source_source_payload_error = 4'd0;
reg wishbone_interface_reader_start_re;
wire wishbone_interface_reader_start_r;
reg wishbone_interface_reader_start_we;
reg wishbone_interface_reader_start_w = 1'd0;
wire wishbone_interface_reader_ready_status;
wire wishbone_interface_reader_ready_we;
reg wishbone_interface_reader_ready_re = 1'd0;
wire [1:0] wishbone_interface_reader_level_status;
wire wishbone_interface_reader_level_we;
reg wishbone_interface_reader_level_re = 1'd0;
reg wishbone_interface_reader_slot_storage = 1'd0;
reg wishbone_interface_reader_slot_re = 1'd0;
reg [10:0] wishbone_interface_reader_length_storage = 11'd0;
reg wishbone_interface_reader_length_re = 1'd0;
wire wishbone_interface_reader_irq;
wire wishbone_interface_reader_eventsourcepulse_status;
reg wishbone_interface_reader_eventsourcepulse_pending = 1'd0;
reg wishbone_interface_reader_eventsourcepulse_trigger;
reg wishbone_interface_reader_eventsourcepulse_clear;
wire wishbone_interface_reader_event00;
wire wishbone_interface_reader_status_status;
wire wishbone_interface_reader_status_we;
reg wishbone_interface_reader_status_re = 1'd0;
wire wishbone_interface_reader_event01;
wire wishbone_interface_reader_pending_status;
wire wishbone_interface_reader_pending_we;
reg wishbone_interface_reader_pending_re = 1'd0;
reg wishbone_interface_reader_pending_r = 1'd0;
wire wishbone_interface_reader_event02;
reg wishbone_interface_reader_enable_storage = 1'd0;
reg wishbone_interface_reader_enable_re = 1'd0;
reg wishbone_interface_reader_read;
reg [10:0] wishbone_interface_reader_length = 11'd0;
wire wishbone_interface_reader_cmd_fifo_sink_valid;
wire wishbone_interface_reader_cmd_fifo_sink_ready;
reg wishbone_interface_reader_cmd_fifo_sink_first = 1'd0;
reg wishbone_interface_reader_cmd_fifo_sink_last = 1'd0;
wire wishbone_interface_reader_cmd_fifo_sink_payload_slot;
wire [10:0] wishbone_interface_reader_cmd_fifo_sink_payload_length;
wire wishbone_interface_reader_cmd_fifo_source_valid;
reg wishbone_interface_reader_cmd_fifo_source_ready;
wire wishbone_interface_reader_cmd_fifo_source_first;
wire wishbone_interface_reader_cmd_fifo_source_last;
wire wishbone_interface_reader_cmd_fifo_source_payload_slot;
wire [10:0] wishbone_interface_reader_cmd_fifo_source_payload_length;
wire wishbone_interface_reader_cmd_fifo_syncfifo_we;
wire wishbone_interface_reader_cmd_fifo_syncfifo_writable;
wire wishbone_interface_reader_cmd_fifo_syncfifo_re;
wire wishbone_interface_reader_cmd_fifo_syncfifo_readable;
wire [13:0] wishbone_interface_reader_cmd_fifo_syncfifo_din;
wire [13:0] wishbone_interface_reader_cmd_fifo_syncfifo_dout;
reg [1:0] wishbone_interface_reader_cmd_fifo_level = 2'd0;
reg wishbone_interface_reader_cmd_fifo_replace = 1'd0;
reg wishbone_interface_reader_cmd_fifo_produce = 1'd0;
reg wishbone_interface_reader_cmd_fifo_consume = 1'd0;
reg wishbone_interface_reader_cmd_fifo_wrport_adr;
wire [13:0] wishbone_interface_reader_cmd_fifo_wrport_dat_r;
wire wishbone_interface_reader_cmd_fifo_wrport_we;
wire [13:0] wishbone_interface_reader_cmd_fifo_wrport_dat_w;
wire wishbone_interface_reader_cmd_fifo_do_read;
wire wishbone_interface_reader_cmd_fifo_rdport_adr;
wire [13:0] wishbone_interface_reader_cmd_fifo_rdport_dat_r;
wire wishbone_interface_reader_cmd_fifo_fifo_in_payload_slot;
wire [10:0] wishbone_interface_reader_cmd_fifo_fifo_in_payload_length;
wire wishbone_interface_reader_cmd_fifo_fifo_in_first;
wire wishbone_interface_reader_cmd_fifo_fifo_in_last;
wire wishbone_interface_reader_cmd_fifo_fifo_out_payload_slot;
wire [10:0] wishbone_interface_reader_cmd_fifo_fifo_out_payload_length;
wire wishbone_interface_reader_cmd_fifo_fifo_out_first;
wire wishbone_interface_reader_cmd_fifo_fifo_out_last;
reg [31:0] wishbone_interface_reader_rd_data;
wire [8:0] wishbone_interface_reader_memory0_adr;
wire [31:0] wishbone_interface_reader_memory0_dat_r;
wire wishbone_interface_reader_memory0_re;
wire [8:0] wishbone_interface_reader_memory1_adr;
wire [31:0] wishbone_interface_reader_memory1_dat_r;
wire wishbone_interface_reader_memory1_re;
wire wishbone_interface_ev_irq;
wire [29:0] wishbone_interface_interface0_adr;
wire [31:0] wishbone_interface_interface0_dat_w;
wire [31:0] wishbone_interface_interface0_dat_r;
wire [3:0] wishbone_interface_interface0_sel;
wire wishbone_interface_interface0_cyc;
wire wishbone_interface_interface0_stb;
reg wishbone_interface_interface0_ack = 1'd0;
wire wishbone_interface_interface0_we;
wire [2:0] wishbone_interface_interface0_cti;
wire [1:0] wishbone_interface_interface0_bte;
reg wishbone_interface_interface0_err = 1'd0;
reg wishbone_interface_sram0_adr_burst = 1'd0;
wire [8:0] wishbone_interface_sram0_adr;
wire [31:0] wishbone_interface_sram0_dat_r;
wire [29:0] wishbone_interface_interface1_adr;
wire [31:0] wishbone_interface_interface1_dat_w;
wire [31:0] wishbone_interface_interface1_dat_r;
wire [3:0] wishbone_interface_interface1_sel;
wire wishbone_interface_interface1_cyc;
wire wishbone_interface_interface1_stb;
reg wishbone_interface_interface1_ack = 1'd0;
wire wishbone_interface_interface1_we;
wire [2:0] wishbone_interface_interface1_cti;
wire [1:0] wishbone_interface_interface1_bte;
reg wishbone_interface_interface1_err = 1'd0;
reg wishbone_interface_sram1_adr_burst = 1'd0;
wire [8:0] wishbone_interface_sram1_adr;
wire [31:0] wishbone_interface_sram1_dat_r;
wire [29:0] wishbone_interface_interface2_adr;
wire [31:0] wishbone_interface_interface2_dat_w;
wire [31:0] wishbone_interface_interface2_dat_r;
wire [3:0] wishbone_interface_interface2_sel;
wire wishbone_interface_interface2_cyc;
wire wishbone_interface_interface2_stb;
reg wishbone_interface_interface2_ack = 1'd0;
wire wishbone_interface_interface2_we;
wire [2:0] wishbone_interface_interface2_cti;
wire [1:0] wishbone_interface_interface2_bte;
reg wishbone_interface_interface2_err = 1'd0;
reg wishbone_interface_sram2_adr_burst = 1'd0;
wire [8:0] wishbone_interface_sram2_adr;
wire [31:0] wishbone_interface_sram2_dat_r;
wire [29:0] wishbone_interface_interface3_adr;
wire [31:0] wishbone_interface_interface3_dat_w;
wire [31:0] wishbone_interface_interface3_dat_r;
wire [3:0] wishbone_interface_interface3_sel;
wire wishbone_interface_interface3_cyc;
wire wishbone_interface_interface3_stb;
reg wishbone_interface_interface3_ack = 1'd0;
wire wishbone_interface_interface3_we;
wire [2:0] wishbone_interface_interface3_cti;
wire [1:0] wishbone_interface_interface3_bte;
reg wishbone_interface_interface3_err = 1'd0;
reg wishbone_interface_sram3_adr_burst = 1'd0;
wire [8:0] wishbone_interface_sram3_adr;
wire [31:0] wishbone_interface_sram3_dat_r;
reg [3:0] wishbone_interface_decoder0_slave_sel;
reg [3:0] wishbone_interface_decoder0_slave_sel_r = 4'd0;
wire [29:0] wishbone_interface_interface4_adr;
wire [31:0] wishbone_interface_interface4_dat_w;
wire [31:0] wishbone_interface_interface4_dat_r;
wire [3:0] wishbone_interface_interface4_sel;
wire wishbone_interface_interface4_cyc;
wire wishbone_interface_interface4_stb;
reg wishbone_interface_interface4_ack = 1'd0;
wire wishbone_interface_interface4_we;
wire [2:0] wishbone_interface_interface4_cti;
wire [1:0] wishbone_interface_interface4_bte;
reg wishbone_interface_interface4_err = 1'd0;
reg wishbone_interface_sram4_adr_burst = 1'd0;
wire [8:0] wishbone_interface_sram4_adr;
wire [31:0] wishbone_interface_sram4_dat_r;
reg [3:0] wishbone_interface_sram4_we;
wire [31:0] wishbone_interface_sram4_dat_w;
wire [29:0] wishbone_interface_interface5_adr;
wire [31:0] wishbone_interface_interface5_dat_w;
wire [31:0] wishbone_interface_interface5_dat_r;
wire [3:0] wishbone_interface_interface5_sel;
wire wishbone_interface_interface5_cyc;
wire wishbone_interface_interface5_stb;
reg wishbone_interface_interface5_ack = 1'd0;
wire wishbone_interface_interface5_we;
wire [2:0] wishbone_interface_interface5_cti;
wire [1:0] wishbone_interface_interface5_bte;
reg wishbone_interface_interface5_err = 1'd0;
reg wishbone_interface_sram5_adr_burst = 1'd0;
wire [8:0] wishbone_interface_sram5_adr;
wire [31:0] wishbone_interface_sram5_dat_r;
reg [3:0] wishbone_interface_sram5_we;
wire [31:0] wishbone_interface_sram5_dat_w;
reg [1:0] wishbone_interface_decoder1_slave_sel;
reg [1:0] wishbone_interface_decoder1_slave_sel_r = 2'd0;
reg [15:0] csrbus_adr = 16'd0;
reg csrbus_re = 1'd0;
reg csrbus_we = 1'd0;
reg [31:0] csrbus_dat_w = 32'd0;
reg [31:0] csrbus_dat_r = 32'd0;
reg sram_writer_slot_re;
wire [1:0] sram_writer_slot_r;
reg sram_writer_slot_we;
wire [1:0] sram_writer_slot_w;
reg sram_writer_length_re;
wire [10:0] sram_writer_length_r;
reg sram_writer_length_we;
wire [10:0] sram_writer_length_w;
reg sram_writer_errors_re;
wire [31:0] sram_writer_errors_r;
reg sram_writer_errors_we;
wire [31:0] sram_writer_errors_w;
reg sram_writer_ev_status_re;
wire sram_writer_ev_status_r;
reg sram_writer_ev_status_we;
wire sram_writer_ev_status_w;
reg sram_writer_ev_pending_re;
wire sram_writer_ev_pending_r;
reg sram_writer_ev_pending_we;
wire sram_writer_ev_pending_w;
reg sram_writer_ev_enable0_re;
wire sram_writer_ev_enable0_r;
reg sram_writer_ev_enable0_we;
wire sram_writer_ev_enable0_w;
reg sram_reader_ready_re;
wire sram_reader_ready_r;
reg sram_reader_ready_we;
wire sram_reader_ready_w;
reg sram_reader_level_re;
wire [1:0] sram_reader_level_r;
reg sram_reader_level_we;
wire [1:0] sram_reader_level_w;
reg sram_reader_slot0_re;
wire sram_reader_slot0_r;
reg sram_reader_slot0_we;
wire sram_reader_slot0_w;
reg sram_reader_length0_re;
wire [10:0] sram_reader_length0_r;
reg sram_reader_length0_we;
wire [10:0] sram_reader_length0_w;
reg sram_reader_ev_status_re;
wire sram_reader_ev_status_r;
reg sram_reader_ev_status_we;
wire sram_reader_ev_status_w;
reg sram_reader_ev_pending_re;
wire sram_reader_ev_pending_r;
reg sram_reader_ev_pending_we;
wire sram_reader_ev_pending_w;
reg sram_reader_ev_enable0_re;
wire sram_reader_ev_enable0_r;
reg sram_reader_ev_enable0_we;
wire sram_reader_ev_enable0_w;
reg preamble_crc_re;
wire preamble_crc_r;
reg preamble_crc_we;
wire preamble_crc_w;
reg rx_datapath_preamble_errors_re;
wire [31:0] rx_datapath_preamble_errors_r;
reg rx_datapath_preamble_errors_we;
wire [31:0] rx_datapath_preamble_errors_w;
reg rx_datapath_crc_errors_re;
wire [31:0] rx_datapath_crc_errors_r;
reg rx_datapath_crc_errors_we;
wire [31:0] rx_datapath_crc_errors_w;
wire sel;
reg txdatapath_liteethmacpaddinginserter_state = 1'd0;
reg txdatapath_liteethmacpaddinginserter_next_state;
reg [15:0] core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value;
reg core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce;
reg [1:0] txdatapath_bufferizeendpoints_state = 2'd0;
reg [1:0] txdatapath_bufferizeendpoints_next_state;
reg [31:0] core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value0;
reg core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value_ce0;
reg [3:0] core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value1;
reg core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value_ce1;
reg [1:0] txdatapath_liteethmacpreambleinserter_state = 2'd0;
reg [1:0] txdatapath_liteethmacpreambleinserter_next_state;
reg core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value;
reg core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value_ce;
reg txdatapath_liteethmactxlastbe_state = 1'd0;
reg txdatapath_liteethmactxlastbe_next_state;
reg txdatapath_liteethmacgap_state = 1'd0;
reg txdatapath_liteethmacgap_next_state;
reg [3:0] core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value;
reg core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value_ce;
reg rxdatapath_liteethmacpreamblechecker_state = 1'd0;
reg rxdatapath_liteethmacpreamblechecker_next_state;
reg [1:0] rxdatapath_bufferizeendpoints_state = 2'd0;
reg [1:0] rxdatapath_bufferizeendpoints_next_state;
reg [3:0] core_liteethmaccrc32checker_last_be_liteethmac_next_value0;
reg core_liteethmaccrc32checker_last_be_liteethmac_next_value_ce0;
reg core_liteethmaccrc32checker_crc_error1_liteethmac_next_value1;
reg core_liteethmaccrc32checker_crc_error1_liteethmac_next_value_ce1;
reg [2:0] liteethmacsramwriter_state = 3'd0;
reg [2:0] liteethmacsramwriter_next_state;
reg [10:0] wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value;
reg wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce;
reg [31:0] wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value;
reg wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value_ce;
reg [1:0] wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value;
reg wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value_ce;
reg [1:0] liteethmacsramreader_state = 2'd0;
reg [1:0] liteethmacsramreader_next_state;
reg [10:0] wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value;
reg wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value_ce;
reg [1:0] state = 2'd0;
reg [1:0] next_state;
reg [31:0] csrbus_dat_w_wishbone2csr_next_value0;
reg csrbus_dat_w_wishbone2csr_next_value_ce0;
reg [15:0] csrbus_adr_wishbone2csr_next_value1;
reg csrbus_adr_wishbone2csr_next_value_ce1;
reg csrbus_re_wishbone2csr_next_value2;
reg csrbus_re_wishbone2csr_next_value_ce2;
reg csrbus_we_wishbone2csr_next_value3;
reg csrbus_we_wishbone2csr_next_value_ce3;
wire [39:0] slice_proxy0;
wire [47:0] slice_proxy1;
wire [55:0] slice_proxy2;
wire [63:0] slice_proxy3;
(* no_retiming = "true" *) reg [11:0] multiregimpl00 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl01 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl10 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl11 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl20 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl21 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl30 = 12'd0;
(* no_retiming = "true" *) reg [11:0] multiregimpl31 = 12'd0;
(* no_retiming = "true" *) reg multiregimpl40 = 1'd0;
(* no_retiming = "true" *) reg multiregimpl41 = 1'd0;
(* no_retiming = "true" *) reg multiregimpl50 = 1'd0;
(* no_retiming = "true" *) reg multiregimpl51 = 1'd0;

// synthesis translate_off
reg dummy_s;
initial dummy_s <= 1'd0;
// synthesis translate_on

assign eth_rx_clk = clock_pads_rx;
assign eth_tx_clk = clock_pads_tx;
assign sys_rst_1 = sys_rst;
assign eth_rx_rst = resetsync0_reset_out;
assign eth_tx_rst = resetsync1_reset_out;
assign irq = (wishbone_interface_writer_pending_status | wishbone_interface_reader_pending_status);
assign source_last = ((~pads_rx_dv) & dv_d);
assign resetsync0_reset_out = (sys_rst_1 | (~(resetsync0_sr[0] & resetsync0_sr[1])));
assign resetsync1_reset_out = (sys_rst_1 | (~(resetsync1_sr[0] & resetsync1_sr[1])));
assign core_sink_valid = wishbone_interface_source_valid;
assign wishbone_interface_source_ready = core_sink_ready;
assign core_sink_first = wishbone_interface_source_first;
assign core_sink_last = wishbone_interface_source_last;
assign core_sink_payload_data = wishbone_interface_source_payload_data;
assign core_sink_payload_last_be = wishbone_interface_source_payload_last_be;
assign core_sink_payload_error = wishbone_interface_source_payload_error;
assign wishbone_interface_sink_valid = core_source_valid;
assign core_source_ready = wishbone_interface_sink_ready;
assign wishbone_interface_sink_first = core_source_first;
assign wishbone_interface_sink_last = core_source_last;
assign wishbone_interface_sink_payload_data = core_source_payload_data;
assign wishbone_interface_sink_payload_last_be = core_source_payload_last_be;
assign wishbone_interface_sink_payload_error = core_source_payload_error;
assign core_tx_padding_counter_done = (core_tx_padding_counter >= 4'd14);

// synthesis translate_off
reg dummy_d;
// synthesis translate_on
always @(*) begin
	core_tx_padding_sink_ready <= 1'd0;
	core_tx_padding_source_valid <= 1'd0;
	core_tx_padding_source_first <= 1'd0;
	core_tx_padding_source_last <= 1'd0;
	core_tx_padding_source_payload_data <= 32'd0;
	core_tx_padding_source_payload_last_be <= 4'd0;
	core_tx_padding_source_payload_error <= 4'd0;
	txdatapath_liteethmacpaddinginserter_next_state <= 1'd0;
	core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value <= 16'd0;
	core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce <= 1'd0;
	txdatapath_liteethmacpaddinginserter_next_state <= txdatapath_liteethmacpaddinginserter_state;
	case (txdatapath_liteethmacpaddinginserter_state)
		1'd1: begin
			core_tx_padding_source_valid <= 1'd1;
			if (core_tx_padding_counter_done) begin
				core_tx_padding_source_payload_last_be <= 4'd8;
				core_tx_padding_source_last <= 1'd1;
			end
			core_tx_padding_source_payload_data <= 1'd0;
			if ((core_tx_padding_source_valid & core_tx_padding_source_ready)) begin
				core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value <= (core_tx_padding_counter + 1'd1);
				core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce <= 1'd1;
				if (core_tx_padding_counter_done) begin
					core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value <= 1'd0;
					core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce <= 1'd1;
					txdatapath_liteethmacpaddinginserter_next_state <= 1'd0;
				end
			end
		end
		default: begin
			core_tx_padding_source_valid <= core_tx_padding_sink_valid;
			core_tx_padding_sink_ready <= core_tx_padding_source_ready;
			core_tx_padding_source_first <= core_tx_padding_sink_first;
			core_tx_padding_source_last <= core_tx_padding_sink_last;
			core_tx_padding_source_payload_data <= core_tx_padding_sink_payload_data;
			core_tx_padding_source_payload_last_be <= core_tx_padding_sink_payload_last_be;
			core_tx_padding_source_payload_error <= core_tx_padding_sink_payload_error;
			if ((core_tx_padding_source_valid & core_tx_padding_source_ready)) begin
				core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value <= (core_tx_padding_counter + 1'd1);
				core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce <= 1'd1;
				if (core_tx_padding_sink_last) begin
					if ((~core_tx_padding_counter_done)) begin
						core_tx_padding_source_last <= 1'd0;
						core_tx_padding_source_payload_last_be <= 1'd0;
						txdatapath_liteethmacpaddinginserter_next_state <= 1'd1;
					end else begin
						if (((core_tx_padding_counter == 4'd14) & (core_tx_padding_sink_payload_last_be < 4'd8))) begin
							core_tx_padding_source_payload_last_be <= 4'd8;
						end else begin
							core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value <= 1'd0;
							core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce <= 1'd1;
						end
					end
				end
			end
		end
	endcase
// synthesis translate_off
	dummy_d <= dummy_s;
// synthesis translate_on
end
assign core_tx_crc_data = core_tx_crc_sink_payload_data;
assign core_tx_crc_be = core_tx_crc_sink_payload_last_be;
assign core_tx_crc_sink_valid = core_tx_crc_source_source_valid;
assign core_tx_crc_source_source_ready = core_tx_crc_sink_ready;
assign core_tx_crc_sink_first = core_tx_crc_source_source_first;
assign core_tx_crc_sink_last = core_tx_crc_source_source_last;
assign core_tx_crc_sink_payload_data = core_tx_crc_source_source_payload_data;
assign core_tx_crc_sink_payload_last_be = core_tx_crc_source_source_payload_last_be;
assign core_tx_crc_sink_payload_error = core_tx_crc_source_source_payload_error;
assign core_tx_crc_liteethmaccrcengine0_data = core_tx_crc_data;
assign core_tx_crc_liteethmaccrcengine0_crc_prev = core_tx_crc_reg;
assign core_tx_crc_liteethmaccrcengine1_data = core_tx_crc_data;
assign core_tx_crc_liteethmaccrcengine1_crc_prev = core_tx_crc_reg;
assign core_tx_crc_liteethmaccrcengine2_data = core_tx_crc_data;
assign core_tx_crc_liteethmaccrcengine2_crc_prev = core_tx_crc_reg;
assign core_tx_crc_liteethmaccrcengine3_data = core_tx_crc_data;
assign core_tx_crc_liteethmaccrcengine3_crc_prev = core_tx_crc_reg;

// synthesis translate_off
reg dummy_d_1;
// synthesis translate_on
always @(*) begin
	core_tx_crc_value <= 32'd0;
	core_tx_crc_error <= 1'd0;
	if (core_tx_crc_be[0]) begin
		core_tx_crc_value <= ({core_tx_crc_liteethmaccrcengine0_crc_next[0], core_tx_crc_liteethmaccrcengine0_crc_next[1], core_tx_crc_liteethmaccrcengine0_crc_next[2], core_tx_crc_liteethmaccrcengine0_crc_next[3], core_tx_crc_liteethmaccrcengine0_crc_next[4], core_tx_crc_liteethmaccrcengine0_crc_next[5], core_tx_crc_liteethmaccrcengine0_crc_next[6], core_tx_crc_liteethmaccrcengine0_crc_next[7], core_tx_crc_liteethmaccrcengine0_crc_next[8], core_tx_crc_liteethmaccrcengine0_crc_next[9], core_tx_crc_liteethmaccrcengine0_crc_next[10], core_tx_crc_liteethmaccrcengine0_crc_next[11], core_tx_crc_liteethmaccrcengine0_crc_next[12], core_tx_crc_liteethmaccrcengine0_crc_next[13], core_tx_crc_liteethmaccrcengine0_crc_next[14], core_tx_crc_liteethmaccrcengine0_crc_next[15], core_tx_crc_liteethmaccrcengine0_crc_next[16], core_tx_crc_liteethmaccrcengine0_crc_next[17], core_tx_crc_liteethmaccrcengine0_crc_next[18], core_tx_crc_liteethmaccrcengine0_crc_next[19], core_tx_crc_liteethmaccrcengine0_crc_next[20], core_tx_crc_liteethmaccrcengine0_crc_next[21], core_tx_crc_liteethmaccrcengine0_crc_next[22], core_tx_crc_liteethmaccrcengine0_crc_next[23], core_tx_crc_liteethmaccrcengine0_crc_next[24], core_tx_crc_liteethmaccrcengine0_crc_next[25], core_tx_crc_liteethmaccrcengine0_crc_next[26], core_tx_crc_liteethmaccrcengine0_crc_next[27], core_tx_crc_liteethmaccrcengine0_crc_next[28], core_tx_crc_liteethmaccrcengine0_crc_next[29], core_tx_crc_liteethmaccrcengine0_crc_next[30], core_tx_crc_liteethmaccrcengine0_crc_next[31]} ^ 32'd4294967295);
		core_tx_crc_error <= (core_tx_crc_liteethmaccrcengine0_crc_next != 32'd3338984827);
	end
	if (core_tx_crc_be[1]) begin
		core_tx_crc_value <= ({core_tx_crc_liteethmaccrcengine1_crc_next[0], core_tx_crc_liteethmaccrcengine1_crc_next[1], core_tx_crc_liteethmaccrcengine1_crc_next[2], core_tx_crc_liteethmaccrcengine1_crc_next[3], core_tx_crc_liteethmaccrcengine1_crc_next[4], core_tx_crc_liteethmaccrcengine1_crc_next[5], core_tx_crc_liteethmaccrcengine1_crc_next[6], core_tx_crc_liteethmaccrcengine1_crc_next[7], core_tx_crc_liteethmaccrcengine1_crc_next[8], core_tx_crc_liteethmaccrcengine1_crc_next[9], core_tx_crc_liteethmaccrcengine1_crc_next[10], core_tx_crc_liteethmaccrcengine1_crc_next[11], core_tx_crc_liteethmaccrcengine1_crc_next[12], core_tx_crc_liteethmaccrcengine1_crc_next[13], core_tx_crc_liteethmaccrcengine1_crc_next[14], core_tx_crc_liteethmaccrcengine1_crc_next[15], core_tx_crc_liteethmaccrcengine1_crc_next[16], core_tx_crc_liteethmaccrcengine1_crc_next[17], core_tx_crc_liteethmaccrcengine1_crc_next[18], core_tx_crc_liteethmaccrcengine1_crc_next[19], core_tx_crc_liteethmaccrcengine1_crc_next[20], core_tx_crc_liteethmaccrcengine1_crc_next[21], core_tx_crc_liteethmaccrcengine1_crc_next[22], core_tx_crc_liteethmaccrcengine1_crc_next[23], core_tx_crc_liteethmaccrcengine1_crc_next[24], core_tx_crc_liteethmaccrcengine1_crc_next[25], core_tx_crc_liteethmaccrcengine1_crc_next[26], core_tx_crc_liteethmaccrcengine1_crc_next[27], core_tx_crc_liteethmaccrcengine1_crc_next[28], core_tx_crc_liteethmaccrcengine1_crc_next[29], core_tx_crc_liteethmaccrcengine1_crc_next[30], core_tx_crc_liteethmaccrcengine1_crc_next[31]} ^ 32'd4294967295);
		core_tx_crc_error <= (core_tx_crc_liteethmaccrcengine1_crc_next != 32'd3338984827);
	end
	if (core_tx_crc_be[2]) begin
		core_tx_crc_value <= ({core_tx_crc_liteethmaccrcengine2_crc_next[0], core_tx_crc_liteethmaccrcengine2_crc_next[1], core_tx_crc_liteethmaccrcengine2_crc_next[2], core_tx_crc_liteethmaccrcengine2_crc_next[3], core_tx_crc_liteethmaccrcengine2_crc_next[4], core_tx_crc_liteethmaccrcengine2_crc_next[5], core_tx_crc_liteethmaccrcengine2_crc_next[6], core_tx_crc_liteethmaccrcengine2_crc_next[7], core_tx_crc_liteethmaccrcengine2_crc_next[8], core_tx_crc_liteethmaccrcengine2_crc_next[9], core_tx_crc_liteethmaccrcengine2_crc_next[10], core_tx_crc_liteethmaccrcengine2_crc_next[11], core_tx_crc_liteethmaccrcengine2_crc_next[12], core_tx_crc_liteethmaccrcengine2_crc_next[13], core_tx_crc_liteethmaccrcengine2_crc_next[14], core_tx_crc_liteethmaccrcengine2_crc_next[15], core_tx_crc_liteethmaccrcengine2_crc_next[16], core_tx_crc_liteethmaccrcengine2_crc_next[17], core_tx_crc_liteethmaccrcengine2_crc_next[18], core_tx_crc_liteethmaccrcengine2_crc_next[19], core_tx_crc_liteethmaccrcengine2_crc_next[20], core_tx_crc_liteethmaccrcengine2_crc_next[21], core_tx_crc_liteethmaccrcengine2_crc_next[22], core_tx_crc_liteethmaccrcengine2_crc_next[23], core_tx_crc_liteethmaccrcengine2_crc_next[24], core_tx_crc_liteethmaccrcengine2_crc_next[25], core_tx_crc_liteethmaccrcengine2_crc_next[26], core_tx_crc_liteethmaccrcengine2_crc_next[27], core_tx_crc_liteethmaccrcengine2_crc_next[28], core_tx_crc_liteethmaccrcengine2_crc_next[29], core_tx_crc_liteethmaccrcengine2_crc_next[30], core_tx_crc_liteethmaccrcengine2_crc_next[31]} ^ 32'd4294967295);
		core_tx_crc_error <= (core_tx_crc_liteethmaccrcengine2_crc_next != 32'd3338984827);
	end
	if (core_tx_crc_be[3]) begin
		core_tx_crc_value <= ({core_tx_crc_liteethmaccrcengine3_crc_next[0], core_tx_crc_liteethmaccrcengine3_crc_next[1], core_tx_crc_liteethmaccrcengine3_crc_next[2], core_tx_crc_liteethmaccrcengine3_crc_next[3], core_tx_crc_liteethmaccrcengine3_crc_next[4], core_tx_crc_liteethmaccrcengine3_crc_next[5], core_tx_crc_liteethmaccrcengine3_crc_next[6], core_tx_crc_liteethmaccrcengine3_crc_next[7], core_tx_crc_liteethmaccrcengine3_crc_next[8], core_tx_crc_liteethmaccrcengine3_crc_next[9], core_tx_crc_liteethmaccrcengine3_crc_next[10], core_tx_crc_liteethmaccrcengine3_crc_next[11], core_tx_crc_liteethmaccrcengine3_crc_next[12], core_tx_crc_liteethmaccrcengine3_crc_next[13], core_tx_crc_liteethmaccrcengine3_crc_next[14], core_tx_crc_liteethmaccrcengine3_crc_next[15], core_tx_crc_liteethmaccrcengine3_crc_next[16], core_tx_crc_liteethmaccrcengine3_crc_next[17], core_tx_crc_liteethmaccrcengine3_crc_next[18], core_tx_crc_liteethmaccrcengine3_crc_next[19], core_tx_crc_liteethmaccrcengine3_crc_next[20], core_tx_crc_liteethmaccrcengine3_crc_next[21], core_tx_crc_liteethmaccrcengine3_crc_next[22], core_tx_crc_liteethmaccrcengine3_crc_next[23], core_tx_crc_liteethmaccrcengine3_crc_next[24], core_tx_crc_liteethmaccrcengine3_crc_next[25], core_tx_crc_liteethmaccrcengine3_crc_next[26], core_tx_crc_liteethmaccrcengine3_crc_next[27], core_tx_crc_liteethmaccrcengine3_crc_next[28], core_tx_crc_liteethmaccrcengine3_crc_next[29], core_tx_crc_liteethmaccrcengine3_crc_next[30], core_tx_crc_liteethmaccrcengine3_crc_next[31]} ^ 32'd4294967295);
		core_tx_crc_error <= (core_tx_crc_liteethmaccrcengine3_crc_next != 32'd3338984827);
	end
// synthesis translate_off
	dummy_d_1 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_2;
// synthesis translate_on
always @(*) begin
	core_tx_crc_liteethmaccrcengine0_crc_next <= 32'd0;
	core_tx_crc_liteethmaccrcengine0_crc_next[0] <= (((core_tx_crc_liteethmaccrcengine0_crc_prev[24] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[1] <= (((((((core_tx_crc_liteethmaccrcengine0_crc_prev[25] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[2] <= (((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[26] ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[3] <= (((((((core_tx_crc_liteethmaccrcengine0_crc_prev[27] ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[4] <= (((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[28] ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[5] <= (((((((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[29] ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[6] <= (((((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[30] ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[7] <= (((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[31] ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[8] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[0] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[9] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[1] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[10] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[2] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[11] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[3] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[12] <= ((((((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[4] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[13] <= ((((((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[5] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[14] <= ((((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[6] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]);
	core_tx_crc_liteethmaccrcengine0_crc_next[15] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[7] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]);
	core_tx_crc_liteethmaccrcengine0_crc_next[16] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[8] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[17] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[9] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[18] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[10] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]);
	core_tx_crc_liteethmaccrcengine0_crc_next[19] <= ((((core_tx_crc_liteethmaccrcengine0_crc_prev[11] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]);
	core_tx_crc_liteethmaccrcengine0_crc_next[20] <= ((core_tx_crc_liteethmaccrcengine0_crc_prev[12] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]);
	core_tx_crc_liteethmaccrcengine0_crc_next[21] <= ((core_tx_crc_liteethmaccrcengine0_crc_prev[13] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]);
	core_tx_crc_liteethmaccrcengine0_crc_next[22] <= ((core_tx_crc_liteethmaccrcengine0_crc_prev[14] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[23] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[15] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_data[6]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[24] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[16] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[25] <= ((((core_tx_crc_liteethmaccrcengine0_crc_prev[17] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]);
	core_tx_crc_liteethmaccrcengine0_crc_next[26] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[18] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_data[7]);
	core_tx_crc_liteethmaccrcengine0_crc_next[27] <= ((((((((core_tx_crc_liteethmaccrcengine0_crc_prev[19] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_data[6]);
	core_tx_crc_liteethmaccrcengine0_crc_next[28] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[20] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine0_data[5]);
	core_tx_crc_liteethmaccrcengine0_crc_next[29] <= ((((((core_tx_crc_liteethmaccrcengine0_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine0_data[1]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine0_data[4]);
	core_tx_crc_liteethmaccrcengine0_crc_next[30] <= ((((core_tx_crc_liteethmaccrcengine0_crc_prev[22] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine0_data[0]) ^ core_tx_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine0_data[3]);
	core_tx_crc_liteethmaccrcengine0_crc_next[31] <= ((core_tx_crc_liteethmaccrcengine0_crc_prev[23] ^ core_tx_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine0_data[2]);
// synthesis translate_off
	dummy_d_2 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_3;
// synthesis translate_on
always @(*) begin
	core_tx_crc_liteethmaccrcengine1_crc_next <= 32'd0;
	core_tx_crc_liteethmaccrcengine1_crc_next[0] <= (((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[16] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[1] <= (((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[17] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[2] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[18] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[3] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[19] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[4] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[20] ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[5] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[6] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[22] ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[7] <= (((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[23] ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[8] <= (((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[24] ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[9] <= (((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[25] ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[10] <= (((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[11] <= (((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[20] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[12] <= (((((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[13] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[22] ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[14] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[23] ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]);
	core_tx_crc_liteethmaccrcengine1_crc_next[15] <= (((((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[24] ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_data[12]);
	core_tx_crc_liteethmaccrcengine1_crc_next[16] <= ((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[0] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[17] <= ((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[1] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[18] <= ((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[2] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[13]);
	core_tx_crc_liteethmaccrcengine1_crc_next[19] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[3] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[12]);
	core_tx_crc_liteethmaccrcengine1_crc_next[20] <= ((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[4] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]);
	core_tx_crc_liteethmaccrcengine1_crc_next[21] <= ((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[5] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]);
	core_tx_crc_liteethmaccrcengine1_crc_next[22] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[6] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[23] <= ((((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[7] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_data[14]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[24] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[8] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_data[13]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[25] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[9] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]);
	core_tx_crc_liteethmaccrcengine1_crc_next[26] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[10] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_data[12]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_data[15]);
	core_tx_crc_liteethmaccrcengine1_crc_next[27] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[11] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_data[11]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_data[14]);
	core_tx_crc_liteethmaccrcengine1_crc_next[28] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[12] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_data[10]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine1_data[3]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_data[13]);
	core_tx_crc_liteethmaccrcengine1_crc_next[29] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[13] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine1_data[9]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine1_data[2]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_data[12]);
	core_tx_crc_liteethmaccrcengine1_crc_next[30] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[14] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine1_data[8]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine1_data[1]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine1_data[5]) ^ core_tx_crc_liteethmaccrcengine1_data[11]);
	core_tx_crc_liteethmaccrcengine1_crc_next[31] <= ((((((((((core_tx_crc_liteethmaccrcengine1_crc_prev[15] ^ core_tx_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine1_data[6]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine1_data[7]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine1_data[0]) ^ core_tx_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine1_data[4]) ^ core_tx_crc_liteethmaccrcengine1_data[10]);
// synthesis translate_off
	dummy_d_3 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_4;
// synthesis translate_on
always @(*) begin
	core_tx_crc_liteethmaccrcengine2_crc_next <= 32'd0;
	core_tx_crc_liteethmaccrcengine2_crc_next[0] <= (((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[8] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[1] <= (((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[9] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[2] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[10] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[3] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[11] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[4] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[12] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[5] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[13] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[6] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[14] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[7] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[15] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[8] <= (((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[16] ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[9] <= (((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[17] ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[10] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[13] ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[11] <= (((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[12] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[12] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[13] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[13] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[14] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[14] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[15] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]);
	core_tx_crc_liteethmaccrcengine2_crc_next[15] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[16] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_data[20]);
	core_tx_crc_liteethmaccrcengine2_crc_next[16] <= (((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[27] ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[17] <= (((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[28] ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[18] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[29] ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[21]);
	core_tx_crc_liteethmaccrcengine2_crc_next[19] <= (((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[30] ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[20]);
	core_tx_crc_liteethmaccrcengine2_crc_next[20] <= (((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[31] ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[19]);
	core_tx_crc_liteethmaccrcengine2_crc_next[21] <= (((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[18]);
	core_tx_crc_liteethmaccrcengine2_crc_next[22] <= (((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[22] ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[23] <= (((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[23] ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_data[22]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[24] <= ((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[0] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine2_data[7]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_data[21]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[25] <= ((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[1] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine2_data[6]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]);
	core_tx_crc_liteethmaccrcengine2_crc_next[26] <= ((((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[2] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine2_data[5]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_data[20]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_data[23]);
	core_tx_crc_liteethmaccrcengine2_crc_next[27] <= ((((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[3] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine2_data[4]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_data[19]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_data[22]);
	core_tx_crc_liteethmaccrcengine2_crc_next[28] <= ((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[4] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine2_data[3]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_data[18]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine2_data[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_data[21]);
	core_tx_crc_liteethmaccrcengine2_crc_next[29] <= ((((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[5] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine2_data[2]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_data[17]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine2_data[10]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_data[20]);
	core_tx_crc_liteethmaccrcengine2_crc_next[30] <= ((((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[6] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine2_data[1]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_data[16]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine2_data[9]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine2_data[13]) ^ core_tx_crc_liteethmaccrcengine2_data[19]);
	core_tx_crc_liteethmaccrcengine2_crc_next[31] <= ((((((((((((core_tx_crc_liteethmaccrcengine2_crc_prev[7] ^ core_tx_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine2_data[0]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine2_data[14]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine2_data[15]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine2_data[8]) ^ core_tx_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine2_data[12]) ^ core_tx_crc_liteethmaccrcengine2_data[18]);
// synthesis translate_off
	dummy_d_4 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_5;
// synthesis translate_on
always @(*) begin
	core_tx_crc_liteethmaccrcengine3_crc_next <= 32'd0;
	core_tx_crc_liteethmaccrcengine3_crc_next[0] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[0] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[1] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[1] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[2] <= (((((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[2] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[3] <= (((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[3] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[4] <= (((((((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[4] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[5] <= (((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[5] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[6] <= (((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[6] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[7] <= (((((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[7] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[8] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[8] ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[9] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[9] ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[10] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[5] ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[11] <= (((((((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[4] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[12] <= (((((((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[5] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[13] <= (((((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[6] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[14] <= (((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[7] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]);
	core_tx_crc_liteethmaccrcengine3_crc_next[15] <= (((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[8] ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_data[28]);
	core_tx_crc_liteethmaccrcengine3_crc_next[16] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[19] ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[17] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[20] ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[18] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[29]);
	core_tx_crc_liteethmaccrcengine3_crc_next[19] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[22] ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[28]);
	core_tx_crc_liteethmaccrcengine3_crc_next[20] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[23] ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_data[27]);
	core_tx_crc_liteethmaccrcengine3_crc_next[21] <= (((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[24] ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[26]);
	core_tx_crc_liteethmaccrcengine3_crc_next[22] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[14] ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[23] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[15] ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_data[30]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[24] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[16] ^ core_tx_crc_liteethmaccrcengine3_data[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_data[29]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[25] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[17] ^ core_tx_crc_liteethmaccrcengine3_data[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]);
	core_tx_crc_liteethmaccrcengine3_crc_next[26] <= (((((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[18] ^ core_tx_crc_liteethmaccrcengine3_data[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_data[28]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_data[31]);
	core_tx_crc_liteethmaccrcengine3_crc_next[27] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[19] ^ core_tx_crc_liteethmaccrcengine3_data[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_data[27]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_data[30]);
	core_tx_crc_liteethmaccrcengine3_crc_next[28] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[20] ^ core_tx_crc_liteethmaccrcengine3_data[11]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_data[26]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_data[19]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_data[29]);
	core_tx_crc_liteethmaccrcengine3_crc_next[29] <= (((((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[21] ^ core_tx_crc_liteethmaccrcengine3_data[10]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_data[25]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_data[18]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_data[28]);
	core_tx_crc_liteethmaccrcengine3_crc_next[30] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[22] ^ core_tx_crc_liteethmaccrcengine3_data[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_tx_crc_liteethmaccrcengine3_data[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_data[24]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_data[17]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_tx_crc_liteethmaccrcengine3_data[21]) ^ core_tx_crc_liteethmaccrcengine3_data[27]);
	core_tx_crc_liteethmaccrcengine3_crc_next[31] <= (((((((((((((((((((((((((core_tx_crc_liteethmaccrcengine3_crc_prev[23] ^ core_tx_crc_liteethmaccrcengine3_data[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_tx_crc_liteethmaccrcengine3_data[3]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_tx_crc_liteethmaccrcengine3_data[4]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_tx_crc_liteethmaccrcengine3_data[6]) ^ core_tx_crc_liteethmaccrcengine3_data[22]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_tx_crc_liteethmaccrcengine3_data[7]) ^ core_tx_crc_liteethmaccrcengine3_data[23]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_tx_crc_liteethmaccrcengine3_data[2]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_tx_crc_liteethmaccrcengine3_data[0]) ^ core_tx_crc_liteethmaccrcengine3_data[16]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_tx_crc_liteethmaccrcengine3_data[1]) ^ core_tx_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_tx_crc_liteethmaccrcengine3_data[20]) ^ core_tx_crc_liteethmaccrcengine3_data[26]);
// synthesis translate_off
	dummy_d_5 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_6;
// synthesis translate_on
always @(*) begin
	core_tx_crc_sink_ready <= 1'd0;
	core_tx_crc_source_valid <= 1'd0;
	core_tx_crc_source_first <= 1'd0;
	core_tx_crc_source_last <= 1'd0;
	core_tx_crc_source_payload_data <= 32'd0;
	core_tx_crc_source_payload_last_be <= 4'd0;
	core_tx_crc_source_payload_error <= 4'd0;
	core_tx_crc_ce <= 1'd0;
	core_tx_crc_reset <= 1'd0;
	txdatapath_bufferizeendpoints_next_state <= 2'd0;
	core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value0 <= 32'd0;
	core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value_ce0 <= 1'd0;
	core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value1 <= 4'd0;
	core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value_ce1 <= 1'd0;
	txdatapath_bufferizeendpoints_next_state <= txdatapath_bufferizeendpoints_state;
	case (txdatapath_bufferizeendpoints_state)
		1'd1: begin
			core_tx_crc_ce <= (core_tx_crc_sink_valid & core_tx_crc_source_ready);
			core_tx_crc_source_valid <= core_tx_crc_sink_valid;
			core_tx_crc_sink_ready <= core_tx_crc_source_ready;
			core_tx_crc_source_first <= core_tx_crc_sink_first;
			core_tx_crc_source_last <= core_tx_crc_sink_last;
			core_tx_crc_source_payload_data <= core_tx_crc_sink_payload_data;
			core_tx_crc_source_payload_last_be <= core_tx_crc_sink_payload_last_be;
			core_tx_crc_source_payload_error <= core_tx_crc_sink_payload_error;
			core_tx_crc_source_last <= 1'd0;
			core_tx_crc_source_payload_last_be <= 1'd0;
			if (core_tx_crc_sink_last) begin
				if (core_tx_crc_sink_payload_last_be[0]) begin
					core_tx_crc_source_payload_data <= slice_proxy0[31:0];
				end
				if (core_tx_crc_sink_payload_last_be[1]) begin
					core_tx_crc_source_payload_data <= slice_proxy1[31:0];
				end
				if (core_tx_crc_sink_payload_last_be[2]) begin
					core_tx_crc_source_payload_data <= slice_proxy2[31:0];
				end
				if (core_tx_crc_sink_payload_last_be[3]) begin
					core_tx_crc_source_payload_data <= slice_proxy3[31:0];
				end
				if ((1'd0 & (core_tx_crc_sink_payload_last_be <= 4'd15))) begin
					core_tx_crc_source_last <= 1'd1;
					core_tx_crc_source_payload_last_be <= (core_tx_crc_sink_payload_last_be <<< 1'd0);
				end
			end
			if (((core_tx_crc_sink_valid & core_tx_crc_sink_last) & core_tx_crc_source_ready)) begin
				if ((1'd0 & (core_tx_crc_sink_payload_last_be <= 4'd15))) begin
					txdatapath_bufferizeendpoints_next_state <= 1'd0;
				end else begin
					core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value0 <= core_tx_crc_value;
					core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value_ce0 <= 1'd1;
					if (1'd0) begin
						core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value1 <= (core_tx_crc_sink_payload_last_be >>> 3'd4);
						core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value_ce1 <= 1'd1;
					end else begin
						core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value1 <= core_tx_crc_sink_payload_last_be;
						core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value_ce1 <= 1'd1;
					end
					txdatapath_bufferizeendpoints_next_state <= 2'd2;
				end
			end
		end
		2'd2: begin
			core_tx_crc_source_valid <= 1'd1;
			core_tx_crc_source_last <= 1'd1;
			core_tx_crc_source_payload_data <= core_tx_crc_value;
			core_tx_crc_source_payload_last_be <= core_tx_crc_last_be;
			if (core_tx_crc_last_be[0]) begin
				core_tx_crc_source_payload_data <= core_tx_crc_crc_packet[31:24];
			end
			if (core_tx_crc_last_be[1]) begin
				core_tx_crc_source_payload_data <= core_tx_crc_crc_packet[31:16];
			end
			if (core_tx_crc_last_be[2]) begin
				core_tx_crc_source_payload_data <= core_tx_crc_crc_packet[31:8];
			end
			if (core_tx_crc_last_be[3]) begin
				core_tx_crc_source_payload_data <= core_tx_crc_crc_packet[31:0];
			end
			if (core_tx_crc_source_ready) begin
				txdatapath_bufferizeendpoints_next_state <= 1'd0;
			end
		end
		default: begin
			core_tx_crc_reset <= 1'd1;
			core_tx_crc_sink_ready <= 1'd1;
			if (core_tx_crc_sink_valid) begin
				core_tx_crc_sink_ready <= 1'd0;
				txdatapath_bufferizeendpoints_next_state <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_6 <= dummy_s;
// synthesis translate_on
end
assign core_tx_crc_pipe_valid_sink_ready = ((~core_tx_crc_pipe_valid_source_valid) | core_tx_crc_pipe_valid_source_ready);
assign core_tx_crc_pipe_valid_sink_valid = core_tx_crc_sink_sink_valid;
assign core_tx_crc_sink_sink_ready = core_tx_crc_pipe_valid_sink_ready;
assign core_tx_crc_pipe_valid_sink_first = core_tx_crc_sink_sink_first;
assign core_tx_crc_pipe_valid_sink_last = core_tx_crc_sink_sink_last;
assign core_tx_crc_pipe_valid_sink_payload_data = core_tx_crc_sink_sink_payload_data;
assign core_tx_crc_pipe_valid_sink_payload_last_be = core_tx_crc_sink_sink_payload_last_be;
assign core_tx_crc_pipe_valid_sink_payload_error = core_tx_crc_sink_sink_payload_error;
assign core_tx_crc_source_source_valid = core_tx_crc_pipe_valid_source_valid;
assign core_tx_crc_pipe_valid_source_ready = core_tx_crc_source_source_ready;
assign core_tx_crc_source_source_first = core_tx_crc_pipe_valid_source_first;
assign core_tx_crc_source_source_last = core_tx_crc_pipe_valid_source_last;
assign core_tx_crc_source_source_payload_data = core_tx_crc_pipe_valid_source_payload_data;
assign core_tx_crc_source_source_payload_last_be = core_tx_crc_pipe_valid_source_payload_last_be;
assign core_tx_crc_source_source_payload_error = core_tx_crc_pipe_valid_source_payload_error;
assign core_tx_preamble_source_payload_last_be = core_tx_preamble_sink_payload_last_be;

// synthesis translate_off
reg dummy_d_7;
// synthesis translate_on
always @(*) begin
	core_tx_preamble_sink_ready <= 1'd0;
	core_tx_preamble_source_valid <= 1'd0;
	core_tx_preamble_source_first <= 1'd0;
	core_tx_preamble_source_last <= 1'd0;
	core_tx_preamble_source_payload_data <= 32'd0;
	core_tx_preamble_source_payload_error <= 4'd0;
	txdatapath_liteethmacpreambleinserter_next_state <= 2'd0;
	core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value <= 1'd0;
	core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value_ce <= 1'd0;
	core_tx_preamble_source_payload_data <= core_tx_preamble_sink_payload_data;
	txdatapath_liteethmacpreambleinserter_next_state <= txdatapath_liteethmacpreambleinserter_state;
	case (txdatapath_liteethmacpreambleinserter_state)
		1'd1: begin
			core_tx_preamble_source_valid <= 1'd1;
			case (core_tx_preamble_count)
				1'd0: begin
					core_tx_preamble_source_payload_data <= core_tx_preamble_preamble[31:0];
				end
				default: begin
					core_tx_preamble_source_payload_data <= core_tx_preamble_preamble[63:32];
				end
			endcase
			if (core_tx_preamble_source_ready) begin
				if ((core_tx_preamble_count == 1'd1)) begin
					txdatapath_liteethmacpreambleinserter_next_state <= 2'd2;
				end else begin
					core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value <= (core_tx_preamble_count + 1'd1);
					core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value_ce <= 1'd1;
				end
			end
		end
		2'd2: begin
			core_tx_preamble_source_valid <= core_tx_preamble_sink_valid;
			core_tx_preamble_sink_ready <= core_tx_preamble_source_ready;
			core_tx_preamble_source_first <= core_tx_preamble_sink_first;
			core_tx_preamble_source_last <= core_tx_preamble_sink_last;
			core_tx_preamble_source_payload_error <= core_tx_preamble_sink_payload_error;
			if (((core_tx_preamble_sink_valid & core_tx_preamble_sink_last) & core_tx_preamble_source_ready)) begin
				txdatapath_liteethmacpreambleinserter_next_state <= 1'd0;
			end
		end
		default: begin
			core_tx_preamble_sink_ready <= 1'd1;
			core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value <= 1'd0;
			core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value_ce <= 1'd1;
			if (core_tx_preamble_sink_valid) begin
				core_tx_preamble_sink_ready <= 1'd0;
				txdatapath_liteethmacpreambleinserter_next_state <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_7 <= dummy_s;
// synthesis translate_on
end
assign core_tx_cdc_cdc_sink_valid = core_tx_cdc_sink_sink_valid;
assign core_tx_cdc_sink_sink_ready = core_tx_cdc_cdc_sink_ready;
assign core_tx_cdc_cdc_sink_first = core_tx_cdc_sink_sink_first;
assign core_tx_cdc_cdc_sink_last = core_tx_cdc_sink_sink_last;
assign core_tx_cdc_cdc_sink_payload_data = core_tx_cdc_sink_sink_payload_data;
assign core_tx_cdc_cdc_sink_payload_last_be = core_tx_cdc_sink_sink_payload_last_be;
assign core_tx_cdc_cdc_sink_payload_error = core_tx_cdc_sink_sink_payload_error;
assign core_tx_cdc_source_source_valid = core_tx_cdc_cdc_source_valid;
assign core_tx_cdc_cdc_source_ready = core_tx_cdc_source_source_ready;
assign core_tx_cdc_source_source_first = core_tx_cdc_cdc_source_first;
assign core_tx_cdc_source_source_last = core_tx_cdc_cdc_source_last;
assign core_tx_cdc_source_source_payload_data = core_tx_cdc_cdc_source_payload_data;
assign core_tx_cdc_source_source_payload_last_be = core_tx_cdc_cdc_source_payload_last_be;
assign core_tx_cdc_source_source_payload_error = core_tx_cdc_cdc_source_payload_error;
assign core_tx_cdc_cdc_asyncfifo_din = {core_tx_cdc_cdc_fifo_in_last, core_tx_cdc_cdc_fifo_in_first, core_tx_cdc_cdc_fifo_in_payload_error, core_tx_cdc_cdc_fifo_in_payload_last_be, core_tx_cdc_cdc_fifo_in_payload_data};
assign {core_tx_cdc_cdc_fifo_out_last, core_tx_cdc_cdc_fifo_out_first, core_tx_cdc_cdc_fifo_out_payload_error, core_tx_cdc_cdc_fifo_out_payload_last_be, core_tx_cdc_cdc_fifo_out_payload_data} = core_tx_cdc_cdc_asyncfifo_dout;
assign core_tx_cdc_cdc_sink_ready = core_tx_cdc_cdc_asyncfifo_writable;
assign core_tx_cdc_cdc_asyncfifo_we = core_tx_cdc_cdc_sink_valid;
assign core_tx_cdc_cdc_fifo_in_first = core_tx_cdc_cdc_sink_first;
assign core_tx_cdc_cdc_fifo_in_last = core_tx_cdc_cdc_sink_last;
assign core_tx_cdc_cdc_fifo_in_payload_data = core_tx_cdc_cdc_sink_payload_data;
assign core_tx_cdc_cdc_fifo_in_payload_last_be = core_tx_cdc_cdc_sink_payload_last_be;
assign core_tx_cdc_cdc_fifo_in_payload_error = core_tx_cdc_cdc_sink_payload_error;
assign core_tx_cdc_cdc_source_valid = core_tx_cdc_cdc_asyncfifo_readable;
assign core_tx_cdc_cdc_source_first = core_tx_cdc_cdc_fifo_out_first;
assign core_tx_cdc_cdc_source_last = core_tx_cdc_cdc_fifo_out_last;
assign core_tx_cdc_cdc_source_payload_data = core_tx_cdc_cdc_fifo_out_payload_data;
assign core_tx_cdc_cdc_source_payload_last_be = core_tx_cdc_cdc_fifo_out_payload_last_be;
assign core_tx_cdc_cdc_source_payload_error = core_tx_cdc_cdc_fifo_out_payload_error;
assign core_tx_cdc_cdc_asyncfifo_re = core_tx_cdc_cdc_source_ready;
assign core_tx_cdc_cdc_graycounter0_ce = (core_tx_cdc_cdc_asyncfifo_writable & core_tx_cdc_cdc_asyncfifo_we);
assign core_tx_cdc_cdc_graycounter1_ce = (core_tx_cdc_cdc_asyncfifo_readable & core_tx_cdc_cdc_asyncfifo_re);
assign core_tx_cdc_cdc_asyncfifo_writable = (((core_tx_cdc_cdc_graycounter0_q[11] == core_tx_cdc_cdc_consume_wdomain[11]) | (core_tx_cdc_cdc_graycounter0_q[10] == core_tx_cdc_cdc_consume_wdomain[10])) | (core_tx_cdc_cdc_graycounter0_q[9:0] != core_tx_cdc_cdc_consume_wdomain[9:0]));
assign core_tx_cdc_cdc_asyncfifo_readable = (core_tx_cdc_cdc_graycounter1_q != core_tx_cdc_cdc_produce_rdomain);
assign core_tx_cdc_cdc_wrport_adr = core_tx_cdc_cdc_graycounter0_q_binary[10:0];
assign core_tx_cdc_cdc_wrport_dat_w = core_tx_cdc_cdc_asyncfifo_din;
assign core_tx_cdc_cdc_wrport_we = core_tx_cdc_cdc_graycounter0_ce;
assign core_tx_cdc_cdc_rdport_adr = core_tx_cdc_cdc_graycounter1_q_next_binary[10:0];
assign core_tx_cdc_cdc_asyncfifo_dout = core_tx_cdc_cdc_rdport_dat_r;

// synthesis translate_off
reg dummy_d_8;
// synthesis translate_on
always @(*) begin
	core_tx_cdc_cdc_graycounter0_q_next_binary <= 12'd0;
	if (core_tx_cdc_cdc_graycounter0_ce) begin
		core_tx_cdc_cdc_graycounter0_q_next_binary <= (core_tx_cdc_cdc_graycounter0_q_binary + 1'd1);
	end else begin
		core_tx_cdc_cdc_graycounter0_q_next_binary <= core_tx_cdc_cdc_graycounter0_q_binary;
	end
// synthesis translate_off
	dummy_d_8 <= dummy_s;
// synthesis translate_on
end
assign core_tx_cdc_cdc_graycounter0_q_next = (core_tx_cdc_cdc_graycounter0_q_next_binary ^ core_tx_cdc_cdc_graycounter0_q_next_binary[11:1]);

// synthesis translate_off
reg dummy_d_9;
// synthesis translate_on
always @(*) begin
	core_tx_cdc_cdc_graycounter1_q_next_binary <= 12'd0;
	if (core_tx_cdc_cdc_graycounter1_ce) begin
		core_tx_cdc_cdc_graycounter1_q_next_binary <= (core_tx_cdc_cdc_graycounter1_q_binary + 1'd1);
	end else begin
		core_tx_cdc_cdc_graycounter1_q_next_binary <= core_tx_cdc_cdc_graycounter1_q_binary;
	end
// synthesis translate_off
	dummy_d_9 <= dummy_s;
// synthesis translate_on
end
assign core_tx_cdc_cdc_graycounter1_q_next = (core_tx_cdc_cdc_graycounter1_q_next_binary ^ core_tx_cdc_cdc_graycounter1_q_next_binary[11:1]);
assign core_tx_converter_converter_sink_valid = core_tx_converter_sink_valid;
assign core_tx_converter_converter_sink_first = core_tx_converter_sink_first;
assign core_tx_converter_converter_sink_last = core_tx_converter_sink_last;
assign core_tx_converter_sink_ready = core_tx_converter_converter_sink_ready;

// synthesis translate_off
reg dummy_d_10;
// synthesis translate_on
always @(*) begin
	core_tx_converter_converter_sink_payload_data <= 40'd0;
	core_tx_converter_converter_sink_payload_data[7:0] <= core_tx_converter_sink_payload_data[7:0];
	core_tx_converter_converter_sink_payload_data[8] <= core_tx_converter_sink_payload_last_be[0];
	core_tx_converter_converter_sink_payload_data[9] <= core_tx_converter_sink_payload_error[0];
	core_tx_converter_converter_sink_payload_data[17:10] <= core_tx_converter_sink_payload_data[15:8];
	core_tx_converter_converter_sink_payload_data[18] <= core_tx_converter_sink_payload_last_be[1];
	core_tx_converter_converter_sink_payload_data[19] <= core_tx_converter_sink_payload_error[1];
	core_tx_converter_converter_sink_payload_data[27:20] <= core_tx_converter_sink_payload_data[23:16];
	core_tx_converter_converter_sink_payload_data[28] <= core_tx_converter_sink_payload_last_be[2];
	core_tx_converter_converter_sink_payload_data[29] <= core_tx_converter_sink_payload_error[2];
	core_tx_converter_converter_sink_payload_data[37:30] <= core_tx_converter_sink_payload_data[31:24];
	core_tx_converter_converter_sink_payload_data[38] <= core_tx_converter_sink_payload_last_be[3];
	core_tx_converter_converter_sink_payload_data[39] <= core_tx_converter_sink_payload_error[3];
// synthesis translate_off
	dummy_d_10 <= dummy_s;
// synthesis translate_on
end
assign core_tx_converter_source_valid = core_tx_converter_source_source_valid;
assign core_tx_converter_source_first = core_tx_converter_source_source_first;
assign core_tx_converter_source_last = core_tx_converter_source_source_last;
assign core_tx_converter_source_source_ready = core_tx_converter_source_ready;
assign {core_tx_converter_source_payload_error, core_tx_converter_source_payload_last_be, core_tx_converter_source_payload_data} = core_tx_converter_source_source_payload_data;
assign core_tx_converter_source_source_valid = core_tx_converter_converter_source_valid;
assign core_tx_converter_converter_source_ready = core_tx_converter_source_source_ready;
assign core_tx_converter_source_source_first = core_tx_converter_converter_source_first;
assign core_tx_converter_source_source_last = core_tx_converter_converter_source_last;
assign core_tx_converter_source_source_payload_data = core_tx_converter_converter_source_payload_data;
assign core_tx_converter_converter_first = (core_tx_converter_converter_mux == 1'd0);
assign core_tx_converter_converter_last = (core_tx_converter_converter_mux == 2'd3);
assign core_tx_converter_converter_source_valid = core_tx_converter_converter_sink_valid;
assign core_tx_converter_converter_source_first = (core_tx_converter_converter_sink_first & core_tx_converter_converter_first);
assign core_tx_converter_converter_source_last = (core_tx_converter_converter_sink_last & core_tx_converter_converter_last);
assign core_tx_converter_converter_sink_ready = (core_tx_converter_converter_last & core_tx_converter_converter_source_ready);

// synthesis translate_off
reg dummy_d_11;
// synthesis translate_on
always @(*) begin
	core_tx_converter_converter_source_payload_data <= 10'd0;
	case (core_tx_converter_converter_mux)
		1'd0: begin
			core_tx_converter_converter_source_payload_data <= core_tx_converter_converter_sink_payload_data[9:0];
		end
		1'd1: begin
			core_tx_converter_converter_source_payload_data <= core_tx_converter_converter_sink_payload_data[19:10];
		end
		2'd2: begin
			core_tx_converter_converter_source_payload_data <= core_tx_converter_converter_sink_payload_data[29:20];
		end
		default: begin
			core_tx_converter_converter_source_payload_data <= core_tx_converter_converter_sink_payload_data[39:30];
		end
	endcase
// synthesis translate_off
	dummy_d_11 <= dummy_s;
// synthesis translate_on
end
assign core_tx_converter_converter_source_payload_valid_token_count = core_tx_converter_converter_last;
assign core_tx_last_be_last_handler_sink_valid = core_tx_last_be_sink_sink_valid;
assign core_tx_last_be_sink_sink_ready = core_tx_last_be_last_handler_sink_ready;
assign core_tx_last_be_last_handler_sink_first = core_tx_last_be_sink_sink_first;
assign core_tx_last_be_last_handler_sink_last = core_tx_last_be_sink_sink_last;
assign core_tx_last_be_last_handler_sink_payload_data = core_tx_last_be_sink_sink_payload_data;
assign core_tx_last_be_last_handler_sink_payload_last_be = core_tx_last_be_sink_sink_payload_last_be;
assign core_tx_last_be_last_handler_sink_payload_error = core_tx_last_be_sink_sink_payload_error;
assign core_tx_last_be_source_source_valid = core_tx_last_be_last_handler_source_valid;
assign core_tx_last_be_last_handler_source_ready = core_tx_last_be_source_source_ready;
assign core_tx_last_be_source_source_first = core_tx_last_be_last_handler_source_first;
assign core_tx_last_be_source_source_last = core_tx_last_be_last_handler_source_last;
assign core_tx_last_be_source_source_payload_data = core_tx_last_be_last_handler_source_payload_data;
assign core_tx_last_be_source_source_payload_last_be = core_tx_last_be_last_handler_source_payload_last_be;
assign core_tx_last_be_source_source_payload_error = core_tx_last_be_last_handler_source_payload_error;

// synthesis translate_off
reg dummy_d_12;
// synthesis translate_on
always @(*) begin
	core_tx_last_be_last_handler_sink_ready <= 1'd0;
	core_tx_last_be_last_handler_source_valid <= 1'd0;
	core_tx_last_be_last_handler_source_first <= 1'd0;
	core_tx_last_be_last_handler_source_last <= 1'd0;
	core_tx_last_be_last_handler_source_payload_data <= 8'd0;
	core_tx_last_be_last_handler_source_payload_last_be <= 1'd0;
	core_tx_last_be_last_handler_source_payload_error <= 1'd0;
	txdatapath_liteethmactxlastbe_next_state <= 1'd0;
	txdatapath_liteethmactxlastbe_next_state <= txdatapath_liteethmactxlastbe_state;
	case (txdatapath_liteethmactxlastbe_state)
		1'd1: begin
			core_tx_last_be_last_handler_sink_ready <= 1'd1;
			if ((core_tx_last_be_last_handler_sink_valid & core_tx_last_be_last_handler_sink_last)) begin
				txdatapath_liteethmactxlastbe_next_state <= 1'd0;
			end
		end
		default: begin
			core_tx_last_be_last_handler_source_valid <= core_tx_last_be_last_handler_sink_valid;
			core_tx_last_be_last_handler_sink_ready <= core_tx_last_be_last_handler_source_ready;
			core_tx_last_be_last_handler_source_first <= core_tx_last_be_last_handler_sink_first;
			core_tx_last_be_last_handler_source_last <= core_tx_last_be_last_handler_sink_last;
			core_tx_last_be_last_handler_source_payload_data <= core_tx_last_be_last_handler_sink_payload_data;
			core_tx_last_be_last_handler_source_payload_last_be <= core_tx_last_be_last_handler_sink_payload_last_be;
			core_tx_last_be_last_handler_source_payload_error <= core_tx_last_be_last_handler_sink_payload_error;
			core_tx_last_be_last_handler_source_last <= (core_tx_last_be_last_handler_sink_payload_last_be != 1'd0);
			if ((core_tx_last_be_last_handler_sink_valid & core_tx_last_be_last_handler_sink_ready)) begin
				if ((core_tx_last_be_last_handler_source_last & (~core_tx_last_be_last_handler_sink_last))) begin
					txdatapath_liteethmactxlastbe_next_state <= 1'd1;
				end
			end
		end
	endcase
// synthesis translate_off
	dummy_d_12 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_13;
// synthesis translate_on
always @(*) begin
	core_tx_gap_sink_ready <= 1'd0;
	core_tx_gap_source_valid <= 1'd0;
	core_tx_gap_source_first <= 1'd0;
	core_tx_gap_source_last <= 1'd0;
	core_tx_gap_source_payload_data <= 8'd0;
	core_tx_gap_source_payload_last_be <= 1'd0;
	core_tx_gap_source_payload_error <= 1'd0;
	txdatapath_liteethmacgap_next_state <= 1'd0;
	core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value <= 4'd0;
	core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value_ce <= 1'd0;
	txdatapath_liteethmacgap_next_state <= txdatapath_liteethmacgap_state;
	case (txdatapath_liteethmacgap_state)
		1'd1: begin
			core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value <= (core_tx_gap_counter + 1'd1);
			core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value_ce <= 1'd1;
			if ((core_tx_gap_counter == 4'd11)) begin
				txdatapath_liteethmacgap_next_state <= 1'd0;
			end
		end
		default: begin
			core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value <= 1'd0;
			core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value_ce <= 1'd1;
			core_tx_gap_source_valid <= core_tx_gap_sink_valid;
			core_tx_gap_sink_ready <= core_tx_gap_source_ready;
			core_tx_gap_source_first <= core_tx_gap_sink_first;
			core_tx_gap_source_last <= core_tx_gap_sink_last;
			core_tx_gap_source_payload_data <= core_tx_gap_sink_payload_data;
			core_tx_gap_source_payload_last_be <= core_tx_gap_sink_payload_last_be;
			core_tx_gap_source_payload_error <= core_tx_gap_sink_payload_error;
			if (((core_tx_gap_sink_valid & core_tx_gap_sink_last) & core_tx_gap_sink_ready)) begin
				txdatapath_liteethmacgap_next_state <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_13 <= dummy_s;
// synthesis translate_on
end
assign core_tx_padding_sink_valid = core_sink_valid;
assign core_sink_ready = core_tx_padding_sink_ready;
assign core_tx_padding_sink_first = core_sink_first;
assign core_tx_padding_sink_last = core_sink_last;
assign core_tx_padding_sink_payload_data = core_sink_payload_data;
assign core_tx_padding_sink_payload_last_be = core_sink_payload_last_be;
assign core_tx_padding_sink_payload_error = core_sink_payload_error;
assign core_tx_crc_sink_sink_valid = core_tx_padding_source_valid;
assign core_tx_padding_source_ready = core_tx_crc_sink_sink_ready;
assign core_tx_crc_sink_sink_first = core_tx_padding_source_first;
assign core_tx_crc_sink_sink_last = core_tx_padding_source_last;
assign core_tx_crc_sink_sink_payload_data = core_tx_padding_source_payload_data;
assign core_tx_crc_sink_sink_payload_last_be = core_tx_padding_source_payload_last_be;
assign core_tx_crc_sink_sink_payload_error = core_tx_padding_source_payload_error;
assign core_tx_preamble_sink_valid = core_tx_crc_source_valid;
assign core_tx_crc_source_ready = core_tx_preamble_sink_ready;
assign core_tx_preamble_sink_first = core_tx_crc_source_first;
assign core_tx_preamble_sink_last = core_tx_crc_source_last;
assign core_tx_preamble_sink_payload_data = core_tx_crc_source_payload_data;
assign core_tx_preamble_sink_payload_last_be = core_tx_crc_source_payload_last_be;
assign core_tx_preamble_sink_payload_error = core_tx_crc_source_payload_error;
assign core_tx_cdc_sink_sink_valid = core_tx_preamble_source_valid;
assign core_tx_preamble_source_ready = core_tx_cdc_sink_sink_ready;
assign core_tx_cdc_sink_sink_first = core_tx_preamble_source_first;
assign core_tx_cdc_sink_sink_last = core_tx_preamble_source_last;
assign core_tx_cdc_sink_sink_payload_data = core_tx_preamble_source_payload_data;
assign core_tx_cdc_sink_sink_payload_last_be = core_tx_preamble_source_payload_last_be;
assign core_tx_cdc_sink_sink_payload_error = core_tx_preamble_source_payload_error;
assign core_tx_converter_sink_valid = core_tx_cdc_source_source_valid;
assign core_tx_cdc_source_source_ready = core_tx_converter_sink_ready;
assign core_tx_converter_sink_first = core_tx_cdc_source_source_first;
assign core_tx_converter_sink_last = core_tx_cdc_source_source_last;
assign core_tx_converter_sink_payload_data = core_tx_cdc_source_source_payload_data;
assign core_tx_converter_sink_payload_last_be = core_tx_cdc_source_source_payload_last_be;
assign core_tx_converter_sink_payload_error = core_tx_cdc_source_source_payload_error;
assign core_tx_last_be_sink_sink_valid = core_tx_converter_source_valid;
assign core_tx_converter_source_ready = core_tx_last_be_sink_sink_ready;
assign core_tx_last_be_sink_sink_first = core_tx_converter_source_first;
assign core_tx_last_be_sink_sink_last = core_tx_converter_source_last;
assign core_tx_last_be_sink_sink_payload_data = core_tx_converter_source_payload_data;
assign core_tx_last_be_sink_sink_payload_last_be = core_tx_converter_source_payload_last_be;
assign core_tx_last_be_sink_sink_payload_error = core_tx_converter_source_payload_error;
assign core_tx_gap_sink_valid = core_tx_last_be_source_source_valid;
assign core_tx_last_be_source_source_ready = core_tx_gap_sink_ready;
assign core_tx_gap_sink_first = core_tx_last_be_source_source_first;
assign core_tx_gap_sink_last = core_tx_last_be_source_source_last;
assign core_tx_gap_sink_payload_data = core_tx_last_be_source_source_payload_data;
assign core_tx_gap_sink_payload_last_be = core_tx_last_be_source_source_payload_last_be;
assign core_tx_gap_sink_payload_error = core_tx_last_be_source_source_payload_error;
assign sink_valid = core_tx_gap_source_valid;
assign core_tx_gap_source_ready = sink_ready;
assign sink_first = core_tx_gap_source_first;
assign sink_last = core_tx_gap_source_last;
assign sink_payload_data = core_tx_gap_source_payload_data;
assign sink_payload_last_be = core_tx_gap_source_payload_last_be;
assign sink_payload_error = core_tx_gap_source_payload_error;
assign core_pulsesynchronizer0_i = core_rx_preamble_error;
assign core_pulsesynchronizer1_i = core_liteethmaccrc32checker_error;
assign core_rx_last_be_source_valid = core_rx_last_be_sink_valid;
assign core_rx_last_be_sink_ready = core_rx_last_be_source_ready;
assign core_rx_last_be_source_first = core_rx_last_be_sink_first;
assign core_rx_last_be_source_last = core_rx_last_be_sink_last;
assign core_rx_last_be_source_payload_data = core_rx_last_be_sink_payload_data;
assign core_rx_last_be_source_payload_error = core_rx_last_be_sink_payload_error;

// synthesis translate_off
reg dummy_d_14;
// synthesis translate_on
always @(*) begin
	core_rx_last_be_source_payload_last_be <= 1'd0;
	core_rx_last_be_source_payload_last_be <= core_rx_last_be_sink_payload_last_be;
	if (1'd1) begin
		core_rx_last_be_source_payload_last_be <= core_rx_last_be_sink_last;
	end
// synthesis translate_off
	dummy_d_14 <= dummy_s;
// synthesis translate_on
end
assign core_rx_converter_converter_sink_valid = core_rx_converter_sink_valid;
assign core_rx_converter_converter_sink_first = core_rx_converter_sink_first;
assign core_rx_converter_converter_sink_last = core_rx_converter_sink_last;
assign core_rx_converter_sink_ready = core_rx_converter_converter_sink_ready;
assign core_rx_converter_converter_sink_payload_data = {core_rx_converter_sink_payload_error, core_rx_converter_sink_payload_last_be, core_rx_converter_sink_payload_data};
assign core_rx_converter_source_valid = core_rx_converter_source_source_valid;
assign core_rx_converter_source_first = core_rx_converter_source_source_first;
assign core_rx_converter_source_last = core_rx_converter_source_source_last;
assign core_rx_converter_source_source_ready = core_rx_converter_source_ready;

// synthesis translate_off
reg dummy_d_15;
// synthesis translate_on
always @(*) begin
	core_rx_converter_source_payload_data <= 32'd0;
	core_rx_converter_source_payload_data[7:0] <= core_rx_converter_source_source_payload_data[7:0];
	core_rx_converter_source_payload_data[15:8] <= core_rx_converter_source_source_payload_data[17:10];
	core_rx_converter_source_payload_data[23:16] <= core_rx_converter_source_source_payload_data[27:20];
	core_rx_converter_source_payload_data[31:24] <= core_rx_converter_source_source_payload_data[37:30];
// synthesis translate_off
	dummy_d_15 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_16;
// synthesis translate_on
always @(*) begin
	core_rx_converter_source_payload_last_be <= 4'd0;
	core_rx_converter_source_payload_last_be[0] <= core_rx_converter_source_source_payload_data[8];
	core_rx_converter_source_payload_last_be[1] <= core_rx_converter_source_source_payload_data[18];
	core_rx_converter_source_payload_last_be[2] <= core_rx_converter_source_source_payload_data[28];
	core_rx_converter_source_payload_last_be[3] <= core_rx_converter_source_source_payload_data[38];
// synthesis translate_off
	dummy_d_16 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_17;
// synthesis translate_on
always @(*) begin
	core_rx_converter_source_payload_error <= 4'd0;
	core_rx_converter_source_payload_error[0] <= core_rx_converter_source_source_payload_data[9];
	core_rx_converter_source_payload_error[1] <= core_rx_converter_source_source_payload_data[19];
	core_rx_converter_source_payload_error[2] <= core_rx_converter_source_source_payload_data[29];
	core_rx_converter_source_payload_error[3] <= core_rx_converter_source_source_payload_data[39];
// synthesis translate_off
	dummy_d_17 <= dummy_s;
// synthesis translate_on
end
assign core_rx_converter_source_source_valid = core_rx_converter_converter_source_valid;
assign core_rx_converter_converter_source_ready = core_rx_converter_source_source_ready;
assign core_rx_converter_source_source_first = core_rx_converter_converter_source_first;
assign core_rx_converter_source_source_last = core_rx_converter_converter_source_last;
assign core_rx_converter_source_source_payload_data = core_rx_converter_converter_source_payload_data;
assign core_rx_converter_converter_sink_ready = ((~core_rx_converter_converter_strobe_all) | core_rx_converter_converter_source_ready);
assign core_rx_converter_converter_source_valid = core_rx_converter_converter_strobe_all;
assign core_rx_converter_converter_load_part = (core_rx_converter_converter_sink_valid & core_rx_converter_converter_sink_ready);
assign core_rx_cdc_cdc_sink_valid = core_rx_cdc_sink_sink_valid;
assign core_rx_cdc_sink_sink_ready = core_rx_cdc_cdc_sink_ready;
assign core_rx_cdc_cdc_sink_first = core_rx_cdc_sink_sink_first;
assign core_rx_cdc_cdc_sink_last = core_rx_cdc_sink_sink_last;
assign core_rx_cdc_cdc_sink_payload_data = core_rx_cdc_sink_sink_payload_data;
assign core_rx_cdc_cdc_sink_payload_last_be = core_rx_cdc_sink_sink_payload_last_be;
assign core_rx_cdc_cdc_sink_payload_error = core_rx_cdc_sink_sink_payload_error;
assign core_rx_cdc_source_source_valid = core_rx_cdc_cdc_source_valid;
assign core_rx_cdc_cdc_source_ready = core_rx_cdc_source_source_ready;
assign core_rx_cdc_source_source_first = core_rx_cdc_cdc_source_first;
assign core_rx_cdc_source_source_last = core_rx_cdc_cdc_source_last;
assign core_rx_cdc_source_source_payload_data = core_rx_cdc_cdc_source_payload_data;
assign core_rx_cdc_source_source_payload_last_be = core_rx_cdc_cdc_source_payload_last_be;
assign core_rx_cdc_source_source_payload_error = core_rx_cdc_cdc_source_payload_error;
assign core_rx_cdc_cdc_asyncfifo_din = {core_rx_cdc_cdc_fifo_in_last, core_rx_cdc_cdc_fifo_in_first, core_rx_cdc_cdc_fifo_in_payload_error, core_rx_cdc_cdc_fifo_in_payload_last_be, core_rx_cdc_cdc_fifo_in_payload_data};
assign {core_rx_cdc_cdc_fifo_out_last, core_rx_cdc_cdc_fifo_out_first, core_rx_cdc_cdc_fifo_out_payload_error, core_rx_cdc_cdc_fifo_out_payload_last_be, core_rx_cdc_cdc_fifo_out_payload_data} = core_rx_cdc_cdc_asyncfifo_dout;
assign core_rx_cdc_cdc_sink_ready = core_rx_cdc_cdc_asyncfifo_writable;
assign core_rx_cdc_cdc_asyncfifo_we = core_rx_cdc_cdc_sink_valid;
assign core_rx_cdc_cdc_fifo_in_first = core_rx_cdc_cdc_sink_first;
assign core_rx_cdc_cdc_fifo_in_last = core_rx_cdc_cdc_sink_last;
assign core_rx_cdc_cdc_fifo_in_payload_data = core_rx_cdc_cdc_sink_payload_data;
assign core_rx_cdc_cdc_fifo_in_payload_last_be = core_rx_cdc_cdc_sink_payload_last_be;
assign core_rx_cdc_cdc_fifo_in_payload_error = core_rx_cdc_cdc_sink_payload_error;
assign core_rx_cdc_cdc_source_valid = core_rx_cdc_cdc_asyncfifo_readable;
assign core_rx_cdc_cdc_source_first = core_rx_cdc_cdc_fifo_out_first;
assign core_rx_cdc_cdc_source_last = core_rx_cdc_cdc_fifo_out_last;
assign core_rx_cdc_cdc_source_payload_data = core_rx_cdc_cdc_fifo_out_payload_data;
assign core_rx_cdc_cdc_source_payload_last_be = core_rx_cdc_cdc_fifo_out_payload_last_be;
assign core_rx_cdc_cdc_source_payload_error = core_rx_cdc_cdc_fifo_out_payload_error;
assign core_rx_cdc_cdc_asyncfifo_re = core_rx_cdc_cdc_source_ready;
assign core_rx_cdc_cdc_graycounter0_ce = (core_rx_cdc_cdc_asyncfifo_writable & core_rx_cdc_cdc_asyncfifo_we);
assign core_rx_cdc_cdc_graycounter1_ce = (core_rx_cdc_cdc_asyncfifo_readable & core_rx_cdc_cdc_asyncfifo_re);
assign core_rx_cdc_cdc_asyncfifo_writable = (((core_rx_cdc_cdc_graycounter0_q[11] == core_rx_cdc_cdc_consume_wdomain[11]) | (core_rx_cdc_cdc_graycounter0_q[10] == core_rx_cdc_cdc_consume_wdomain[10])) | (core_rx_cdc_cdc_graycounter0_q[9:0] != core_rx_cdc_cdc_consume_wdomain[9:0]));
assign core_rx_cdc_cdc_asyncfifo_readable = (core_rx_cdc_cdc_graycounter1_q != core_rx_cdc_cdc_produce_rdomain);
assign core_rx_cdc_cdc_wrport_adr = core_rx_cdc_cdc_graycounter0_q_binary[10:0];
assign core_rx_cdc_cdc_wrport_dat_w = core_rx_cdc_cdc_asyncfifo_din;
assign core_rx_cdc_cdc_wrport_we = core_rx_cdc_cdc_graycounter0_ce;
assign core_rx_cdc_cdc_rdport_adr = core_rx_cdc_cdc_graycounter1_q_next_binary[10:0];
assign core_rx_cdc_cdc_asyncfifo_dout = core_rx_cdc_cdc_rdport_dat_r;

// synthesis translate_off
reg dummy_d_18;
// synthesis translate_on
always @(*) begin
	core_rx_cdc_cdc_graycounter0_q_next_binary <= 12'd0;
	if (core_rx_cdc_cdc_graycounter0_ce) begin
		core_rx_cdc_cdc_graycounter0_q_next_binary <= (core_rx_cdc_cdc_graycounter0_q_binary + 1'd1);
	end else begin
		core_rx_cdc_cdc_graycounter0_q_next_binary <= core_rx_cdc_cdc_graycounter0_q_binary;
	end
// synthesis translate_off
	dummy_d_18 <= dummy_s;
// synthesis translate_on
end
assign core_rx_cdc_cdc_graycounter0_q_next = (core_rx_cdc_cdc_graycounter0_q_next_binary ^ core_rx_cdc_cdc_graycounter0_q_next_binary[11:1]);

// synthesis translate_off
reg dummy_d_19;
// synthesis translate_on
always @(*) begin
	core_rx_cdc_cdc_graycounter1_q_next_binary <= 12'd0;
	if (core_rx_cdc_cdc_graycounter1_ce) begin
		core_rx_cdc_cdc_graycounter1_q_next_binary <= (core_rx_cdc_cdc_graycounter1_q_binary + 1'd1);
	end else begin
		core_rx_cdc_cdc_graycounter1_q_next_binary <= core_rx_cdc_cdc_graycounter1_q_binary;
	end
// synthesis translate_off
	dummy_d_19 <= dummy_s;
// synthesis translate_on
end
assign core_rx_cdc_cdc_graycounter1_q_next = (core_rx_cdc_cdc_graycounter1_q_next_binary ^ core_rx_cdc_cdc_graycounter1_q_next_binary[11:1]);
assign core_rx_preamble_source_payload_data = core_rx_preamble_sink_payload_data;
assign core_rx_preamble_source_payload_last_be = core_rx_preamble_sink_payload_last_be;

// synthesis translate_off
reg dummy_d_20;
// synthesis translate_on
always @(*) begin
	core_rx_preamble_sink_ready <= 1'd0;
	core_rx_preamble_source_valid <= 1'd0;
	core_rx_preamble_source_first <= 1'd0;
	core_rx_preamble_source_last <= 1'd0;
	core_rx_preamble_source_payload_error <= 4'd0;
	core_rx_preamble_error <= 1'd0;
	rxdatapath_liteethmacpreamblechecker_next_state <= 1'd0;
	rxdatapath_liteethmacpreamblechecker_next_state <= rxdatapath_liteethmacpreamblechecker_state;
	case (rxdatapath_liteethmacpreamblechecker_state)
		1'd1: begin
			core_rx_preamble_source_valid <= core_rx_preamble_sink_valid;
			core_rx_preamble_sink_ready <= core_rx_preamble_source_ready;
			core_rx_preamble_source_first <= core_rx_preamble_sink_first;
			core_rx_preamble_source_last <= core_rx_preamble_sink_last;
			core_rx_preamble_source_payload_error <= core_rx_preamble_sink_payload_error;
			if (((core_rx_preamble_source_valid & core_rx_preamble_source_last) & core_rx_preamble_source_ready)) begin
				rxdatapath_liteethmacpreamblechecker_next_state <= 1'd0;
			end
		end
		default: begin
			core_rx_preamble_sink_ready <= 1'd1;
			if (((core_rx_preamble_sink_valid & (~core_rx_preamble_sink_last)) & (core_rx_preamble_sink_payload_data == core_rx_preamble_preamble[63:32]))) begin
				rxdatapath_liteethmacpreamblechecker_next_state <= 1'd1;
			end
			if ((core_rx_preamble_sink_valid & core_rx_preamble_sink_last)) begin
				core_rx_preamble_error <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_20 <= dummy_s;
// synthesis translate_on
end
assign core_pulsesynchronizer0_o = (core_pulsesynchronizer0_toggle_o ^ core_pulsesynchronizer0_toggle_o_r);
assign core_liteethmaccrc32checker_fifo_full = (core_liteethmaccrc32checker_syncfifo_level == 1'd1);
assign core_liteethmaccrc32checker_fifo_in = (core_liteethmaccrc32checker_sink_sink_valid & ((~core_liteethmaccrc32checker_fifo_full) | core_liteethmaccrc32checker_fifo_out));
assign core_liteethmaccrc32checker_fifo_out = (core_liteethmaccrc32checker_source_source_valid & core_liteethmaccrc32checker_source_source_ready);
assign core_liteethmaccrc32checker_syncfifo_sink_first = core_liteethmaccrc32checker_sink_sink_first;
assign core_liteethmaccrc32checker_syncfifo_sink_last = core_liteethmaccrc32checker_sink_sink_last;
assign core_liteethmaccrc32checker_syncfifo_sink_payload_data = core_liteethmaccrc32checker_sink_sink_payload_data;
assign core_liteethmaccrc32checker_syncfifo_sink_payload_last_be = core_liteethmaccrc32checker_sink_sink_payload_last_be;
assign core_liteethmaccrc32checker_syncfifo_sink_payload_error = core_liteethmaccrc32checker_sink_sink_payload_error;

// synthesis translate_off
reg dummy_d_21;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_syncfifo_sink_valid <= 1'd0;
	core_liteethmaccrc32checker_syncfifo_sink_valid <= core_liteethmaccrc32checker_sink_sink_valid;
	core_liteethmaccrc32checker_syncfifo_sink_valid <= core_liteethmaccrc32checker_fifo_in;
// synthesis translate_off
	dummy_d_21 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_22;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_sink_sink_ready <= 1'd0;
	core_liteethmaccrc32checker_sink_sink_ready <= core_liteethmaccrc32checker_syncfifo_sink_ready;
	core_liteethmaccrc32checker_sink_sink_ready <= core_liteethmaccrc32checker_fifo_in;
// synthesis translate_off
	dummy_d_22 <= dummy_s;
// synthesis translate_on
end
assign core_liteethmaccrc32checker_crc_data = core_liteethmaccrc32checker_sink_sink_payload_data;
assign core_liteethmaccrc32checker_crc_be = core_liteethmaccrc32checker_sink_sink_payload_last_be;
assign core_liteethmaccrc32checker_source_source_first = core_liteethmaccrc32checker_syncfifo_source_first;
assign core_liteethmaccrc32checker_source_source_payload_data = core_liteethmaccrc32checker_syncfifo_source_payload_data;
assign core_liteethmaccrc32checker_sink_sink_valid = core_bufferizeendpoints_source_source_valid;
assign core_bufferizeendpoints_source_source_ready = core_liteethmaccrc32checker_sink_sink_ready;
assign core_liteethmaccrc32checker_sink_sink_first = core_bufferizeendpoints_source_source_first;
assign core_liteethmaccrc32checker_sink_sink_last = core_bufferizeendpoints_source_source_last;
assign core_liteethmaccrc32checker_sink_sink_payload_data = core_bufferizeendpoints_source_source_payload_data;
assign core_liteethmaccrc32checker_sink_sink_payload_last_be = core_bufferizeendpoints_source_source_payload_last_be;
assign core_liteethmaccrc32checker_sink_sink_payload_error = core_bufferizeendpoints_source_source_payload_error;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data = core_liteethmaccrc32checker_crc_data;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev = core_liteethmaccrc32checker_crc_reg;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data = core_liteethmaccrc32checker_crc_data;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev = core_liteethmaccrc32checker_crc_reg;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data = core_liteethmaccrc32checker_crc_data;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev = core_liteethmaccrc32checker_crc_reg;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data = core_liteethmaccrc32checker_crc_data;
assign core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev = core_liteethmaccrc32checker_crc_reg;

// synthesis translate_off
reg dummy_d_23;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_crc_value <= 32'd0;
	core_liteethmaccrc32checker_crc_error0 <= 1'd0;
	if (core_liteethmaccrc32checker_crc_be[0]) begin
		core_liteethmaccrc32checker_crc_value <= ({core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[0], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[1], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[2], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[3], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[4], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[5], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[6], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[7], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[8], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[9], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[10], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[11], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[12], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[13], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[14], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[15], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[16], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[17], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[18], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[19], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[20], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[21], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[22], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[23], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[24], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[25], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[26], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[27], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[28], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[29], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[30], core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[31]} ^ 32'd4294967295);
		core_liteethmaccrc32checker_crc_error0 <= (core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next != 32'd3338984827);
	end
	if (core_liteethmaccrc32checker_crc_be[1]) begin
		core_liteethmaccrc32checker_crc_value <= ({core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[0], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[1], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[2], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[3], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[4], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[5], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[6], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[7], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[8], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[9], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[10], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[11], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[12], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[13], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[14], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[15], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[16], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[17], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[18], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[19], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[20], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[21], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[22], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[23], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[24], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[25], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[26], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[27], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[28], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[29], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[30], core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[31]} ^ 32'd4294967295);
		core_liteethmaccrc32checker_crc_error0 <= (core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next != 32'd3338984827);
	end
	if (core_liteethmaccrc32checker_crc_be[2]) begin
		core_liteethmaccrc32checker_crc_value <= ({core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[0], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[1], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[2], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[3], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[4], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[5], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[6], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[7], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[8], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[9], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[10], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[11], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[12], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[13], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[14], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[15], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[16], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[17], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[18], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[19], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[20], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[21], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[22], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[23], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[24], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[25], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[26], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[27], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[28], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[29], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[30], core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[31]} ^ 32'd4294967295);
		core_liteethmaccrc32checker_crc_error0 <= (core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next != 32'd3338984827);
	end
	if (core_liteethmaccrc32checker_crc_be[3]) begin
		core_liteethmaccrc32checker_crc_value <= ({core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[0], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[1], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[2], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[3], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[4], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[5], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[6], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[7], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[8], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[9], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[10], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[11], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[12], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[13], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[14], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[15], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[16], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[17], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[18], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[19], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[20], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[21], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[22], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[23], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[24], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[25], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[26], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[27], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[28], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[29], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[30], core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[31]} ^ 32'd4294967295);
		core_liteethmaccrc32checker_crc_error0 <= (core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next != 32'd3338984827);
	end
// synthesis translate_off
	dummy_d_23 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_24;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next <= 32'd0;
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[0] <= (((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[1] <= (((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[2] <= (((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[3] <= (((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[4] <= (((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[5] <= (((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[6] <= (((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[7] <= (((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[8] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[0] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[9] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[1] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[10] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[2] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[11] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[3] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[12] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[4] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[13] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[5] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[14] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[6] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[15] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[7] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[16] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[8] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[17] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[9] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[18] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[10] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[19] <= ((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[11] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[20] <= ((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[12] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[21] <= ((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[13] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[22] <= ((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[14] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[23] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[15] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[24] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[16] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[25] <= ((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[17] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[26] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[18] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[7]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[27] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[19] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[6]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[28] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[20] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[5]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[29] <= ((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[4]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[30] <= ((((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[22] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[3]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_next[31] <= ((core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[23] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine0_data[2]);
// synthesis translate_off
	dummy_d_24 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_25;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next <= 32'd0;
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[0] <= (((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[1] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[2] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[3] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[4] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[5] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[6] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[7] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[8] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[9] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[10] <= (((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[11] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[12] <= (((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[13] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[14] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[15] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[16] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[0] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[17] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[1] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[18] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[2] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[19] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[3] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[20] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[4] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[21] <= ((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[5] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[22] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[6] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[23] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[7] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[24] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[8] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[25] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[9] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[26] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[10] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[15]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[27] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[11] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[14]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[28] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[12] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[13]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[29] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[13] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[12]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[30] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[14] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[11]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_next[31] <= ((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[15] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine1_data[10]);
// synthesis translate_off
	dummy_d_25 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_26;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next <= 32'd0;
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[0] <= (((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[1] <= (((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[2] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[3] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[4] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[5] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[6] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[7] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[8] <= (((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[9] <= (((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[10] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[11] <= (((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[12] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[13] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[14] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[15] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[16] <= (((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[17] <= (((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[18] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[19] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[20] <= (((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[21] <= (((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[22] <= (((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[23] <= (((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[24] <= ((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[0] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[25] <= ((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[1] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[26] <= ((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[2] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[23]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[27] <= ((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[3] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[22]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[28] <= ((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[4] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[21]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[29] <= ((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[5] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[20]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[30] <= ((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[6] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[19]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_next[31] <= ((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[7] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine2_data[18]);
// synthesis translate_off
	dummy_d_26 <= dummy_s;
// synthesis translate_on
end

// synthesis translate_off
reg dummy_d_27;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next <= 32'd0;
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[0] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[1] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[2] <= (((((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[3] <= (((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[4] <= (((((((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[5] <= (((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[6] <= (((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[7] <= (((((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[8] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[9] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[10] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[11] <= (((((((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[12] <= (((((((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[13] <= (((((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[14] <= (((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[15] <= (((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[16] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[17] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[18] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[19] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[20] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[21] <= (((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[22] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[23] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[24] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[16] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[25] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[17] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[26] <= (((((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[18] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[31]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[27] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[19] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[30]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[28] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[20] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[12]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[19]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[29]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[29] <= (((((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[21] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[13]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[18]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[28]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[30] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[22] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[26]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[14]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[17]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[10]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[21]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[27]);
	core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next[31] <= (((((((((((((((((((((((((core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[23] ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[28]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[3]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[27]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[4]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[9]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[25]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[6]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[22]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[8]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[24]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[7]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[23]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[5]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[29]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[2]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[15]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[31]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[0]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[16]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[30]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[1]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_prev[11]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[20]) ^ core_liteethmaccrc32checker_crc_liteethmaccrcengine3_data[26]);
// synthesis translate_off
	dummy_d_27 <= dummy_s;
// synthesis translate_on
end
assign core_liteethmaccrc32checker_syncfifo_syncfifo_din = {core_liteethmaccrc32checker_syncfifo_fifo_in_last, core_liteethmaccrc32checker_syncfifo_fifo_in_first, core_liteethmaccrc32checker_syncfifo_fifo_in_payload_error, core_liteethmaccrc32checker_syncfifo_fifo_in_payload_last_be, core_liteethmaccrc32checker_syncfifo_fifo_in_payload_data};
assign {core_liteethmaccrc32checker_syncfifo_fifo_out_last, core_liteethmaccrc32checker_syncfifo_fifo_out_first, core_liteethmaccrc32checker_syncfifo_fifo_out_payload_error, core_liteethmaccrc32checker_syncfifo_fifo_out_payload_last_be, core_liteethmaccrc32checker_syncfifo_fifo_out_payload_data} = core_liteethmaccrc32checker_syncfifo_syncfifo_dout;
assign core_liteethmaccrc32checker_syncfifo_sink_ready = core_liteethmaccrc32checker_syncfifo_syncfifo_writable;
assign core_liteethmaccrc32checker_syncfifo_syncfifo_we = core_liteethmaccrc32checker_syncfifo_sink_valid;
assign core_liteethmaccrc32checker_syncfifo_fifo_in_first = core_liteethmaccrc32checker_syncfifo_sink_first;
assign core_liteethmaccrc32checker_syncfifo_fifo_in_last = core_liteethmaccrc32checker_syncfifo_sink_last;
assign core_liteethmaccrc32checker_syncfifo_fifo_in_payload_data = core_liteethmaccrc32checker_syncfifo_sink_payload_data;
assign core_liteethmaccrc32checker_syncfifo_fifo_in_payload_last_be = core_liteethmaccrc32checker_syncfifo_sink_payload_last_be;
assign core_liteethmaccrc32checker_syncfifo_fifo_in_payload_error = core_liteethmaccrc32checker_syncfifo_sink_payload_error;
assign core_liteethmaccrc32checker_syncfifo_source_valid = core_liteethmaccrc32checker_syncfifo_syncfifo_readable;
assign core_liteethmaccrc32checker_syncfifo_source_first = core_liteethmaccrc32checker_syncfifo_fifo_out_first;
assign core_liteethmaccrc32checker_syncfifo_source_last = core_liteethmaccrc32checker_syncfifo_fifo_out_last;
assign core_liteethmaccrc32checker_syncfifo_source_payload_data = core_liteethmaccrc32checker_syncfifo_fifo_out_payload_data;
assign core_liteethmaccrc32checker_syncfifo_source_payload_last_be = core_liteethmaccrc32checker_syncfifo_fifo_out_payload_last_be;
assign core_liteethmaccrc32checker_syncfifo_source_payload_error = core_liteethmaccrc32checker_syncfifo_fifo_out_payload_error;
assign core_liteethmaccrc32checker_syncfifo_syncfifo_re = core_liteethmaccrc32checker_syncfifo_source_ready;

// synthesis translate_off
reg dummy_d_28;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_syncfifo_wrport_adr <= 1'd0;
	if (core_liteethmaccrc32checker_syncfifo_replace) begin
		core_liteethmaccrc32checker_syncfifo_wrport_adr <= (core_liteethmaccrc32checker_syncfifo_produce - 1'd1);
	end else begin
		core_liteethmaccrc32checker_syncfifo_wrport_adr <= core_liteethmaccrc32checker_syncfifo_produce;
	end
// synthesis translate_off
	dummy_d_28 <= dummy_s;
// synthesis translate_on
end
assign core_liteethmaccrc32checker_syncfifo_wrport_dat_w = core_liteethmaccrc32checker_syncfifo_syncfifo_din;
assign core_liteethmaccrc32checker_syncfifo_wrport_we = (core_liteethmaccrc32checker_syncfifo_syncfifo_we & (core_liteethmaccrc32checker_syncfifo_syncfifo_writable | core_liteethmaccrc32checker_syncfifo_replace));
assign core_liteethmaccrc32checker_syncfifo_do_read = (core_liteethmaccrc32checker_syncfifo_syncfifo_readable & core_liteethmaccrc32checker_syncfifo_syncfifo_re);
assign core_liteethmaccrc32checker_syncfifo_rdport_adr = core_liteethmaccrc32checker_syncfifo_consume;
assign core_liteethmaccrc32checker_syncfifo_syncfifo_dout = core_liteethmaccrc32checker_syncfifo_rdport_dat_r;
assign core_liteethmaccrc32checker_syncfifo_syncfifo_writable = (core_liteethmaccrc32checker_syncfifo_level != 2'd2);
assign core_liteethmaccrc32checker_syncfifo_syncfifo_readable = (core_liteethmaccrc32checker_syncfifo_level != 1'd0);

// synthesis translate_off
reg dummy_d_29;
// synthesis translate_on
always @(*) begin
	core_liteethmaccrc32checker_source_source_valid <= 1'd0;
	core_liteethmaccrc32checker_source_source_last <= 1'd0;
	core_liteethmaccrc32checker_source_source_payload_last_be <= 4'd0;
	core_liteethmaccrc32checker_source_source_payload_error <= 4'd0;
	core_liteethmaccrc32checker_error <= 1'd0;
	core_liteethmaccrc32checker_crc_ce <= 1'd0;
	core_liteethmaccrc32checker_crc_reset <= 1'd0;
	core_liteethmaccrc32checker_syncfifo_source_ready <= 1'd0;
	core_liteethmaccrc32checker_fifo_reset <= 1'd0;
	rxdatapath_bufferizeendpoints_next_state <= 2'd0;
	core_liteethmaccrc32checker_last_be_liteethmac_next_value0 <= 4'd0;
	core_liteethmaccrc32checker_last_be_liteethmac_next_value_ce0 <= 1'd0;
	core_liteethmaccrc32checker_crc_error1_liteethmac_next_value1 <= 1'd0;
	core_liteethmaccrc32checker_crc_error1_liteethmac_next_value_ce1 <= 1'd0;
	core_liteethmaccrc32checker_source_source_payload_error <= core_liteethmaccrc32checker_syncfifo_source_payload_error;
	rxdatapath_bufferizeendpoints_next_state <= rxdatapath_bufferizeendpoints_state;
	case (rxdatapath_bufferizeendpoints_state)
		1'd1: begin
			if ((core_liteethmaccrc32checker_sink_sink_valid & core_liteethmaccrc32checker_sink_sink_ready)) begin
				core_liteethmaccrc32checker_crc_ce <= 1'd1;
				rxdatapath_bufferizeendpoints_next_state <= 2'd2;
			end
		end
		2'd2: begin
			core_liteethmaccrc32checker_syncfifo_source_ready <= core_liteethmaccrc32checker_fifo_out;
			core_liteethmaccrc32checker_source_source_valid <= (core_liteethmaccrc32checker_sink_sink_valid & core_liteethmaccrc32checker_fifo_full);
			if (1'd1) begin
				core_liteethmaccrc32checker_source_source_last <= core_liteethmaccrc32checker_sink_sink_last;
				core_liteethmaccrc32checker_source_source_payload_last_be <= core_liteethmaccrc32checker_sink_sink_payload_last_be;
			end else begin
				if ((core_liteethmaccrc32checker_sink_sink_payload_last_be & 4'd15)) begin
					core_liteethmaccrc32checker_source_source_last <= core_liteethmaccrc32checker_sink_sink_last;
					core_liteethmaccrc32checker_source_source_payload_last_be <= (core_liteethmaccrc32checker_sink_sink_payload_last_be <<< 1'd0);
				end else begin
					core_liteethmaccrc32checker_last_be_liteethmac_next_value0 <= (core_liteethmaccrc32checker_sink_sink_payload_last_be >>> 3'd4);
					core_liteethmaccrc32checker_last_be_liteethmac_next_value_ce0 <= 1'd1;
					core_liteethmaccrc32checker_crc_error1_liteethmac_next_value1 <= core_liteethmaccrc32checker_crc_error0;
					core_liteethmaccrc32checker_crc_error1_liteethmac_next_value_ce1 <= 1'd1;
				end
			end
			core_liteethmaccrc32checker_source_source_payload_error <= (core_liteethmaccrc32checker_sink_sink_payload_error | {4{(core_liteethmaccrc32checker_crc_error0 & core_liteethmaccrc32checker_sink_sink_last)}});
			core_liteethmaccrc32checker_error <= ((core_liteethmaccrc32checker_sink_sink_valid & core_liteethmaccrc32checker_sink_sink_last) & core_liteethmaccrc32checker_crc_error0);
			if ((core_liteethmaccrc32checker_sink_sink_valid & core_liteethmaccrc32checker_sink_sink_ready)) begin
				core_liteethmaccrc32checker_crc_ce <= 1'd1;
				if ((core_liteethmaccrc32checker_sink_sink_last & (core_liteethmaccrc32checker_sink_sink_payload_last_be > 4'd15))) begin
					rxdatapath_bufferizeendpoints_next_state <= 2'd3;
				end else begin
					if (core_liteethmaccrc32checker_sink_sink_last) begin
						rxdatapath_bufferizeendpoints_next_state <= 1'd0;
					end
				end
			end
		end
		2'd3: begin
			core_liteethmaccrc32checker_source_source_valid <= core_liteethmaccrc32checker_syncfifo_source_valid;
			core_liteethmaccrc32checker_syncfifo_source_ready <= core_liteethmaccrc32checker_source_source_ready;
			core_liteethmaccrc32checker_source_source_last <= core_liteethmaccrc32checker_syncfifo_source_last;
			core_liteethmaccrc32checker_source_source_payload_error <= (core_liteethmaccrc32checker_syncfifo_source_payload_error | {4{core_liteethmaccrc32checker_crc_error1}});
			core_liteethmaccrc32checker_source_source_payload_last_be <= core_liteethmaccrc32checker_last_be;
			if ((core_liteethmaccrc32checker_source_source_valid & core_liteethmaccrc32checker_source_source_ready)) begin
				rxdatapath_bufferizeendpoints_next_state <= 1'd0;
			end
		end
		default: begin
			core_liteethmaccrc32checker_crc_reset <= 1'd1;
			core_liteethmaccrc32checker_fifo_reset <= 1'd1;
			rxdatapath_bufferizeendpoints_next_state <= 1'd1;
		end
	endcase
// synthesis translate_off
	dummy_d_29 <= dummy_s;
// synthesis translate_on
end
assign core_bufferizeendpoints_pipe_valid_sink_ready = ((~core_bufferizeendpoints_pipe_valid_source_valid) | core_bufferizeendpoints_pipe_valid_source_ready);
assign core_bufferizeendpoints_pipe_valid_sink_valid = core_bufferizeendpoints_sink_sink_valid;
assign core_bufferizeendpoints_sink_sink_ready = core_bufferizeendpoints_pipe_valid_sink_ready;
assign core_bufferizeendpoints_pipe_valid_sink_first = core_bufferizeendpoints_sink_sink_first;
assign core_bufferizeendpoints_pipe_valid_sink_last = core_bufferizeendpoints_sink_sink_last;
assign core_bufferizeendpoints_pipe_valid_sink_payload_data = core_bufferizeendpoints_sink_sink_payload_data;
assign core_bufferizeendpoints_pipe_valid_sink_payload_last_be = core_bufferizeendpoints_sink_sink_payload_last_be;
assign core_bufferizeendpoints_pipe_valid_sink_payload_error = core_bufferizeendpoints_sink_sink_payload_error;
assign core_bufferizeendpoints_source_source_valid = core_bufferizeendpoints_pipe_valid_source_valid;
assign core_bufferizeendpoints_pipe_valid_source_ready = core_bufferizeendpoints_source_source_ready;
assign core_bufferizeendpoints_source_source_first = core_bufferizeendpoints_pipe_valid_source_first;
assign core_bufferizeendpoints_source_source_last = core_bufferizeendpoints_pipe_valid_source_last;
assign core_bufferizeendpoints_source_source_payload_data = core_bufferizeendpoints_pipe_valid_source_payload_data;
assign core_bufferizeendpoints_source_source_payload_last_be = core_bufferizeendpoints_pipe_valid_source_payload_last_be;
assign core_bufferizeendpoints_source_source_payload_error = core_bufferizeendpoints_pipe_valid_source_payload_error;
assign core_pulsesynchronizer1_o = (core_pulsesynchronizer1_toggle_o ^ core_pulsesynchronizer1_toggle_o_r);
assign core_rx_padding_source_valid = core_rx_padding_sink_valid;
assign core_rx_padding_sink_ready = core_rx_padding_source_ready;
assign core_rx_padding_source_first = core_rx_padding_sink_first;
assign core_rx_padding_source_last = core_rx_padding_sink_last;
assign core_rx_padding_source_payload_data = core_rx_padding_sink_payload_data;
assign core_rx_padding_source_payload_last_be = core_rx_padding_sink_payload_last_be;
assign core_rx_padding_source_payload_error = core_rx_padding_sink_payload_error;
assign core_rx_last_be_sink_valid = source_valid;
assign source_ready = core_rx_last_be_sink_ready;
assign core_rx_last_be_sink_first = source_first;
assign core_rx_last_be_sink_last = source_last;
assign core_rx_last_be_sink_payload_data = source_payload_data;
assign core_rx_last_be_sink_payload_last_be = source_payload_last_be;
assign core_rx_last_be_sink_payload_error = source_payload_error;
assign core_rx_converter_sink_valid = core_rx_last_be_source_valid;
assign core_rx_last_be_source_ready = core_rx_converter_sink_ready;
assign core_rx_converter_sink_first = core_rx_last_be_source_first;
assign core_rx_converter_sink_last = core_rx_last_be_source_last;
assign core_rx_converter_sink_payload_data = core_rx_last_be_source_payload_data;
assign core_rx_converter_sink_payload_last_be = core_rx_last_be_source_payload_last_be;
assign core_rx_converter_sink_payload_error = core_rx_last_be_source_payload_error;
assign core_rx_cdc_sink_sink_valid = core_rx_converter_source_valid;
assign core_rx_converter_source_ready = core_rx_cdc_sink_sink_ready;
assign core_rx_cdc_sink_sink_first = core_rx_converter_source_first;
assign core_rx_cdc_sink_sink_last = core_rx_converter_source_last;
assign core_rx_cdc_sink_sink_payload_data = core_rx_converter_source_payload_data;
assign core_rx_cdc_sink_sink_payload_last_be = core_rx_converter_source_payload_last_be;
assign core_rx_cdc_sink_sink_payload_error = core_rx_converter_source_payload_error;
assign core_rx_preamble_sink_valid = core_rx_cdc_source_source_valid;
assign core_rx_cdc_source_source_ready = core_rx_preamble_sink_ready;
assign core_rx_preamble_sink_first = core_rx_cdc_source_source_first;
assign core_rx_preamble_sink_last = core_rx_cdc_source_source_last;
assign core_rx_preamble_sink_payload_data = core_rx_cdc_source_source_payload_data;
assign core_rx_preamble_sink_payload_last_be = core_rx_cdc_source_source_payload_last_be;
assign core_rx_preamble_sink_payload_error = core_rx_cdc_source_source_payload_error;
assign core_bufferizeendpoints_sink_sink_valid = core_rx_preamble_source_valid;
assign core_rx_preamble_source_ready = core_bufferizeendpoints_sink_sink_ready;
assign core_bufferizeendpoints_sink_sink_first = core_rx_preamble_source_first;
assign core_bufferizeendpoints_sink_sink_last = core_rx_preamble_source_last;
assign core_bufferizeendpoints_sink_sink_payload_data = core_rx_preamble_source_payload_data;
assign core_bufferizeendpoints_sink_sink_payload_last_be = core_rx_preamble_source_payload_last_be;
assign core_bufferizeendpoints_sink_sink_payload_error = core_rx_preamble_source_payload_error;
assign core_rx_padding_sink_valid = core_liteethmaccrc32checker_source_source_valid;
assign core_liteethmaccrc32checker_source_source_ready = core_rx_padding_sink_ready;
assign core_rx_padding_sink_first = core_liteethmaccrc32checker_source_source_first;
assign core_rx_padding_sink_last = core_liteethmaccrc32checker_source_source_last;
assign core_rx_padding_sink_payload_data = core_liteethmaccrc32checker_source_source_payload_data;
assign core_rx_padding_sink_payload_last_be = core_liteethmaccrc32checker_source_source_payload_last_be;
assign core_rx_padding_sink_payload_error = core_liteethmaccrc32checker_source_source_payload_error;
assign core_source_valid = core_rx_padding_source_valid;
assign core_rx_padding_source_ready = core_source_ready;
assign core_source_first = core_rx_padding_source_first;
assign core_source_last = core_rx_padding_source_last;
assign core_source_payload_data = core_rx_padding_source_payload_data;
assign core_source_payload_last_be = core_rx_padding_source_payload_last_be;
assign core_source_payload_error = core_rx_padding_source_payload_error;
assign wishbone_interface_writer_sink_sink_valid = wishbone_interface_sink_valid;
assign wishbone_interface_sink_ready = wishbone_interface_writer_sink_sink_ready;
assign wishbone_interface_writer_sink_sink_first = wishbone_interface_sink_first;
assign wishbone_interface_writer_sink_sink_last = wishbone_interface_sink_last;
assign wishbone_interface_writer_sink_sink_payload_data = wishbone_interface_sink_payload_data;
assign wishbone_interface_writer_sink_sink_payload_last_be = wishbone_interface_sink_payload_last_be;
assign wishbone_interface_writer_sink_sink_payload_error = wishbone_interface_sink_payload_error;
assign wishbone_interface_source_valid = wishbone_interface_reader_source_source_valid;
assign wishbone_interface_reader_source_source_ready = wishbone_interface_source_ready;
assign wishbone_interface_source_first = wishbone_interface_reader_source_source_first;
assign wishbone_interface_source_last = wishbone_interface_reader_source_source_last;
assign wishbone_interface_source_payload_data = wishbone_interface_reader_source_source_payload_data;
assign wishbone_interface_source_payload_last_be = wishbone_interface_reader_source_source_payload_last_be;
assign wishbone_interface_source_payload_error = wishbone_interface_reader_source_source_payload_error;

// synthesis translate_off
reg dummy_d_30;
// synthesis translate_on
always @(*) begin
	wishbone_interface_writer_length_inc <= 4'd0;
	case (wishbone_interface_writer_sink_sink_payload_last_be)
		1'd1: begin
			wishbone_interface_writer_length_inc <= 1'd1;
		end
		2'd2: begin
			wishbone_interface_writer_length_inc <= 2'd2;
		end
		3'd4: begin
			wishbone_interface_writer_length_inc <= 2'd3;
		end
		4'd8: begin
			wishbone_interface_writer_length_inc <= 3'd4;
		end
		5'd16: begin
			wishbone_interface_writer_length_inc <= 3'd5;
		end
		6'd32: begin
			wishbone_interface_writer_length_inc <= 3'd6;
		end
		7'd64: begin
			wishbone_interface_writer_length_inc <= 3'd7;
		end
		default: begin
			wishbone_interface_writer_length_inc <= 3'd4;
		end
	endcase
// synthesis translate_off
	dummy_d_30 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_writer_stat_fifo_source_ready = wishbone_interface_writer_available_clear;
assign wishbone_interface_writer_available_trigger = wishbone_interface_writer_stat_fifo_source_valid;
assign wishbone_interface_writer_slot_status = wishbone_interface_writer_stat_fifo_source_payload_slot;
assign wishbone_interface_writer_length_status = wishbone_interface_writer_stat_fifo_source_payload_length;
assign wishbone_interface_writer_wr_data = wishbone_interface_writer_sink_sink_payload_data;

// synthesis translate_off
reg dummy_d_31;
// synthesis translate_on
always @(*) begin
	wishbone_interface_writer_memory0_adr <= 9'd0;
	wishbone_interface_writer_memory0_we <= 1'd0;
	wishbone_interface_writer_memory0_dat_w <= 32'd0;
	wishbone_interface_writer_memory1_adr <= 9'd0;
	wishbone_interface_writer_memory1_we <= 1'd0;
	wishbone_interface_writer_memory1_dat_w <= 32'd0;
	wishbone_interface_writer_memory2_adr <= 9'd0;
	wishbone_interface_writer_memory2_we <= 1'd0;
	wishbone_interface_writer_memory2_dat_w <= 32'd0;
	wishbone_interface_writer_memory3_adr <= 9'd0;
	wishbone_interface_writer_memory3_we <= 1'd0;
	wishbone_interface_writer_memory3_dat_w <= 32'd0;
	case (wishbone_interface_writer_slot)
		1'd0: begin
			wishbone_interface_writer_memory0_adr <= wishbone_interface_writer_length[10:2];
			wishbone_interface_writer_memory0_dat_w <= wishbone_interface_writer_wr_data;
			if ((wishbone_interface_writer_sink_sink_valid & wishbone_interface_writer_write)) begin
				wishbone_interface_writer_memory0_we <= 1'd1;
			end
		end
		1'd1: begin
			wishbone_interface_writer_memory1_adr <= wishbone_interface_writer_length[10:2];
			wishbone_interface_writer_memory1_dat_w <= wishbone_interface_writer_wr_data;
			if ((wishbone_interface_writer_sink_sink_valid & wishbone_interface_writer_write)) begin
				wishbone_interface_writer_memory1_we <= 1'd1;
			end
		end
		2'd2: begin
			wishbone_interface_writer_memory2_adr <= wishbone_interface_writer_length[10:2];
			wishbone_interface_writer_memory2_dat_w <= wishbone_interface_writer_wr_data;
			if ((wishbone_interface_writer_sink_sink_valid & wishbone_interface_writer_write)) begin
				wishbone_interface_writer_memory2_we <= 1'd1;
			end
		end
		2'd3: begin
			wishbone_interface_writer_memory3_adr <= wishbone_interface_writer_length[10:2];
			wishbone_interface_writer_memory3_dat_w <= wishbone_interface_writer_wr_data;
			if ((wishbone_interface_writer_sink_sink_valid & wishbone_interface_writer_write)) begin
				wishbone_interface_writer_memory3_we <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_31 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_writer_available0 = wishbone_interface_writer_available_status;
assign wishbone_interface_writer_available1 = wishbone_interface_writer_available_pending;

// synthesis translate_off
reg dummy_d_32;
// synthesis translate_on
always @(*) begin
	wishbone_interface_writer_available_clear <= 1'd0;
	if ((wishbone_interface_writer_pending_re & wishbone_interface_writer_pending_r)) begin
		wishbone_interface_writer_available_clear <= 1'd1;
	end
// synthesis translate_off
	dummy_d_32 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_writer_irq = (wishbone_interface_writer_pending_status & wishbone_interface_writer_enable_storage);
assign wishbone_interface_writer_available_status = wishbone_interface_writer_available_trigger;
assign wishbone_interface_writer_available_pending = wishbone_interface_writer_available_trigger;
assign wishbone_interface_writer_stat_fifo_syncfifo_din = {wishbone_interface_writer_stat_fifo_fifo_in_last, wishbone_interface_writer_stat_fifo_fifo_in_first, wishbone_interface_writer_stat_fifo_fifo_in_payload_length, wishbone_interface_writer_stat_fifo_fifo_in_payload_slot};
assign {wishbone_interface_writer_stat_fifo_fifo_out_last, wishbone_interface_writer_stat_fifo_fifo_out_first, wishbone_interface_writer_stat_fifo_fifo_out_payload_length, wishbone_interface_writer_stat_fifo_fifo_out_payload_slot} = wishbone_interface_writer_stat_fifo_syncfifo_dout;
assign wishbone_interface_writer_stat_fifo_sink_ready = wishbone_interface_writer_stat_fifo_syncfifo_writable;
assign wishbone_interface_writer_stat_fifo_syncfifo_we = wishbone_interface_writer_stat_fifo_sink_valid;
assign wishbone_interface_writer_stat_fifo_fifo_in_first = wishbone_interface_writer_stat_fifo_sink_first;
assign wishbone_interface_writer_stat_fifo_fifo_in_last = wishbone_interface_writer_stat_fifo_sink_last;
assign wishbone_interface_writer_stat_fifo_fifo_in_payload_slot = wishbone_interface_writer_stat_fifo_sink_payload_slot;
assign wishbone_interface_writer_stat_fifo_fifo_in_payload_length = wishbone_interface_writer_stat_fifo_sink_payload_length;
assign wishbone_interface_writer_stat_fifo_source_valid = wishbone_interface_writer_stat_fifo_syncfifo_readable;
assign wishbone_interface_writer_stat_fifo_source_first = wishbone_interface_writer_stat_fifo_fifo_out_first;
assign wishbone_interface_writer_stat_fifo_source_last = wishbone_interface_writer_stat_fifo_fifo_out_last;
assign wishbone_interface_writer_stat_fifo_source_payload_slot = wishbone_interface_writer_stat_fifo_fifo_out_payload_slot;
assign wishbone_interface_writer_stat_fifo_source_payload_length = wishbone_interface_writer_stat_fifo_fifo_out_payload_length;
assign wishbone_interface_writer_stat_fifo_syncfifo_re = wishbone_interface_writer_stat_fifo_source_ready;

// synthesis translate_off
reg dummy_d_33;
// synthesis translate_on
always @(*) begin
	wishbone_interface_writer_stat_fifo_wrport_adr <= 2'd0;
	if (wishbone_interface_writer_stat_fifo_replace) begin
		wishbone_interface_writer_stat_fifo_wrport_adr <= (wishbone_interface_writer_stat_fifo_produce - 1'd1);
	end else begin
		wishbone_interface_writer_stat_fifo_wrport_adr <= wishbone_interface_writer_stat_fifo_produce;
	end
// synthesis translate_off
	dummy_d_33 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_writer_stat_fifo_wrport_dat_w = wishbone_interface_writer_stat_fifo_syncfifo_din;
assign wishbone_interface_writer_stat_fifo_wrport_we = (wishbone_interface_writer_stat_fifo_syncfifo_we & (wishbone_interface_writer_stat_fifo_syncfifo_writable | wishbone_interface_writer_stat_fifo_replace));
assign wishbone_interface_writer_stat_fifo_do_read = (wishbone_interface_writer_stat_fifo_syncfifo_readable & wishbone_interface_writer_stat_fifo_syncfifo_re);
assign wishbone_interface_writer_stat_fifo_rdport_adr = wishbone_interface_writer_stat_fifo_consume;
assign wishbone_interface_writer_stat_fifo_syncfifo_dout = wishbone_interface_writer_stat_fifo_rdport_dat_r;
assign wishbone_interface_writer_stat_fifo_syncfifo_writable = (wishbone_interface_writer_stat_fifo_level != 3'd4);
assign wishbone_interface_writer_stat_fifo_syncfifo_readable = (wishbone_interface_writer_stat_fifo_level != 1'd0);

// synthesis translate_off
reg dummy_d_34;
// synthesis translate_on
always @(*) begin
	wishbone_interface_writer_write <= 1'd0;
	wishbone_interface_writer_stat_fifo_sink_valid <= 1'd0;
	wishbone_interface_writer_stat_fifo_sink_payload_slot <= 2'd0;
	wishbone_interface_writer_stat_fifo_sink_payload_length <= 11'd0;
	liteethmacsramwriter_next_state <= 3'd0;
	wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value <= 11'd0;
	wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce <= 1'd0;
	wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value <= 32'd0;
	wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value_ce <= 1'd0;
	wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value <= 2'd0;
	wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value_ce <= 1'd0;
	liteethmacsramwriter_next_state <= liteethmacsramwriter_state;
	case (liteethmacsramwriter_state)
		1'd1: begin
			if ((wishbone_interface_writer_sink_sink_valid & wishbone_interface_writer_sink_sink_last)) begin
				if (((wishbone_interface_writer_sink_sink_payload_error & wishbone_interface_writer_sink_sink_payload_last_be) != 1'd0)) begin
					liteethmacsramwriter_next_state <= 2'd3;
				end else begin
					liteethmacsramwriter_next_state <= 3'd4;
				end
			end
		end
		2'd2: begin
			if ((wishbone_interface_writer_sink_sink_valid & wishbone_interface_writer_sink_sink_last)) begin
				if ((wishbone_interface_writer_sink_sink_payload_last_be != 1'd0)) begin
					liteethmacsramwriter_next_state <= 2'd3;
				end else begin
					wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value <= 1'd0;
					wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce <= 1'd1;
					liteethmacsramwriter_next_state <= 1'd0;
				end
			end
		end
		2'd3: begin
			wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value <= 1'd0;
			wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce <= 1'd1;
			liteethmacsramwriter_next_state <= 1'd0;
		end
		3'd4: begin
			wishbone_interface_writer_stat_fifo_sink_valid <= 1'd1;
			wishbone_interface_writer_stat_fifo_sink_payload_slot <= wishbone_interface_writer_slot;
			wishbone_interface_writer_stat_fifo_sink_payload_length <= wishbone_interface_writer_length;
			wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value <= 1'd0;
			wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce <= 1'd1;
			wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value <= (wishbone_interface_writer_slot + 1'd1);
			wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value_ce <= 1'd1;
			liteethmacsramwriter_next_state <= 1'd0;
		end
		default: begin
			if (wishbone_interface_writer_sink_sink_valid) begin
				if (wishbone_interface_writer_stat_fifo_sink_ready) begin
					wishbone_interface_writer_write <= 1'd1;
					wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value <= (wishbone_interface_writer_length + wishbone_interface_writer_length_inc);
					wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce <= 1'd1;
					if ((wishbone_interface_writer_length >= 11'd1530)) begin
						liteethmacsramwriter_next_state <= 1'd1;
					end
					if (wishbone_interface_writer_sink_sink_last) begin
						if (((wishbone_interface_writer_sink_sink_payload_error & wishbone_interface_writer_sink_sink_payload_last_be) != 1'd0)) begin
							liteethmacsramwriter_next_state <= 2'd3;
						end else begin
							liteethmacsramwriter_next_state <= 3'd4;
						end
					end
				end else begin
					wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value <= (wishbone_interface_writer_errors_status + 1'd1);
					wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value_ce <= 1'd1;
					liteethmacsramwriter_next_state <= 2'd2;
				end
			end
		end
	endcase
// synthesis translate_off
	dummy_d_34 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_reader_cmd_fifo_sink_valid = wishbone_interface_reader_start_re;
assign wishbone_interface_reader_cmd_fifo_sink_payload_slot = wishbone_interface_reader_slot_storage;
assign wishbone_interface_reader_cmd_fifo_sink_payload_length = wishbone_interface_reader_length_storage;
assign wishbone_interface_reader_ready_status = wishbone_interface_reader_cmd_fifo_sink_ready;
assign wishbone_interface_reader_level_status = wishbone_interface_reader_cmd_fifo_level;

// synthesis translate_off
reg dummy_d_35;
// synthesis translate_on
always @(*) begin
	wishbone_interface_reader_source_source_payload_last_be <= 4'd0;
	if (wishbone_interface_reader_source_source_last) begin
		case (wishbone_interface_reader_cmd_fifo_source_payload_length[1:0])
			1'd1: begin
				wishbone_interface_reader_source_source_payload_last_be <= 1'd1;
			end
			2'd2: begin
				wishbone_interface_reader_source_source_payload_last_be <= 2'd2;
			end
			2'd3: begin
				wishbone_interface_reader_source_source_payload_last_be <= 3'd4;
			end
			3'd4: begin
				wishbone_interface_reader_source_source_payload_last_be <= 4'd8;
			end
			3'd5: begin
				wishbone_interface_reader_source_source_payload_last_be <= 5'd16;
			end
			3'd6: begin
				wishbone_interface_reader_source_source_payload_last_be <= 6'd32;
			end
			3'd7: begin
				wishbone_interface_reader_source_source_payload_last_be <= 7'd64;
			end
			default: begin
				wishbone_interface_reader_source_source_payload_last_be <= 4'd8;
			end
		endcase
	end
// synthesis translate_off
	dummy_d_35 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_reader_memory0_re = wishbone_interface_reader_read;
assign wishbone_interface_reader_memory0_adr = wishbone_interface_reader_length[10:2];
assign wishbone_interface_reader_memory1_re = wishbone_interface_reader_read;
assign wishbone_interface_reader_memory1_adr = wishbone_interface_reader_length[10:2];

// synthesis translate_off
reg dummy_d_36;
// synthesis translate_on
always @(*) begin
	wishbone_interface_reader_rd_data <= 32'd0;
	case (wishbone_interface_reader_cmd_fifo_source_payload_slot)
		1'd0: begin
			wishbone_interface_reader_rd_data <= wishbone_interface_reader_memory0_dat_r;
		end
		1'd1: begin
			wishbone_interface_reader_rd_data <= wishbone_interface_reader_memory1_dat_r;
		end
	endcase
// synthesis translate_off
	dummy_d_36 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_reader_source_source_payload_data = wishbone_interface_reader_rd_data;
assign wishbone_interface_reader_event00 = wishbone_interface_reader_eventsourcepulse_status;
assign wishbone_interface_reader_event01 = wishbone_interface_reader_eventsourcepulse_pending;

// synthesis translate_off
reg dummy_d_37;
// synthesis translate_on
always @(*) begin
	wishbone_interface_reader_eventsourcepulse_clear <= 1'd0;
	if ((wishbone_interface_reader_pending_re & wishbone_interface_reader_pending_r)) begin
		wishbone_interface_reader_eventsourcepulse_clear <= 1'd1;
	end
// synthesis translate_off
	dummy_d_37 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_reader_irq = (wishbone_interface_reader_pending_status & wishbone_interface_reader_enable_storage);
assign wishbone_interface_reader_eventsourcepulse_status = 1'd0;
assign wishbone_interface_reader_cmd_fifo_syncfifo_din = {wishbone_interface_reader_cmd_fifo_fifo_in_last, wishbone_interface_reader_cmd_fifo_fifo_in_first, wishbone_interface_reader_cmd_fifo_fifo_in_payload_length, wishbone_interface_reader_cmd_fifo_fifo_in_payload_slot};
assign {wishbone_interface_reader_cmd_fifo_fifo_out_last, wishbone_interface_reader_cmd_fifo_fifo_out_first, wishbone_interface_reader_cmd_fifo_fifo_out_payload_length, wishbone_interface_reader_cmd_fifo_fifo_out_payload_slot} = wishbone_interface_reader_cmd_fifo_syncfifo_dout;
assign wishbone_interface_reader_cmd_fifo_sink_ready = wishbone_interface_reader_cmd_fifo_syncfifo_writable;
assign wishbone_interface_reader_cmd_fifo_syncfifo_we = wishbone_interface_reader_cmd_fifo_sink_valid;
assign wishbone_interface_reader_cmd_fifo_fifo_in_first = wishbone_interface_reader_cmd_fifo_sink_first;
assign wishbone_interface_reader_cmd_fifo_fifo_in_last = wishbone_interface_reader_cmd_fifo_sink_last;
assign wishbone_interface_reader_cmd_fifo_fifo_in_payload_slot = wishbone_interface_reader_cmd_fifo_sink_payload_slot;
assign wishbone_interface_reader_cmd_fifo_fifo_in_payload_length = wishbone_interface_reader_cmd_fifo_sink_payload_length;
assign wishbone_interface_reader_cmd_fifo_source_valid = wishbone_interface_reader_cmd_fifo_syncfifo_readable;
assign wishbone_interface_reader_cmd_fifo_source_first = wishbone_interface_reader_cmd_fifo_fifo_out_first;
assign wishbone_interface_reader_cmd_fifo_source_last = wishbone_interface_reader_cmd_fifo_fifo_out_last;
assign wishbone_interface_reader_cmd_fifo_source_payload_slot = wishbone_interface_reader_cmd_fifo_fifo_out_payload_slot;
assign wishbone_interface_reader_cmd_fifo_source_payload_length = wishbone_interface_reader_cmd_fifo_fifo_out_payload_length;
assign wishbone_interface_reader_cmd_fifo_syncfifo_re = wishbone_interface_reader_cmd_fifo_source_ready;

// synthesis translate_off
reg dummy_d_38;
// synthesis translate_on
always @(*) begin
	wishbone_interface_reader_cmd_fifo_wrport_adr <= 1'd0;
	if (wishbone_interface_reader_cmd_fifo_replace) begin
		wishbone_interface_reader_cmd_fifo_wrport_adr <= (wishbone_interface_reader_cmd_fifo_produce - 1'd1);
	end else begin
		wishbone_interface_reader_cmd_fifo_wrport_adr <= wishbone_interface_reader_cmd_fifo_produce;
	end
// synthesis translate_off
	dummy_d_38 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_reader_cmd_fifo_wrport_dat_w = wishbone_interface_reader_cmd_fifo_syncfifo_din;
assign wishbone_interface_reader_cmd_fifo_wrport_we = (wishbone_interface_reader_cmd_fifo_syncfifo_we & (wishbone_interface_reader_cmd_fifo_syncfifo_writable | wishbone_interface_reader_cmd_fifo_replace));
assign wishbone_interface_reader_cmd_fifo_do_read = (wishbone_interface_reader_cmd_fifo_syncfifo_readable & wishbone_interface_reader_cmd_fifo_syncfifo_re);
assign wishbone_interface_reader_cmd_fifo_rdport_adr = wishbone_interface_reader_cmd_fifo_consume;
assign wishbone_interface_reader_cmd_fifo_syncfifo_dout = wishbone_interface_reader_cmd_fifo_rdport_dat_r;
assign wishbone_interface_reader_cmd_fifo_syncfifo_writable = (wishbone_interface_reader_cmd_fifo_level != 2'd2);
assign wishbone_interface_reader_cmd_fifo_syncfifo_readable = (wishbone_interface_reader_cmd_fifo_level != 1'd0);

// synthesis translate_off
reg dummy_d_39;
// synthesis translate_on
always @(*) begin
	wishbone_interface_reader_source_source_valid <= 1'd0;
	wishbone_interface_reader_source_source_last <= 1'd0;
	wishbone_interface_reader_eventsourcepulse_trigger <= 1'd0;
	wishbone_interface_reader_read <= 1'd0;
	wishbone_interface_reader_cmd_fifo_source_ready <= 1'd0;
	liteethmacsramreader_next_state <= 2'd0;
	wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value <= 11'd0;
	wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value_ce <= 1'd0;
	liteethmacsramreader_next_state <= liteethmacsramreader_state;
	case (liteethmacsramreader_state)
		1'd1: begin
			wishbone_interface_reader_source_source_valid <= 1'd1;
			wishbone_interface_reader_source_source_last <= (wishbone_interface_reader_length >= wishbone_interface_reader_cmd_fifo_source_payload_length);
			if (wishbone_interface_reader_source_source_ready) begin
				wishbone_interface_reader_read <= 1'd1;
				wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value <= (wishbone_interface_reader_length + 3'd4);
				wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value_ce <= 1'd1;
				if (wishbone_interface_reader_source_source_last) begin
					liteethmacsramreader_next_state <= 2'd2;
				end
			end
		end
		2'd2: begin
			wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value <= 1'd0;
			wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value_ce <= 1'd1;
			wishbone_interface_reader_eventsourcepulse_trigger <= 1'd1;
			wishbone_interface_reader_cmd_fifo_source_ready <= 1'd1;
			liteethmacsramreader_next_state <= 1'd0;
		end
		default: begin
			if (wishbone_interface_reader_cmd_fifo_source_valid) begin
				wishbone_interface_reader_read <= 1'd1;
				wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value <= 3'd4;
				wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value_ce <= 1'd1;
				liteethmacsramreader_next_state <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_39 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_ev_irq = (wishbone_interface_writer_irq | wishbone_interface_reader_irq);
assign wishbone_interface_sram0_adr = wishbone_interface_interface0_adr[8:0];
assign wishbone_interface_interface0_dat_r = wishbone_interface_sram0_dat_r;
assign wishbone_interface_sram1_adr = wishbone_interface_interface1_adr[8:0];
assign wishbone_interface_interface1_dat_r = wishbone_interface_sram1_dat_r;
assign wishbone_interface_sram2_adr = wishbone_interface_interface2_adr[8:0];
assign wishbone_interface_interface2_dat_r = wishbone_interface_sram2_dat_r;
assign wishbone_interface_sram3_adr = wishbone_interface_interface3_adr[8:0];
assign wishbone_interface_interface3_dat_r = wishbone_interface_sram3_dat_r;

// synthesis translate_off
reg dummy_d_40;
// synthesis translate_on
always @(*) begin
	wishbone_interface_decoder0_slave_sel <= 4'd0;
	wishbone_interface_decoder0_slave_sel[0] <= (bus_rx_adr[10:9] == 1'd0);
	wishbone_interface_decoder0_slave_sel[1] <= (bus_rx_adr[10:9] == 1'd1);
	wishbone_interface_decoder0_slave_sel[2] <= (bus_rx_adr[10:9] == 2'd2);
	wishbone_interface_decoder0_slave_sel[3] <= (bus_rx_adr[10:9] == 2'd3);
// synthesis translate_off
	dummy_d_40 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_interface0_adr = bus_rx_adr;
assign wishbone_interface_interface0_dat_w = bus_rx_dat_w;
assign wishbone_interface_interface0_sel = bus_rx_sel;
assign wishbone_interface_interface0_stb = bus_rx_stb;
assign wishbone_interface_interface0_we = bus_rx_we;
assign wishbone_interface_interface0_cti = bus_rx_cti;
assign wishbone_interface_interface0_bte = bus_rx_bte;
assign wishbone_interface_interface1_adr = bus_rx_adr;
assign wishbone_interface_interface1_dat_w = bus_rx_dat_w;
assign wishbone_interface_interface1_sel = bus_rx_sel;
assign wishbone_interface_interface1_stb = bus_rx_stb;
assign wishbone_interface_interface1_we = bus_rx_we;
assign wishbone_interface_interface1_cti = bus_rx_cti;
assign wishbone_interface_interface1_bte = bus_rx_bte;
assign wishbone_interface_interface2_adr = bus_rx_adr;
assign wishbone_interface_interface2_dat_w = bus_rx_dat_w;
assign wishbone_interface_interface2_sel = bus_rx_sel;
assign wishbone_interface_interface2_stb = bus_rx_stb;
assign wishbone_interface_interface2_we = bus_rx_we;
assign wishbone_interface_interface2_cti = bus_rx_cti;
assign wishbone_interface_interface2_bte = bus_rx_bte;
assign wishbone_interface_interface3_adr = bus_rx_adr;
assign wishbone_interface_interface3_dat_w = bus_rx_dat_w;
assign wishbone_interface_interface3_sel = bus_rx_sel;
assign wishbone_interface_interface3_stb = bus_rx_stb;
assign wishbone_interface_interface3_we = bus_rx_we;
assign wishbone_interface_interface3_cti = bus_rx_cti;
assign wishbone_interface_interface3_bte = bus_rx_bte;
assign wishbone_interface_interface0_cyc = (bus_rx_cyc & wishbone_interface_decoder0_slave_sel[0]);
assign wishbone_interface_interface1_cyc = (bus_rx_cyc & wishbone_interface_decoder0_slave_sel[1]);
assign wishbone_interface_interface2_cyc = (bus_rx_cyc & wishbone_interface_decoder0_slave_sel[2]);
assign wishbone_interface_interface3_cyc = (bus_rx_cyc & wishbone_interface_decoder0_slave_sel[3]);
assign bus_rx_ack = (((wishbone_interface_interface0_ack | wishbone_interface_interface1_ack) | wishbone_interface_interface2_ack) | wishbone_interface_interface3_ack);
assign bus_rx_err = (((wishbone_interface_interface0_err | wishbone_interface_interface1_err) | wishbone_interface_interface2_err) | wishbone_interface_interface3_err);
assign bus_rx_dat_r = (((({32{wishbone_interface_decoder0_slave_sel_r[0]}} & wishbone_interface_interface0_dat_r) | ({32{wishbone_interface_decoder0_slave_sel_r[1]}} & wishbone_interface_interface1_dat_r)) | ({32{wishbone_interface_decoder0_slave_sel_r[2]}} & wishbone_interface_interface2_dat_r)) | ({32{wishbone_interface_decoder0_slave_sel_r[3]}} & wishbone_interface_interface3_dat_r));

// synthesis translate_off
reg dummy_d_41;
// synthesis translate_on
always @(*) begin
	wishbone_interface_sram4_we <= 4'd0;
	wishbone_interface_sram4_we[0] <= (((wishbone_interface_interface4_cyc & wishbone_interface_interface4_stb) & wishbone_interface_interface4_we) & wishbone_interface_interface4_sel[0]);
	wishbone_interface_sram4_we[1] <= (((wishbone_interface_interface4_cyc & wishbone_interface_interface4_stb) & wishbone_interface_interface4_we) & wishbone_interface_interface4_sel[1]);
	wishbone_interface_sram4_we[2] <= (((wishbone_interface_interface4_cyc & wishbone_interface_interface4_stb) & wishbone_interface_interface4_we) & wishbone_interface_interface4_sel[2]);
	wishbone_interface_sram4_we[3] <= (((wishbone_interface_interface4_cyc & wishbone_interface_interface4_stb) & wishbone_interface_interface4_we) & wishbone_interface_interface4_sel[3]);
// synthesis translate_off
	dummy_d_41 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_sram4_adr = wishbone_interface_interface4_adr[8:0];
assign wishbone_interface_interface4_dat_r = wishbone_interface_sram4_dat_r;
assign wishbone_interface_sram4_dat_w = wishbone_interface_interface4_dat_w;

// synthesis translate_off
reg dummy_d_42;
// synthesis translate_on
always @(*) begin
	wishbone_interface_sram5_we <= 4'd0;
	wishbone_interface_sram5_we[0] <= (((wishbone_interface_interface5_cyc & wishbone_interface_interface5_stb) & wishbone_interface_interface5_we) & wishbone_interface_interface5_sel[0]);
	wishbone_interface_sram5_we[1] <= (((wishbone_interface_interface5_cyc & wishbone_interface_interface5_stb) & wishbone_interface_interface5_we) & wishbone_interface_interface5_sel[1]);
	wishbone_interface_sram5_we[2] <= (((wishbone_interface_interface5_cyc & wishbone_interface_interface5_stb) & wishbone_interface_interface5_we) & wishbone_interface_interface5_sel[2]);
	wishbone_interface_sram5_we[3] <= (((wishbone_interface_interface5_cyc & wishbone_interface_interface5_stb) & wishbone_interface_interface5_we) & wishbone_interface_interface5_sel[3]);
// synthesis translate_off
	dummy_d_42 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_sram5_adr = wishbone_interface_interface5_adr[8:0];
assign wishbone_interface_interface5_dat_r = wishbone_interface_sram5_dat_r;
assign wishbone_interface_sram5_dat_w = wishbone_interface_interface5_dat_w;

// synthesis translate_off
reg dummy_d_43;
// synthesis translate_on
always @(*) begin
	wishbone_interface_decoder1_slave_sel <= 2'd0;
	wishbone_interface_decoder1_slave_sel[0] <= (bus_tx_adr[9] == 1'd0);
	wishbone_interface_decoder1_slave_sel[1] <= (bus_tx_adr[9] == 1'd1);
// synthesis translate_off
	dummy_d_43 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_interface4_adr = bus_tx_adr;
assign wishbone_interface_interface4_dat_w = bus_tx_dat_w;
assign wishbone_interface_interface4_sel = bus_tx_sel;
assign wishbone_interface_interface4_stb = bus_tx_stb;
assign wishbone_interface_interface4_we = bus_tx_we;
assign wishbone_interface_interface4_cti = bus_tx_cti;
assign wishbone_interface_interface4_bte = bus_tx_bte;
assign wishbone_interface_interface5_adr = bus_tx_adr;
assign wishbone_interface_interface5_dat_w = bus_tx_dat_w;
assign wishbone_interface_interface5_sel = bus_tx_sel;
assign wishbone_interface_interface5_stb = bus_tx_stb;
assign wishbone_interface_interface5_we = bus_tx_we;
assign wishbone_interface_interface5_cti = bus_tx_cti;
assign wishbone_interface_interface5_bte = bus_tx_bte;
assign wishbone_interface_interface4_cyc = (bus_tx_cyc & wishbone_interface_decoder1_slave_sel[0]);
assign wishbone_interface_interface5_cyc = (bus_tx_cyc & wishbone_interface_decoder1_slave_sel[1]);
assign bus_tx_ack = (wishbone_interface_interface4_ack | wishbone_interface_interface5_ack);
assign bus_tx_err = (wishbone_interface_interface4_err | wishbone_interface_interface5_err);
assign bus_tx_dat_r = (({32{wishbone_interface_decoder1_slave_sel_r[0]}} & wishbone_interface_interface4_dat_r) | ({32{wishbone_interface_decoder1_slave_sel_r[1]}} & wishbone_interface_interface5_dat_r));
assign sel = (csrbus_adr[15:9] == 1'd0);
assign sram_writer_slot_r = csrbus_dat_w[1:0];

// synthesis translate_off
reg dummy_d_44;
// synthesis translate_on
always @(*) begin
	sram_writer_slot_re <= 1'd0;
	sram_writer_slot_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 1'd0))) begin
		sram_writer_slot_re <= csrbus_we;
		sram_writer_slot_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_44 <= dummy_s;
// synthesis translate_on
end
assign sram_writer_length_r = csrbus_dat_w[10:0];

// synthesis translate_off
reg dummy_d_45;
// synthesis translate_on
always @(*) begin
	sram_writer_length_re <= 1'd0;
	sram_writer_length_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 1'd1))) begin
		sram_writer_length_re <= csrbus_we;
		sram_writer_length_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_45 <= dummy_s;
// synthesis translate_on
end
assign sram_writer_errors_r = csrbus_dat_w[31:0];

// synthesis translate_off
reg dummy_d_46;
// synthesis translate_on
always @(*) begin
	sram_writer_errors_re <= 1'd0;
	sram_writer_errors_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 2'd2))) begin
		sram_writer_errors_re <= csrbus_we;
		sram_writer_errors_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_46 <= dummy_s;
// synthesis translate_on
end
assign sram_writer_ev_status_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_47;
// synthesis translate_on
always @(*) begin
	sram_writer_ev_status_re <= 1'd0;
	sram_writer_ev_status_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 2'd3))) begin
		sram_writer_ev_status_re <= csrbus_we;
		sram_writer_ev_status_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_47 <= dummy_s;
// synthesis translate_on
end
assign sram_writer_ev_pending_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_48;
// synthesis translate_on
always @(*) begin
	sram_writer_ev_pending_re <= 1'd0;
	sram_writer_ev_pending_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 3'd4))) begin
		sram_writer_ev_pending_re <= csrbus_we;
		sram_writer_ev_pending_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_48 <= dummy_s;
// synthesis translate_on
end
assign sram_writer_ev_enable0_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_49;
// synthesis translate_on
always @(*) begin
	sram_writer_ev_enable0_re <= 1'd0;
	sram_writer_ev_enable0_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 3'd5))) begin
		sram_writer_ev_enable0_re <= csrbus_we;
		sram_writer_ev_enable0_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_49 <= dummy_s;
// synthesis translate_on
end
assign wishbone_interface_reader_start_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_50;
// synthesis translate_on
always @(*) begin
	wishbone_interface_reader_start_re <= 1'd0;
	wishbone_interface_reader_start_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 3'd6))) begin
		wishbone_interface_reader_start_re <= csrbus_we;
		wishbone_interface_reader_start_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_50 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_ready_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_51;
// synthesis translate_on
always @(*) begin
	sram_reader_ready_re <= 1'd0;
	sram_reader_ready_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 3'd7))) begin
		sram_reader_ready_re <= csrbus_we;
		sram_reader_ready_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_51 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_level_r = csrbus_dat_w[1:0];

// synthesis translate_off
reg dummy_d_52;
// synthesis translate_on
always @(*) begin
	sram_reader_level_re <= 1'd0;
	sram_reader_level_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd8))) begin
		sram_reader_level_re <= csrbus_we;
		sram_reader_level_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_52 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_slot0_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_53;
// synthesis translate_on
always @(*) begin
	sram_reader_slot0_re <= 1'd0;
	sram_reader_slot0_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd9))) begin
		sram_reader_slot0_re <= csrbus_we;
		sram_reader_slot0_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_53 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_length0_r = csrbus_dat_w[10:0];

// synthesis translate_off
reg dummy_d_54;
// synthesis translate_on
always @(*) begin
	sram_reader_length0_re <= 1'd0;
	sram_reader_length0_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd10))) begin
		sram_reader_length0_re <= csrbus_we;
		sram_reader_length0_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_54 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_ev_status_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_55;
// synthesis translate_on
always @(*) begin
	sram_reader_ev_status_re <= 1'd0;
	sram_reader_ev_status_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd11))) begin
		sram_reader_ev_status_re <= csrbus_we;
		sram_reader_ev_status_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_55 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_ev_pending_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_56;
// synthesis translate_on
always @(*) begin
	sram_reader_ev_pending_re <= 1'd0;
	sram_reader_ev_pending_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd12))) begin
		sram_reader_ev_pending_re <= csrbus_we;
		sram_reader_ev_pending_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_56 <= dummy_s;
// synthesis translate_on
end
assign sram_reader_ev_enable0_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_57;
// synthesis translate_on
always @(*) begin
	sram_reader_ev_enable0_re <= 1'd0;
	sram_reader_ev_enable0_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd13))) begin
		sram_reader_ev_enable0_re <= csrbus_we;
		sram_reader_ev_enable0_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_57 <= dummy_s;
// synthesis translate_on
end
assign preamble_crc_r = csrbus_dat_w[0];

// synthesis translate_off
reg dummy_d_58;
// synthesis translate_on
always @(*) begin
	preamble_crc_re <= 1'd0;
	preamble_crc_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd14))) begin
		preamble_crc_re <= csrbus_we;
		preamble_crc_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_58 <= dummy_s;
// synthesis translate_on
end
assign rx_datapath_preamble_errors_r = csrbus_dat_w[31:0];

// synthesis translate_off
reg dummy_d_59;
// synthesis translate_on
always @(*) begin
	rx_datapath_preamble_errors_re <= 1'd0;
	rx_datapath_preamble_errors_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 4'd15))) begin
		rx_datapath_preamble_errors_re <= csrbus_we;
		rx_datapath_preamble_errors_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_59 <= dummy_s;
// synthesis translate_on
end
assign rx_datapath_crc_errors_r = csrbus_dat_w[31:0];

// synthesis translate_off
reg dummy_d_60;
// synthesis translate_on
always @(*) begin
	rx_datapath_crc_errors_re <= 1'd0;
	rx_datapath_crc_errors_we <= 1'd0;
	if ((sel & (csrbus_adr[8:0] == 5'd16))) begin
		rx_datapath_crc_errors_re <= csrbus_we;
		rx_datapath_crc_errors_we <= csrbus_re;
	end
// synthesis translate_off
	dummy_d_60 <= dummy_s;
// synthesis translate_on
end
assign sram_writer_slot_w = wishbone_interface_writer_slot_status[1:0];
assign wishbone_interface_writer_slot_we = sram_writer_slot_we;
assign sram_writer_length_w = wishbone_interface_writer_length_status[10:0];
assign wishbone_interface_writer_length_we = sram_writer_length_we;
assign sram_writer_errors_w = wishbone_interface_writer_errors_status[31:0];
assign wishbone_interface_writer_errors_we = sram_writer_errors_we;
assign wishbone_interface_writer_status_status = wishbone_interface_writer_available0;
assign sram_writer_ev_status_w = wishbone_interface_writer_status_status;
assign wishbone_interface_writer_status_we = sram_writer_ev_status_we;
assign wishbone_interface_writer_pending_status = wishbone_interface_writer_available1;
assign sram_writer_ev_pending_w = wishbone_interface_writer_pending_status;
assign wishbone_interface_writer_pending_we = sram_writer_ev_pending_we;
assign wishbone_interface_writer_available2 = wishbone_interface_writer_enable_storage;
assign sram_writer_ev_enable0_w = wishbone_interface_writer_enable_storage;
assign sram_reader_ready_w = wishbone_interface_reader_ready_status;
assign wishbone_interface_reader_ready_we = sram_reader_ready_we;
assign sram_reader_level_w = wishbone_interface_reader_level_status[1:0];
assign wishbone_interface_reader_level_we = sram_reader_level_we;
assign sram_reader_slot0_w = wishbone_interface_reader_slot_storage;
assign sram_reader_length0_w = wishbone_interface_reader_length_storage[10:0];
assign wishbone_interface_reader_status_status = wishbone_interface_reader_event00;
assign sram_reader_ev_status_w = wishbone_interface_reader_status_status;
assign wishbone_interface_reader_status_we = sram_reader_ev_status_we;
assign wishbone_interface_reader_pending_status = wishbone_interface_reader_event01;
assign sram_reader_ev_pending_w = wishbone_interface_reader_pending_status;
assign wishbone_interface_reader_pending_we = sram_reader_ev_pending_we;
assign wishbone_interface_reader_event02 = wishbone_interface_reader_enable_storage;
assign sram_reader_ev_enable0_w = wishbone_interface_reader_enable_storage;
assign preamble_crc_w = core_status;
assign core_we = preamble_crc_we;
assign rx_datapath_preamble_errors_w = core_preamble_errors_status[31:0];
assign core_preamble_errors_we = rx_datapath_preamble_errors_we;
assign rx_datapath_crc_errors_w = core_crc_errors_status[31:0];
assign core_crc_errors_we = rx_datapath_crc_errors_we;

// synthesis translate_off
reg dummy_d_61;
// synthesis translate_on
always @(*) begin
	wb_csr_dat_r <= 32'd0;
	wb_csr_ack <= 1'd0;
	next_state <= 2'd0;
	csrbus_dat_w_wishbone2csr_next_value0 <= 32'd0;
	csrbus_dat_w_wishbone2csr_next_value_ce0 <= 1'd0;
	csrbus_adr_wishbone2csr_next_value1 <= 16'd0;
	csrbus_adr_wishbone2csr_next_value_ce1 <= 1'd0;
	csrbus_re_wishbone2csr_next_value2 <= 1'd0;
	csrbus_re_wishbone2csr_next_value_ce2 <= 1'd0;
	csrbus_we_wishbone2csr_next_value3 <= 1'd0;
	csrbus_we_wishbone2csr_next_value_ce3 <= 1'd0;
	next_state <= state;
	case (state)
		1'd1: begin
			csrbus_adr_wishbone2csr_next_value1 <= 1'd0;
			csrbus_adr_wishbone2csr_next_value_ce1 <= 1'd1;
			csrbus_re_wishbone2csr_next_value2 <= 1'd0;
			csrbus_re_wishbone2csr_next_value_ce2 <= 1'd1;
			csrbus_we_wishbone2csr_next_value3 <= 1'd0;
			csrbus_we_wishbone2csr_next_value_ce3 <= 1'd1;
			next_state <= 2'd2;
		end
		2'd2: begin
			wb_csr_ack <= 1'd1;
			wb_csr_dat_r <= csrbus_dat_r;
			next_state <= 1'd0;
		end
		default: begin
			csrbus_dat_w_wishbone2csr_next_value0 <= wb_csr_dat_w;
			csrbus_dat_w_wishbone2csr_next_value_ce0 <= 1'd1;
			if ((wb_csr_cyc & wb_csr_stb)) begin
				csrbus_adr_wishbone2csr_next_value1 <= wb_csr_adr[29:0];
				csrbus_adr_wishbone2csr_next_value_ce1 <= 1'd1;
				csrbus_re_wishbone2csr_next_value2 <= ((~wb_csr_we) & (wb_csr_sel != 1'd0));
				csrbus_re_wishbone2csr_next_value_ce2 <= 1'd1;
				csrbus_we_wishbone2csr_next_value3 <= (wb_csr_we & (wb_csr_sel != 1'd0));
				csrbus_we_wishbone2csr_next_value_ce3 <= 1'd1;
				next_state <= 1'd1;
			end
		end
	endcase
// synthesis translate_off
	dummy_d_61 <= dummy_s;
// synthesis translate_on
end
assign slice_proxy0 = {core_tx_crc_value, core_tx_crc_sink_payload_data[7:0]};
assign slice_proxy1 = {core_tx_crc_value, core_tx_crc_sink_payload_data[15:0]};
assign slice_proxy2 = {core_tx_crc_value, core_tx_crc_sink_payload_data[23:0]};
assign slice_proxy3 = {core_tx_crc_value, core_tx_crc_sink_payload_data[31:0]};
assign core_tx_cdc_cdc_produce_rdomain = multiregimpl01;
assign core_tx_cdc_cdc_consume_wdomain = multiregimpl11;
assign core_rx_cdc_cdc_produce_rdomain = multiregimpl21;
assign core_rx_cdc_cdc_consume_wdomain = multiregimpl31;
assign core_pulsesynchronizer0_toggle_o = multiregimpl41;
assign core_pulsesynchronizer1_toggle_o = multiregimpl51;

always @(posedge eth_rx_clk) begin
	dv_d <= pads_rx_dv;
	source_valid <= pads_rx_dv;
	source_payload_data <= pads_rx_data;
	resetsync0_sr <= {resetsync0_sr[0], (~sys_rst_1)};
	if (core_rx_converter_converter_source_ready) begin
		core_rx_converter_converter_strobe_all <= 1'd0;
	end
	if (core_rx_converter_converter_load_part) begin
		if (((core_rx_converter_converter_demux == 2'd3) | core_rx_converter_converter_sink_last)) begin
			core_rx_converter_converter_demux <= 1'd0;
			core_rx_converter_converter_strobe_all <= 1'd1;
		end else begin
			core_rx_converter_converter_demux <= (core_rx_converter_converter_demux + 1'd1);
		end
	end
	if ((core_rx_converter_converter_source_valid & core_rx_converter_converter_source_ready)) begin
		if ((core_rx_converter_converter_sink_valid & core_rx_converter_converter_sink_ready)) begin
			core_rx_converter_converter_source_first <= core_rx_converter_converter_sink_first;
			core_rx_converter_converter_source_last <= core_rx_converter_converter_sink_last;
		end else begin
			core_rx_converter_converter_source_first <= 1'd0;
			core_rx_converter_converter_source_last <= 1'd0;
		end
	end else begin
		if ((core_rx_converter_converter_sink_valid & core_rx_converter_converter_sink_ready)) begin
			core_rx_converter_converter_source_first <= (core_rx_converter_converter_sink_first | core_rx_converter_converter_source_first);
			core_rx_converter_converter_source_last <= (core_rx_converter_converter_sink_last | core_rx_converter_converter_source_last);
		end
	end
	if (core_rx_converter_converter_load_part) begin
		case (core_rx_converter_converter_demux)
			1'd0: begin
				core_rx_converter_converter_source_payload_data[9:0] <= core_rx_converter_converter_sink_payload_data;
			end
			1'd1: begin
				core_rx_converter_converter_source_payload_data[19:10] <= core_rx_converter_converter_sink_payload_data;
			end
			2'd2: begin
				core_rx_converter_converter_source_payload_data[29:20] <= core_rx_converter_converter_sink_payload_data;
			end
			2'd3: begin
				core_rx_converter_converter_source_payload_data[39:30] <= core_rx_converter_converter_sink_payload_data;
			end
		endcase
	end
	if (core_rx_converter_converter_load_part) begin
		core_rx_converter_converter_source_payload_valid_token_count <= (core_rx_converter_converter_demux + 1'd1);
	end
	core_rx_cdc_cdc_graycounter0_q_binary <= core_rx_cdc_cdc_graycounter0_q_next_binary;
	core_rx_cdc_cdc_graycounter0_q <= core_rx_cdc_cdc_graycounter0_q_next;
	if (eth_rx_rst) begin
		source_valid <= 1'd0;
		source_payload_data <= 8'd0;
		dv_d <= 1'd0;
		core_rx_converter_converter_source_payload_data <= 40'd0;
		core_rx_converter_converter_source_payload_valid_token_count <= 3'd0;
		core_rx_converter_converter_demux <= 2'd0;
		core_rx_converter_converter_strobe_all <= 1'd0;
		core_rx_cdc_cdc_graycounter0_q <= 12'd0;
		core_rx_cdc_cdc_graycounter0_q_binary <= 12'd0;
	end
	multiregimpl30 <= core_rx_cdc_cdc_graycounter1_q;
	multiregimpl31 <= multiregimpl30;
end

always @(posedge eth_tx_clk) begin
	pads_tx_en <= sink_valid;
	pads_tx_data <= sink_payload_data;
	sink_ready <= 1'd1;
	resetsync1_sr <= {resetsync1_sr[0], (~sys_rst_1)};
	core_tx_cdc_cdc_graycounter1_q_binary <= core_tx_cdc_cdc_graycounter1_q_next_binary;
	core_tx_cdc_cdc_graycounter1_q <= core_tx_cdc_cdc_graycounter1_q_next;
	if ((core_tx_converter_converter_source_valid & core_tx_converter_converter_source_ready)) begin
		if (core_tx_converter_converter_last) begin
			core_tx_converter_converter_mux <= 1'd0;
		end else begin
			core_tx_converter_converter_mux <= (core_tx_converter_converter_mux + 1'd1);
		end
	end
	txdatapath_liteethmactxlastbe_state <= txdatapath_liteethmactxlastbe_next_state;
	txdatapath_liteethmacgap_state <= txdatapath_liteethmacgap_next_state;
	if (core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value_ce) begin
		core_tx_gap_counter <= core_tx_gap_counter_liteethmac_clockdomainsrenamer3_next_value;
	end
	if (eth_tx_rst) begin
		sink_ready <= 1'd0;
		core_tx_cdc_cdc_graycounter1_q <= 12'd0;
		core_tx_cdc_cdc_graycounter1_q_binary <= 12'd0;
		core_tx_converter_converter_mux <= 2'd0;
		txdatapath_liteethmactxlastbe_state <= 1'd0;
		txdatapath_liteethmacgap_state <= 1'd0;
	end
	multiregimpl00 <= core_tx_cdc_cdc_graycounter0_q;
	multiregimpl01 <= multiregimpl00;
end

always @(posedge sys_clk) begin
	txdatapath_liteethmacpaddinginserter_state <= txdatapath_liteethmacpaddinginserter_next_state;
	if (core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value_ce) begin
		core_tx_padding_counter <= core_tx_padding_counter_liteethmac_clockdomainsrenamer0_next_value;
	end
	if (core_tx_crc_ce) begin
		core_tx_crc_reg <= core_tx_crc_liteethmaccrcengine3_crc_next;
	end
	if (core_tx_crc_reset) begin
		core_tx_crc_reg <= 32'd4294967295;
	end
	txdatapath_bufferizeendpoints_state <= txdatapath_bufferizeendpoints_next_state;
	if (core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value_ce0) begin
		core_tx_crc_crc_packet <= core_tx_crc_crc_packet_liteethmac_clockdomainsrenamer1_next_value0;
	end
	if (core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value_ce1) begin
		core_tx_crc_last_be <= core_tx_crc_last_be_liteethmac_clockdomainsrenamer1_next_value1;
	end
	if (((~core_tx_crc_pipe_valid_source_valid) | core_tx_crc_pipe_valid_source_ready)) begin
		core_tx_crc_pipe_valid_source_valid <= core_tx_crc_pipe_valid_sink_valid;
		core_tx_crc_pipe_valid_source_first <= core_tx_crc_pipe_valid_sink_first;
		core_tx_crc_pipe_valid_source_last <= core_tx_crc_pipe_valid_sink_last;
		core_tx_crc_pipe_valid_source_payload_data <= core_tx_crc_pipe_valid_sink_payload_data;
		core_tx_crc_pipe_valid_source_payload_last_be <= core_tx_crc_pipe_valid_sink_payload_last_be;
		core_tx_crc_pipe_valid_source_payload_error <= core_tx_crc_pipe_valid_sink_payload_error;
	end
	txdatapath_liteethmacpreambleinserter_state <= txdatapath_liteethmacpreambleinserter_next_state;
	if (core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value_ce) begin
		core_tx_preamble_count <= core_tx_preamble_count_liteethmac_clockdomainsrenamer2_next_value;
	end
	core_tx_cdc_cdc_graycounter0_q_binary <= core_tx_cdc_cdc_graycounter0_q_next_binary;
	core_tx_cdc_cdc_graycounter0_q <= core_tx_cdc_cdc_graycounter0_q_next;
	if (core_pulsesynchronizer0_o) begin
		core_preamble_errors_status <= (core_preamble_errors_status + 1'd1);
	end
	if (core_pulsesynchronizer1_o) begin
		core_crc_errors_status <= (core_crc_errors_status + 1'd1);
	end
	core_rx_cdc_cdc_graycounter1_q_binary <= core_rx_cdc_cdc_graycounter1_q_next_binary;
	core_rx_cdc_cdc_graycounter1_q <= core_rx_cdc_cdc_graycounter1_q_next;
	rxdatapath_liteethmacpreamblechecker_state <= rxdatapath_liteethmacpreamblechecker_next_state;
	if (core_pulsesynchronizer0_i) begin
		core_pulsesynchronizer0_toggle_i <= (~core_pulsesynchronizer0_toggle_i);
	end
	core_pulsesynchronizer0_toggle_o_r <= core_pulsesynchronizer0_toggle_o;
	if (core_liteethmaccrc32checker_crc_ce) begin
		core_liteethmaccrc32checker_crc_reg <= core_liteethmaccrc32checker_crc_liteethmaccrcengine3_crc_next;
	end
	if (core_liteethmaccrc32checker_crc_reset) begin
		core_liteethmaccrc32checker_crc_reg <= 32'd4294967295;
	end
	if (((core_liteethmaccrc32checker_syncfifo_syncfifo_we & core_liteethmaccrc32checker_syncfifo_syncfifo_writable) & (~core_liteethmaccrc32checker_syncfifo_replace))) begin
		core_liteethmaccrc32checker_syncfifo_produce <= (core_liteethmaccrc32checker_syncfifo_produce + 1'd1);
	end
	if (core_liteethmaccrc32checker_syncfifo_do_read) begin
		core_liteethmaccrc32checker_syncfifo_consume <= (core_liteethmaccrc32checker_syncfifo_consume + 1'd1);
	end
	if (((core_liteethmaccrc32checker_syncfifo_syncfifo_we & core_liteethmaccrc32checker_syncfifo_syncfifo_writable) & (~core_liteethmaccrc32checker_syncfifo_replace))) begin
		if ((~core_liteethmaccrc32checker_syncfifo_do_read)) begin
			core_liteethmaccrc32checker_syncfifo_level <= (core_liteethmaccrc32checker_syncfifo_level + 1'd1);
		end
	end else begin
		if (core_liteethmaccrc32checker_syncfifo_do_read) begin
			core_liteethmaccrc32checker_syncfifo_level <= (core_liteethmaccrc32checker_syncfifo_level - 1'd1);
		end
	end
	if (core_liteethmaccrc32checker_fifo_reset) begin
		core_liteethmaccrc32checker_syncfifo_level <= 2'd0;
		core_liteethmaccrc32checker_syncfifo_produce <= 1'd0;
		core_liteethmaccrc32checker_syncfifo_consume <= 1'd0;
	end
	rxdatapath_bufferizeendpoints_state <= rxdatapath_bufferizeendpoints_next_state;
	if (core_liteethmaccrc32checker_last_be_liteethmac_next_value_ce0) begin
		core_liteethmaccrc32checker_last_be <= core_liteethmaccrc32checker_last_be_liteethmac_next_value0;
	end
	if (core_liteethmaccrc32checker_crc_error1_liteethmac_next_value_ce1) begin
		core_liteethmaccrc32checker_crc_error1 <= core_liteethmaccrc32checker_crc_error1_liteethmac_next_value1;
	end
	if (((~core_bufferizeendpoints_pipe_valid_source_valid) | core_bufferizeendpoints_pipe_valid_source_ready)) begin
		core_bufferizeendpoints_pipe_valid_source_valid <= core_bufferizeendpoints_pipe_valid_sink_valid;
		core_bufferizeendpoints_pipe_valid_source_first <= core_bufferizeendpoints_pipe_valid_sink_first;
		core_bufferizeendpoints_pipe_valid_source_last <= core_bufferizeendpoints_pipe_valid_sink_last;
		core_bufferizeendpoints_pipe_valid_source_payload_data <= core_bufferizeendpoints_pipe_valid_sink_payload_data;
		core_bufferizeendpoints_pipe_valid_source_payload_last_be <= core_bufferizeendpoints_pipe_valid_sink_payload_last_be;
		core_bufferizeendpoints_pipe_valid_source_payload_error <= core_bufferizeendpoints_pipe_valid_sink_payload_error;
	end
	if (core_pulsesynchronizer1_i) begin
		core_pulsesynchronizer1_toggle_i <= (~core_pulsesynchronizer1_toggle_i);
	end
	core_pulsesynchronizer1_toggle_o_r <= core_pulsesynchronizer1_toggle_o;
	if (((wishbone_interface_writer_stat_fifo_syncfifo_we & wishbone_interface_writer_stat_fifo_syncfifo_writable) & (~wishbone_interface_writer_stat_fifo_replace))) begin
		wishbone_interface_writer_stat_fifo_produce <= (wishbone_interface_writer_stat_fifo_produce + 1'd1);
	end
	if (wishbone_interface_writer_stat_fifo_do_read) begin
		wishbone_interface_writer_stat_fifo_consume <= (wishbone_interface_writer_stat_fifo_consume + 1'd1);
	end
	if (((wishbone_interface_writer_stat_fifo_syncfifo_we & wishbone_interface_writer_stat_fifo_syncfifo_writable) & (~wishbone_interface_writer_stat_fifo_replace))) begin
		if ((~wishbone_interface_writer_stat_fifo_do_read)) begin
			wishbone_interface_writer_stat_fifo_level <= (wishbone_interface_writer_stat_fifo_level + 1'd1);
		end
	end else begin
		if (wishbone_interface_writer_stat_fifo_do_read) begin
			wishbone_interface_writer_stat_fifo_level <= (wishbone_interface_writer_stat_fifo_level - 1'd1);
		end
	end
	liteethmacsramwriter_state <= liteethmacsramwriter_next_state;
	if (wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value_ce) begin
		wishbone_interface_writer_length <= wishbone_interface_writer_length_liteethmac_liteethmacsramwriter_t_next_value;
	end
	if (wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value_ce) begin
		wishbone_interface_writer_errors_status <= wishbone_interface_writer_errors_status_liteethmac_liteethmacsramwriter_f_next_value;
	end
	if (wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value_ce) begin
		wishbone_interface_writer_slot <= wishbone_interface_writer_slot_liteethmac_liteethmacsramwriter_next_value;
	end
	if (wishbone_interface_reader_eventsourcepulse_clear) begin
		wishbone_interface_reader_eventsourcepulse_pending <= 1'd0;
	end
	if (wishbone_interface_reader_eventsourcepulse_trigger) begin
		wishbone_interface_reader_eventsourcepulse_pending <= 1'd1;
	end
	if (((wishbone_interface_reader_cmd_fifo_syncfifo_we & wishbone_interface_reader_cmd_fifo_syncfifo_writable) & (~wishbone_interface_reader_cmd_fifo_replace))) begin
		wishbone_interface_reader_cmd_fifo_produce <= (wishbone_interface_reader_cmd_fifo_produce + 1'd1);
	end
	if (wishbone_interface_reader_cmd_fifo_do_read) begin
		wishbone_interface_reader_cmd_fifo_consume <= (wishbone_interface_reader_cmd_fifo_consume + 1'd1);
	end
	if (((wishbone_interface_reader_cmd_fifo_syncfifo_we & wishbone_interface_reader_cmd_fifo_syncfifo_writable) & (~wishbone_interface_reader_cmd_fifo_replace))) begin
		if ((~wishbone_interface_reader_cmd_fifo_do_read)) begin
			wishbone_interface_reader_cmd_fifo_level <= (wishbone_interface_reader_cmd_fifo_level + 1'd1);
		end
	end else begin
		if (wishbone_interface_reader_cmd_fifo_do_read) begin
			wishbone_interface_reader_cmd_fifo_level <= (wishbone_interface_reader_cmd_fifo_level - 1'd1);
		end
	end
	liteethmacsramreader_state <= liteethmacsramreader_next_state;
	if (wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value_ce) begin
		wishbone_interface_reader_length <= wishbone_interface_reader_length_liteethmac_liteethmacsramreader_next_value;
	end
	wishbone_interface_interface0_ack <= 1'd0;
	if (((wishbone_interface_interface0_cyc & wishbone_interface_interface0_stb) & ((~wishbone_interface_interface0_ack) | wishbone_interface_sram0_adr_burst))) begin
		wishbone_interface_interface0_ack <= 1'd1;
	end
	wishbone_interface_interface1_ack <= 1'd0;
	if (((wishbone_interface_interface1_cyc & wishbone_interface_interface1_stb) & ((~wishbone_interface_interface1_ack) | wishbone_interface_sram1_adr_burst))) begin
		wishbone_interface_interface1_ack <= 1'd1;
	end
	wishbone_interface_interface2_ack <= 1'd0;
	if (((wishbone_interface_interface2_cyc & wishbone_interface_interface2_stb) & ((~wishbone_interface_interface2_ack) | wishbone_interface_sram2_adr_burst))) begin
		wishbone_interface_interface2_ack <= 1'd1;
	end
	wishbone_interface_interface3_ack <= 1'd0;
	if (((wishbone_interface_interface3_cyc & wishbone_interface_interface3_stb) & ((~wishbone_interface_interface3_ack) | wishbone_interface_sram3_adr_burst))) begin
		wishbone_interface_interface3_ack <= 1'd1;
	end
	wishbone_interface_decoder0_slave_sel_r <= wishbone_interface_decoder0_slave_sel;
	wishbone_interface_interface4_ack <= 1'd0;
	if (((wishbone_interface_interface4_cyc & wishbone_interface_interface4_stb) & ((~wishbone_interface_interface4_ack) | wishbone_interface_sram4_adr_burst))) begin
		wishbone_interface_interface4_ack <= 1'd1;
	end
	wishbone_interface_interface5_ack <= 1'd0;
	if (((wishbone_interface_interface5_cyc & wishbone_interface_interface5_stb) & ((~wishbone_interface_interface5_ack) | wishbone_interface_sram5_adr_burst))) begin
		wishbone_interface_interface5_ack <= 1'd1;
	end
	wishbone_interface_decoder1_slave_sel_r <= wishbone_interface_decoder1_slave_sel;
	csrbus_dat_r <= 1'd0;
	if (sel) begin
		case (csrbus_adr[8:0])
			1'd0: begin
				csrbus_dat_r <= sram_writer_slot_w;
			end
			1'd1: begin
				csrbus_dat_r <= sram_writer_length_w;
			end
			2'd2: begin
				csrbus_dat_r <= sram_writer_errors_w;
			end
			2'd3: begin
				csrbus_dat_r <= sram_writer_ev_status_w;
			end
			3'd4: begin
				csrbus_dat_r <= sram_writer_ev_pending_w;
			end
			3'd5: begin
				csrbus_dat_r <= sram_writer_ev_enable0_w;
			end
			3'd6: begin
				csrbus_dat_r <= wishbone_interface_reader_start_w;
			end
			3'd7: begin
				csrbus_dat_r <= sram_reader_ready_w;
			end
			4'd8: begin
				csrbus_dat_r <= sram_reader_level_w;
			end
			4'd9: begin
				csrbus_dat_r <= sram_reader_slot0_w;
			end
			4'd10: begin
				csrbus_dat_r <= sram_reader_length0_w;
			end
			4'd11: begin
				csrbus_dat_r <= sram_reader_ev_status_w;
			end
			4'd12: begin
				csrbus_dat_r <= sram_reader_ev_pending_w;
			end
			4'd13: begin
				csrbus_dat_r <= sram_reader_ev_enable0_w;
			end
			4'd14: begin
				csrbus_dat_r <= preamble_crc_w;
			end
			4'd15: begin
				csrbus_dat_r <= rx_datapath_preamble_errors_w;
			end
			5'd16: begin
				csrbus_dat_r <= rx_datapath_crc_errors_w;
			end
		endcase
	end
	wishbone_interface_writer_slot_re <= sram_writer_slot_re;
	wishbone_interface_writer_length_re <= sram_writer_length_re;
	wishbone_interface_writer_errors_re <= sram_writer_errors_re;
	wishbone_interface_writer_status_re <= sram_writer_ev_status_re;
	if (sram_writer_ev_pending_re) begin
		wishbone_interface_writer_pending_r <= sram_writer_ev_pending_r;
	end
	wishbone_interface_writer_pending_re <= sram_writer_ev_pending_re;
	if (sram_writer_ev_enable0_re) begin
		wishbone_interface_writer_enable_storage <= sram_writer_ev_enable0_r;
	end
	wishbone_interface_writer_enable_re <= sram_writer_ev_enable0_re;
	wishbone_interface_reader_ready_re <= sram_reader_ready_re;
	wishbone_interface_reader_level_re <= sram_reader_level_re;
	if (sram_reader_slot0_re) begin
		wishbone_interface_reader_slot_storage <= sram_reader_slot0_r;
	end
	wishbone_interface_reader_slot_re <= sram_reader_slot0_re;
	if (sram_reader_length0_re) begin
		wishbone_interface_reader_length_storage[10:0] <= sram_reader_length0_r;
	end
	wishbone_interface_reader_length_re <= sram_reader_length0_re;
	wishbone_interface_reader_status_re <= sram_reader_ev_status_re;
	if (sram_reader_ev_pending_re) begin
		wishbone_interface_reader_pending_r <= sram_reader_ev_pending_r;
	end
	wishbone_interface_reader_pending_re <= sram_reader_ev_pending_re;
	if (sram_reader_ev_enable0_re) begin
		wishbone_interface_reader_enable_storage <= sram_reader_ev_enable0_r;
	end
	wishbone_interface_reader_enable_re <= sram_reader_ev_enable0_re;
	core_re <= preamble_crc_re;
	core_preamble_errors_re <= rx_datapath_preamble_errors_re;
	core_crc_errors_re <= rx_datapath_crc_errors_re;
	state <= next_state;
	if (csrbus_dat_w_wishbone2csr_next_value_ce0) begin
		csrbus_dat_w <= csrbus_dat_w_wishbone2csr_next_value0;
	end
	if (csrbus_adr_wishbone2csr_next_value_ce1) begin
		csrbus_adr <= csrbus_adr_wishbone2csr_next_value1;
	end
	if (csrbus_re_wishbone2csr_next_value_ce2) begin
		csrbus_re <= csrbus_re_wishbone2csr_next_value2;
	end
	if (csrbus_we_wishbone2csr_next_value_ce3) begin
		csrbus_we <= csrbus_we_wishbone2csr_next_value3;
	end
	if (sys_rst) begin
		core_re <= 1'd0;
		core_tx_padding_counter <= 16'd0;
		core_tx_crc_reg <= 32'd4294967295;
		core_tx_crc_pipe_valid_source_valid <= 1'd0;
		core_tx_crc_pipe_valid_source_payload_data <= 32'd0;
		core_tx_crc_pipe_valid_source_payload_last_be <= 4'd0;
		core_tx_crc_pipe_valid_source_payload_error <= 4'd0;
		core_tx_cdc_cdc_graycounter0_q <= 12'd0;
		core_tx_cdc_cdc_graycounter0_q_binary <= 12'd0;
		core_preamble_errors_status <= 32'd0;
		core_preamble_errors_re <= 1'd0;
		core_crc_errors_status <= 32'd0;
		core_crc_errors_re <= 1'd0;
		core_rx_cdc_cdc_graycounter1_q <= 12'd0;
		core_rx_cdc_cdc_graycounter1_q_binary <= 12'd0;
		core_liteethmaccrc32checker_crc_reg <= 32'd4294967295;
		core_liteethmaccrc32checker_syncfifo_level <= 2'd0;
		core_liteethmaccrc32checker_syncfifo_produce <= 1'd0;
		core_liteethmaccrc32checker_syncfifo_consume <= 1'd0;
		core_liteethmaccrc32checker_last_be <= 4'd0;
		core_liteethmaccrc32checker_crc_error1 <= 1'd0;
		core_bufferizeendpoints_pipe_valid_source_valid <= 1'd0;
		core_bufferizeendpoints_pipe_valid_source_payload_data <= 32'd0;
		core_bufferizeendpoints_pipe_valid_source_payload_last_be <= 4'd0;
		core_bufferizeendpoints_pipe_valid_source_payload_error <= 4'd0;
		wishbone_interface_writer_slot_re <= 1'd0;
		wishbone_interface_writer_length_re <= 1'd0;
		wishbone_interface_writer_errors_status <= 32'd0;
		wishbone_interface_writer_errors_re <= 1'd0;
		wishbone_interface_writer_status_re <= 1'd0;
		wishbone_interface_writer_pending_re <= 1'd0;
		wishbone_interface_writer_pending_r <= 1'd0;
		wishbone_interface_writer_enable_storage <= 1'd0;
		wishbone_interface_writer_enable_re <= 1'd0;
		wishbone_interface_writer_slot <= 2'd0;
		wishbone_interface_writer_length <= 11'd0;
		wishbone_interface_writer_stat_fifo_level <= 3'd0;
		wishbone_interface_writer_stat_fifo_produce <= 2'd0;
		wishbone_interface_writer_stat_fifo_consume <= 2'd0;
		wishbone_interface_reader_ready_re <= 1'd0;
		wishbone_interface_reader_level_re <= 1'd0;
		wishbone_interface_reader_slot_re <= 1'd0;
		wishbone_interface_reader_length_re <= 1'd0;
		wishbone_interface_reader_eventsourcepulse_pending <= 1'd0;
		wishbone_interface_reader_status_re <= 1'd0;
		wishbone_interface_reader_pending_re <= 1'd0;
		wishbone_interface_reader_pending_r <= 1'd0;
		wishbone_interface_reader_enable_storage <= 1'd0;
		wishbone_interface_reader_enable_re <= 1'd0;
		wishbone_interface_reader_length <= 11'd0;
		wishbone_interface_reader_cmd_fifo_level <= 2'd0;
		wishbone_interface_reader_cmd_fifo_produce <= 1'd0;
		wishbone_interface_reader_cmd_fifo_consume <= 1'd0;
		wishbone_interface_interface0_ack <= 1'd0;
		wishbone_interface_interface1_ack <= 1'd0;
		wishbone_interface_interface2_ack <= 1'd0;
		wishbone_interface_interface3_ack <= 1'd0;
		wishbone_interface_decoder0_slave_sel_r <= 4'd0;
		wishbone_interface_interface4_ack <= 1'd0;
		wishbone_interface_interface5_ack <= 1'd0;
		wishbone_interface_decoder1_slave_sel_r <= 2'd0;
		csrbus_re <= 1'd0;
		csrbus_we <= 1'd0;
		txdatapath_liteethmacpaddinginserter_state <= 1'd0;
		txdatapath_bufferizeendpoints_state <= 2'd0;
		txdatapath_liteethmacpreambleinserter_state <= 2'd0;
		rxdatapath_liteethmacpreamblechecker_state <= 1'd0;
		rxdatapath_bufferizeendpoints_state <= 2'd0;
		liteethmacsramwriter_state <= 3'd0;
		liteethmacsramreader_state <= 2'd0;
		state <= 2'd0;
	end
	multiregimpl10 <= core_tx_cdc_cdc_graycounter1_q;
	multiregimpl11 <= multiregimpl10;
	multiregimpl20 <= core_rx_cdc_cdc_graycounter0_q;
	multiregimpl21 <= multiregimpl20;
	multiregimpl40 <= core_pulsesynchronizer0_toggle_i;
	multiregimpl41 <= multiregimpl40;
	multiregimpl50 <= core_pulsesynchronizer1_toggle_i;
	multiregimpl51 <= multiregimpl50;
end

reg [41:0] storage[0:2047];
reg [10:0] memadr;
reg [10:0] memadr_1;
always @(posedge sys_clk) begin
	if (core_tx_cdc_cdc_wrport_we)
		storage[core_tx_cdc_cdc_wrport_adr] <= core_tx_cdc_cdc_wrport_dat_w;
	memadr <= core_tx_cdc_cdc_wrport_adr;
end

always @(posedge eth_tx_clk) begin
	memadr_1 <= core_tx_cdc_cdc_rdport_adr;
end

assign core_tx_cdc_cdc_wrport_dat_r = storage[memadr];
assign core_tx_cdc_cdc_rdport_dat_r = storage[memadr_1];

reg [41:0] storage_1[0:2047];
reg [10:0] memadr_2;
reg [10:0] memadr_3;
always @(posedge eth_rx_clk) begin
	if (core_rx_cdc_cdc_wrport_we)
		storage_1[core_rx_cdc_cdc_wrport_adr] <= core_rx_cdc_cdc_wrport_dat_w;
	memadr_2 <= core_rx_cdc_cdc_wrport_adr;
end

always @(posedge sys_clk) begin
	memadr_3 <= core_rx_cdc_cdc_rdport_adr;
end

assign core_rx_cdc_cdc_wrport_dat_r = storage_1[memadr_2];
assign core_rx_cdc_cdc_rdport_dat_r = storage_1[memadr_3];

reg [41:0] storage_2[0:1];
reg [41:0] memdat;
always @(posedge sys_clk) begin
	if (core_liteethmaccrc32checker_syncfifo_wrport_we)
		storage_2[core_liteethmaccrc32checker_syncfifo_wrport_adr] <= core_liteethmaccrc32checker_syncfifo_wrport_dat_w;
	memdat <= storage_2[core_liteethmaccrc32checker_syncfifo_wrport_adr];
end

always @(posedge sys_clk) begin
end

assign core_liteethmaccrc32checker_syncfifo_wrport_dat_r = memdat;
assign core_liteethmaccrc32checker_syncfifo_rdport_dat_r = storage_2[core_liteethmaccrc32checker_syncfifo_rdport_adr];

reg [14:0] storage_3[0:3];
reg [14:0] memdat_1;
always @(posedge sys_clk) begin
	if (wishbone_interface_writer_stat_fifo_wrport_we)
		storage_3[wishbone_interface_writer_stat_fifo_wrport_adr] <= wishbone_interface_writer_stat_fifo_wrport_dat_w;
	memdat_1 <= storage_3[wishbone_interface_writer_stat_fifo_wrport_adr];
end

always @(posedge sys_clk) begin
end

assign wishbone_interface_writer_stat_fifo_wrport_dat_r = memdat_1;
assign wishbone_interface_writer_stat_fifo_rdport_dat_r = storage_3[wishbone_interface_writer_stat_fifo_rdport_adr];

reg [31:0] mem[0:382];
reg [8:0] memadr_4;
reg [31:0] memdat_2;
always @(posedge sys_clk) begin
	if (wishbone_interface_writer_memory0_we)
		mem[wishbone_interface_writer_memory0_adr] <= wishbone_interface_writer_memory0_dat_w;
	memadr_4 <= wishbone_interface_writer_memory0_adr;
end

always @(posedge sys_clk) begin
	memdat_2 <= mem[wishbone_interface_sram0_adr];
end

assign wishbone_interface_writer_memory0_dat_r = mem[memadr_4];
assign wishbone_interface_sram0_dat_r = memdat_2;

reg [31:0] mem_1[0:382];
reg [8:0] memadr_5;
reg [31:0] memdat_3;
always @(posedge sys_clk) begin
	if (wishbone_interface_writer_memory1_we)
		mem_1[wishbone_interface_writer_memory1_adr] <= wishbone_interface_writer_memory1_dat_w;
	memadr_5 <= wishbone_interface_writer_memory1_adr;
end

always @(posedge sys_clk) begin
	memdat_3 <= mem_1[wishbone_interface_sram1_adr];
end

assign wishbone_interface_writer_memory1_dat_r = mem_1[memadr_5];
assign wishbone_interface_sram1_dat_r = memdat_3;

reg [31:0] mem_2[0:382];
reg [8:0] memadr_6;
reg [31:0] memdat_4;
always @(posedge sys_clk) begin
	if (wishbone_interface_writer_memory2_we)
		mem_2[wishbone_interface_writer_memory2_adr] <= wishbone_interface_writer_memory2_dat_w;
	memadr_6 <= wishbone_interface_writer_memory2_adr;
end

always @(posedge sys_clk) begin
	memdat_4 <= mem_2[wishbone_interface_sram2_adr];
end

assign wishbone_interface_writer_memory2_dat_r = mem_2[memadr_6];
assign wishbone_interface_sram2_dat_r = memdat_4;

reg [31:0] mem_3[0:382];
reg [8:0] memadr_7;
reg [31:0] memdat_5;
always @(posedge sys_clk) begin
	if (wishbone_interface_writer_memory3_we)
		mem_3[wishbone_interface_writer_memory3_adr] <= wishbone_interface_writer_memory3_dat_w;
	memadr_7 <= wishbone_interface_writer_memory3_adr;
end

always @(posedge sys_clk) begin
	memdat_5 <= mem_3[wishbone_interface_sram3_adr];
end

assign wishbone_interface_writer_memory3_dat_r = mem_3[memadr_7];
assign wishbone_interface_sram3_dat_r = memdat_5;

reg [13:0] storage_4[0:1];
reg [13:0] memdat_6;
always @(posedge sys_clk) begin
	if (wishbone_interface_reader_cmd_fifo_wrport_we)
		storage_4[wishbone_interface_reader_cmd_fifo_wrport_adr] <= wishbone_interface_reader_cmd_fifo_wrport_dat_w;
	memdat_6 <= storage_4[wishbone_interface_reader_cmd_fifo_wrport_adr];
end

always @(posedge sys_clk) begin
end

assign wishbone_interface_reader_cmd_fifo_wrport_dat_r = memdat_6;
assign wishbone_interface_reader_cmd_fifo_rdport_dat_r = storage_4[wishbone_interface_reader_cmd_fifo_rdport_adr];

reg [31:0] mem_4[0:382];
reg [31:0] memdat_7;
reg [8:0] memadr_8;
always @(posedge sys_clk) begin
	if (wishbone_interface_reader_memory0_re)
		memdat_7 <= mem_4[wishbone_interface_reader_memory0_adr];
end

always @(posedge sys_clk) begin
	if (wishbone_interface_sram4_we[0])
		mem_4[wishbone_interface_sram4_adr][7:0] <= wishbone_interface_sram4_dat_w[7:0];
	if (wishbone_interface_sram4_we[1])
		mem_4[wishbone_interface_sram4_adr][15:8] <= wishbone_interface_sram4_dat_w[15:8];
	if (wishbone_interface_sram4_we[2])
		mem_4[wishbone_interface_sram4_adr][23:16] <= wishbone_interface_sram4_dat_w[23:16];
	if (wishbone_interface_sram4_we[3])
		mem_4[wishbone_interface_sram4_adr][31:24] <= wishbone_interface_sram4_dat_w[31:24];
	memadr_8 <= wishbone_interface_sram4_adr;
end

assign wishbone_interface_reader_memory0_dat_r = memdat_7;
assign wishbone_interface_sram4_dat_r = mem_4[memadr_8];

reg [31:0] mem_5[0:382];
reg [31:0] memdat_8;
reg [8:0] memadr_9;
always @(posedge sys_clk) begin
	if (wishbone_interface_reader_memory1_re)
		memdat_8 <= mem_5[wishbone_interface_reader_memory1_adr];
end

always @(posedge sys_clk) begin
	if (wishbone_interface_sram5_we[0])
		mem_5[wishbone_interface_sram5_adr][7:0] <= wishbone_interface_sram5_dat_w[7:0];
	if (wishbone_interface_sram5_we[1])
		mem_5[wishbone_interface_sram5_adr][15:8] <= wishbone_interface_sram5_dat_w[15:8];
	if (wishbone_interface_sram5_we[2])
		mem_5[wishbone_interface_sram5_adr][23:16] <= wishbone_interface_sram5_dat_w[23:16];
	if (wishbone_interface_sram5_we[3])
		mem_5[wishbone_interface_sram5_adr][31:24] <= wishbone_interface_sram5_dat_w[31:24];
	memadr_9 <= wishbone_interface_sram5_adr;
end

assign wishbone_interface_reader_memory1_dat_r = memdat_8;
assign wishbone_interface_sram5_dat_r = mem_5[memadr_9];

endmodule
