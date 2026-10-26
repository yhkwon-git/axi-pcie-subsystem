`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// pcie_to_axi_bridge
//
// Basic PCIe Memory Read / Memory Write TLP to AXI4 converter.
//
// The PCIe MAC is not in this module. A neighbor presents one TLP DWORD per
// beat on pclk (sop on the first DWORD, eop on the last). 3DW and 4DW headers
// with 32-bit addresses are accepted. A 4DW header whose upper address is not
// zero is dropped: this bridge's AXI master is 32-bit. Type is Memory only.
//
//   MWr  fmt/type 010_00000 (3DW) or 011_00000 (4DW), then `length` data DWORDs
//   MRd  fmt/type 000_00000 (3DW) or 001_00000 (4DW), no data
//
// The whole request is pushed, header beat then payload beats, into one
// asynchronous FIFO so the AXI clock cannot observe the header before the
// payload that belongs to it. AXI4 INCR bursts use a 4-byte size. length==1
// is a single beat (the AXI4-Lite shape). One transaction is outstanding.
// Memory writes are posted. Memory reads become a 3DW CplD on pclk after the
// AXI read data has been buffered, so the completion status is known before
// the header is handed to the PCIe clock.
//
// Byte enables follow the TLP: first DW uses First BE, last DW uses Last BE,
// middle DWs are 4'hF. p_rst_n and a_rst_n follow the FIFO reset rule.
// -----------------------------------------------------------------------------

module pcie_to_axi_bridge #(
  parameter int          ADDR_WIDTH   = 32,
  parameter int          MAX_DW       = 16,
  parameter int          REQ_DEPTH    = 32,
  parameter int          CPL_DEPTH    = 32,
  parameter logic [15:0] COMPLETER_ID = 16'h0100
) (
  input  wire                        pclk,
  input  wire                        p_rst_n,
  input  wire                        aclk,
  input  wire                        a_rst_n,

  input  wire                        tlp_valid,
  output wire                        tlp_ready,
  input  wire                        tlp_sop,
  input  wire                        tlp_eop,
  input  wire [31:0]                 tlp_data,
  output wire                        tlp_error,

  output wire                        cpl_valid,
  input  wire                        cpl_ready,
  output wire                        cpl_sop,
  output wire                        cpl_eop,
  output wire [31:0]                 cpl_data,

  output wire [3:0]                  m_axi_awid,
  output wire [ADDR_WIDTH-1:0]       m_axi_awaddr,
  output wire [7:0]                  m_axi_awlen,
  output wire [2:0]                  m_axi_awsize,
  output wire [1:0]                  m_axi_awburst,
  output wire                        m_axi_awlock,
  output wire [3:0]                  m_axi_awcache,
  output wire [2:0]                  m_axi_awprot,
  output wire                        m_axi_awvalid,
  input  wire                        m_axi_awready,

  output wire [31:0]                 m_axi_wdata,
  output wire [3:0]                  m_axi_wstrb,
  output wire                        m_axi_wlast,
  output wire                        m_axi_wvalid,
  input  wire                        m_axi_wready,

  input  wire [3:0]                  m_axi_bid,
  input  wire [1:0]                  m_axi_bresp,
  input  wire                        m_axi_bvalid,
  output wire                        m_axi_bready,

  output wire [3:0]                  m_axi_arid,
  output wire [ADDR_WIDTH-1:0]       m_axi_araddr,
  output wire [7:0]                  m_axi_arlen,
  output wire [2:0]                  m_axi_arsize,
  output wire [1:0]                  m_axi_arburst,
  output wire                        m_axi_arlock,
  output wire [3:0]                  m_axi_arcache,
  output wire [2:0]                  m_axi_arprot,
  output wire                        m_axi_arvalid,
  input  wire                        m_axi_arready,

  input  wire [3:0]                  m_axi_rid,
  input  wire [31:0]                 m_axi_rdata,
  input  wire [1:0]                  m_axi_rresp,
  input  wire                        m_axi_rlast,
  input  wire                        m_axi_rvalid,
  output wire                        m_axi_rready
);

  localparam int BEAT_W = 76;
  localparam int CPL_W  = 34;

  // Request beat, MSB first in the concatenation below:
  //   hdr, write, word[31:0], len[9:0], lbe, fbe, req_id, tag
  localparam int BP_TAG_L = 0;
  localparam int BP_TAG_H = 7;
  localparam int BP_REQ_L = 8;
  localparam int BP_REQ_H = 23;
  localparam int BP_FBE_L = 24;
  localparam int BP_FBE_H = 27;
  localparam int BP_LBE_L = 28;
  localparam int BP_LBE_H = 31;
  localparam int BP_LEN_L = 32;
  localparam int BP_LEN_H = 41;
  localparam int BP_DAT_L = 42;
  localparam int BP_DAT_H = 73;
  localparam int BP_WRITE = 74;
  localparam int BP_HDR   = 75;

  localparam logic [2:0] IN_IDLE = 3'd0;
  localparam logic [2:0] IN_DW1  = 3'd1;
  localparam logic [2:0] IN_DW2  = 3'd2;
  localparam logic [2:0] IN_DW3  = 3'd3;
  localparam logic [2:0] IN_PAY  = 3'd4;
  localparam logic [2:0] IN_DROP = 3'd5;

  localparam logic [3:0] AX_IDLE = 4'd0;
  localparam logic [3:0] AX_AW   = 4'd1;
  localparam logic [3:0] AX_W    = 4'd2;
  localparam logic [3:0] AX_B    = 4'd3;
  localparam logic [3:0] AX_AR   = 4'd4;
  localparam logic [3:0] AX_R    = 4'd5;
  localparam logic [3:0] AX_CH0  = 4'd6;
  localparam logic [3:0] AX_CH1  = 4'd7;
  localparam logic [3:0] AX_CH2  = 4'd8;
  localparam logic [3:0] AX_OUT  = 4'd9;

  localparam logic [2:0] SC = 3'b000;
  localparam logic [2:0] CA = 3'b100;
  localparam int IDX_W = (MAX_DW <= 2) ? 1 : $clog2(MAX_DW);

  generate
    if (ADDR_WIDTH != 32) begin : g_addr
      initial $error("pcie_to_axi_bridge: ADDR_WIDTH must be 32 in this basic bridge");
    end
    if ((MAX_DW < 1) || (MAX_DW > 256)) begin : g_len
      initial $error("pcie_to_axi_bridge: MAX_DW must be in 1..256");
    end
  endgenerate

  function automatic logic [1:0] low_off(input logic [3:0] be);
    if (be[0]) return 2'd0;
    else if (be[1]) return 2'd1;
    else if (be[2]) return 2'd2;
    else return 2'd3;
  endfunction

  function automatic logic [1:0] high_drop(input logic [3:0] be);
    if (be[3]) return 2'd0;
    else if (be[2]) return 2'd1;
    else if (be[1]) return 2'd2;
    else return 2'd3;
  endfunction

  function automatic logic [11:0] payload_bytes(
    input logic [9:0] len,
    input logic [3:0] fbe,
    input logic [3:0] lbe
  );
    logic [2:0] ones;
    begin
      ones = {2'b0, fbe[0]} + {2'b0, fbe[1]} + {2'b0, fbe[2]} + {2'b0, fbe[3]};
      if (len <= 10'd1) begin
        payload_bytes = {9'd0, ones};
      end else begin
        payload_bytes = {len, 2'b00} - {10'd0, low_off(fbe)} - {10'd0, high_drop(lbe)};
      end
    end
  endfunction

  logic [2:0]  in_state;
  logic        in_write;
  logic        in_4dw;
  logic [9:0]  in_len;
  logic [9:0]  in_left;
  logic [15:0] in_req;
  logic [7:0]  in_tag;
  logic [3:0]  in_fbe;
  logic [3:0]  in_lbe;
  logic        tlp_error_q;

  wire         req_full;
  wire         req_wr_en;
  wire [BEAT_W-1:0] req_wr_data;
  wire         req_empty;
  wire         req_rd_en;
  wire [BEAT_W-1:0] req_rd_data;

  wire         tlp_fire;
  wire         push_hdr;
  wire         push_data;

  assign tlp_ready = (in_state == IN_DROP) || ~req_full;
  assign tlp_fire  = tlp_valid & tlp_ready;
  assign push_hdr  = tlp_fire & (((in_state == IN_DW2) & ~in_4dw) | (in_state == IN_DW3));
  assign push_data = tlp_fire & (in_state == IN_PAY);
  assign req_wr_en = push_hdr | push_data;
  assign req_wr_data = push_data
    ? {1'b0, 1'b0, tlp_data, 10'd0, 4'd0, 4'd0, 16'd0, 8'd0}
    : {1'b1, in_write, tlp_data, in_len, in_lbe, in_fbe, in_req, in_tag};
  assign tlp_error = tlp_error_q;

  always_ff @(posedge pclk or negedge p_rst_n) begin
    if (!p_rst_n) begin
      in_state    <= IN_IDLE;
      in_write    <= 1'b0;
      in_4dw      <= 1'b0;
      in_len      <= '0;
      in_left     <= '0;
      in_req      <= '0;
      in_tag      <= '0;
      in_fbe      <= '0;
      in_lbe      <= '0;
      tlp_error_q <= 1'b0;
    end else begin
      tlp_error_q <= 1'b0;
      if (tlp_fire) begin
        case (in_state)
          IN_IDLE: begin
            if (!tlp_sop || (tlp_data[28:24] != 5'b00000) || (tlp_data[9:0] == 10'd0) ||
                (tlp_data[9:0] > 10'(MAX_DW))) begin
              tlp_error_q <= 1'b1;
              in_state    <= (!tlp_sop || tlp_eop) ? IN_IDLE : IN_DROP;
            end else begin
              in_write <= tlp_data[30];
              in_4dw   <= tlp_data[29];
              in_len   <= tlp_data[9:0];
              in_state <= IN_DW1;
            end
          end
          IN_DW1: begin
            in_req   <= tlp_data[31:16];
            in_tag   <= tlp_data[15:8];
            in_lbe   <= tlp_data[7:4];
            in_fbe   <= tlp_data[3:0];
            in_state <= IN_DW2;
          end
          IN_DW2: begin
            if (in_4dw) begin
              if (tlp_data != 32'd0) begin
                tlp_error_q <= 1'b1;
                in_state    <= tlp_eop ? IN_IDLE : IN_DROP;
              end else begin
                in_state <= IN_DW3;
              end
            end else if (in_write) begin
              in_left  <= in_len;
              in_state <= IN_PAY;
            end else begin
              in_state <= IN_IDLE;
            end
          end
          IN_DW3: begin
            if (in_write) begin
              in_left  <= in_len;
              in_state <= IN_PAY;
            end else begin
              in_state <= IN_IDLE;
            end
          end
          IN_PAY: begin
            if (in_left == 10'd1) begin
              in_state <= IN_IDLE;
            end else begin
              in_left <= in_left - 10'd1;
            end
          end
          IN_DROP: begin
            if (tlp_eop) begin
              in_state <= IN_IDLE;
            end
          end
          default: begin
            in_state <= IN_IDLE;
          end
        endcase
      end
    end
  end

  cdc_async_fifo #(.WIDTH(BEAT_W), .DEPTH(REQ_DEPTH)) u_req (
    .wr_clk   (pclk),
    .wr_rst_n (p_rst_n),
    .wr_en    (req_wr_en),
    .wr_data  (req_wr_data),
    .wr_full  (req_full),
    .rd_clk   (aclk),
    .rd_rst_n (a_rst_n),
    .rd_en    (req_rd_en),
    .rd_data  (req_rd_data),
    .rd_empty (req_empty)
  );

  logic [3:0]        ax_state;
  logic              ax_write;
  logic [31:0]       ax_addr;
  logic [9:0]        ax_len;
  logic [3:0]        ax_fbe;
  logic [3:0]        ax_lbe;
  logic [15:0]       ax_req;
  logic [7:0]        ax_tag;
  logic [9:0]        ax_beat;
  logic [2:0]        ax_status;
  logic [11:0]       ax_bytes;
  logic [6:0]        ax_lower;
  logic [31:0]       rbuf [0:MAX_DW-1];

  wire               cpl_full;
  wire               cpl_wr_en;
  wire [CPL_W-1:0]   cpl_wr_data;
  wire               cpl_empty;
  wire               cpl_rd_en;
  wire [CPL_W-1:0]   cpl_rd_data;

  wire               beat_hdr;
  wire               beat_write;
  wire [31:0]        beat_word;
  wire [9:0]         beat_len;
  wire [3:0]         beat_lbe;
  wire [3:0]         beat_fbe;
  wire [15:0]        beat_req;
  wire [7:0]         beat_tag;
  wire               take_hdr;
  wire               take_w;
  wire               w_last;
  wire [3:0]         wstrb_now;
  wire [31:0]        cpl_dw0;
  wire [31:0]        cpl_dw1;
  wire [31:0]        cpl_dw2;

  assign beat_hdr   = req_rd_data[BP_HDR];
  assign beat_write = req_rd_data[BP_WRITE];
  assign beat_word  = req_rd_data[BP_DAT_H:BP_DAT_L];
  assign beat_len   = req_rd_data[BP_LEN_H:BP_LEN_L];
  assign beat_lbe   = req_rd_data[BP_LBE_H:BP_LBE_L];
  assign beat_fbe   = req_rd_data[BP_FBE_H:BP_FBE_L];
  assign beat_req   = req_rd_data[BP_REQ_H:BP_REQ_L];
  assign beat_tag   = req_rd_data[BP_TAG_H:BP_TAG_L];

  assign take_hdr = (ax_state == AX_IDLE) && !req_empty && beat_hdr;
  assign w_last   = (ax_beat == (ax_len - 10'd1));
  assign wstrb_now = (ax_len == 10'd1) ? ax_fbe :
                     (ax_beat == 10'd0) ? ax_fbe :
                     w_last ? ax_lbe : 4'hF;
  assign m_axi_wvalid = (ax_state == AX_W) && !req_empty && !beat_hdr;
  assign take_w       = m_axi_wvalid && m_axi_wready;
  assign req_rd_en    = take_hdr || take_w;

  assign m_axi_awid    = ax_tag[3:0];
  assign m_axi_awaddr  = {ax_addr[31:2], 2'b00};
  assign m_axi_awlen   = ax_len[7:0] - 8'd1;
  assign m_axi_awsize  = 3'b010;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awcache = 4'b0000;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awvalid = (ax_state == AX_AW);

  assign m_axi_wdata = beat_word;
  assign m_axi_wstrb = wstrb_now;
  assign m_axi_wlast = w_last;

  assign m_axi_bready = (ax_state == AX_B);

  assign m_axi_arid    = ax_tag[3:0];
  assign m_axi_araddr  = {ax_addr[31:2], 2'b00};
  assign m_axi_arlen   = ax_len[7:0] - 8'd1;
  assign m_axi_arsize  = 3'b010;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = 4'b0000;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arvalid = (ax_state == AX_AR);
  assign m_axi_rready  = (ax_state == AX_R);

  assign cpl_dw0 = {3'b010, 5'b01010, 14'd0, ax_len};
  assign cpl_dw1 = {COMPLETER_ID, ax_status, 1'b0, ax_bytes};
  assign cpl_dw2 = {ax_req, ax_tag, 1'b0, ax_lower};

  assign cpl_wr_en = ((ax_state == AX_CH0) || (ax_state == AX_CH1) ||
                      (ax_state == AX_CH2) || (ax_state == AX_OUT)) && !cpl_full;
  assign cpl_wr_data =
    (ax_state == AX_CH0) ? {1'b0, 1'b1, cpl_dw0} :
    (ax_state == AX_CH1) ? {1'b0, 1'b0, cpl_dw1} :
    (ax_state == AX_CH2) ? {1'b0, 1'b0, cpl_dw2} :
    {w_last, 1'b0, rbuf[ax_beat[IDX_W-1:0]]};

  always_ff @(posedge aclk or negedge a_rst_n) begin
    if (!a_rst_n) begin
      ax_state  <= AX_IDLE;
      ax_write  <= 1'b0;
      ax_addr   <= '0;
      ax_len    <= 10'd1;
      ax_fbe    <= 4'hF;
      ax_lbe    <= 4'h0;
      ax_req    <= '0;
      ax_tag    <= '0;
      ax_beat   <= '0;
      ax_status <= SC;
      ax_bytes  <= '0;
      ax_lower  <= '0;
    end else begin
      case (ax_state)
        AX_IDLE: begin
          if (take_hdr) begin
            ax_write  <= beat_write;
            ax_addr   <= beat_word;
            ax_len    <= beat_len;
            ax_fbe    <= beat_fbe;
            ax_lbe    <= beat_lbe;
            ax_req    <= beat_req;
            ax_tag    <= beat_tag;
            ax_beat   <= '0;
            ax_status <= SC;
            ax_bytes  <= payload_bytes(beat_len, beat_fbe, beat_lbe);
            ax_lower  <= {beat_word[6:2], low_off(beat_fbe)};
            ax_state  <= beat_write ? AX_AW : AX_AR;
          end
        end
        AX_AW: begin
          if (m_axi_awvalid && m_axi_awready) begin
            ax_state <= AX_W;
          end
        end
        AX_W: begin
          if (take_w) begin
            if (w_last) begin
              ax_state <= AX_B;
            end else begin
              ax_beat <= ax_beat + 10'd1;
            end
          end
        end
        AX_B: begin
          if (m_axi_bvalid && m_axi_bready) begin
            ax_state <= AX_IDLE;
          end
        end
        AX_AR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            ax_beat  <= '0;
            ax_state <= AX_R;
          end
        end
        AX_R: begin
          if (m_axi_rvalid && m_axi_rready) begin
            rbuf[ax_beat[IDX_W-1:0]] <= m_axi_rdata;
            if (m_axi_rresp != 2'b00) begin
              ax_status <= CA;
            end
            if (w_last) begin
              ax_beat  <= '0;
              ax_state <= AX_CH0;
            end else begin
              ax_beat <= ax_beat + 10'd1;
            end
          end
        end
        AX_CH0: begin
          if (!cpl_full) begin
            ax_state <= AX_CH1;
          end
        end
        AX_CH1: begin
          if (!cpl_full) begin
            ax_state <= AX_CH2;
          end
        end
        AX_CH2: begin
          if (!cpl_full) begin
            ax_beat  <= '0;
            ax_state <= AX_OUT;
          end
        end
        AX_OUT: begin
          if (!cpl_full) begin
            if (w_last) begin
              ax_state <= AX_IDLE;
            end else begin
              ax_beat <= ax_beat + 10'd1;
            end
          end
        end
        default: begin
          ax_state <= AX_IDLE;
        end
      endcase
    end
  end

  cdc_async_fifo #(.WIDTH(CPL_W), .DEPTH(CPL_DEPTH)) u_cpl (
    .wr_clk   (aclk),
    .wr_rst_n (a_rst_n),
    .wr_en    (cpl_wr_en),
    .wr_data  (cpl_wr_data),
    .wr_full  (cpl_full),
    .rd_clk   (pclk),
    .rd_rst_n (p_rst_n),
    .rd_en    (cpl_rd_en),
    .rd_data  (cpl_rd_data),
    .rd_empty (cpl_empty)
  );

  assign cpl_valid = ~cpl_empty;
  assign cpl_rd_en = cpl_valid & cpl_ready;
  assign cpl_data  = cpl_rd_data[31:0];
  assign cpl_sop   = cpl_rd_data[32];
  assign cpl_eop   = cpl_rd_data[33];

  wire _unused_resp = &{1'b0, m_axi_bid, m_axi_bresp, m_axi_rid, m_axi_rlast, ax_write};
  wire _unused_lint = _unused_resp;

endmodule : pcie_to_axi_bridge

`default_nettype wire
