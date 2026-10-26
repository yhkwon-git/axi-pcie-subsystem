`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_register_slice
//
// AXI4-Lite full register slice for the control-plane hop of the multi-layer
// interconnect and the PCIe protocol bridge.
//
// Each of the five AXI channels (AW, W, B, AR, R) is an independent 2-deep
// skid pipeline:
//   * output register cuts the forward (VALID/payload) timing path
//   * skid register absorbs the beat that arrives while the output is stalled
//   * S-side READY is the registered complement of skid occupancy, so the
//     reverse (READY) path does not combinationally depend on M-side READY
//
// Cycle behavior when both sides are ready: one beat per cycle, one cycle of
// latency. A downstream stall is absorbed by the skid slot, and the upstream
// stall lasts the same number of cycles. Payload bytes are forwarded as-is.
// This module does not decode addresses, modify responses, or track
// outstanding transactions.
//
// Reset follows the AXI convention: aresetn is asynchronously asserted and
// must be synchronously deasserted by the SoC reset controller.
//
// Leaf cell axi_channel_reg_slice is the timing-isolation primitive the AXI4
// data-plane slice can reuse later (ID/LEN/SIZE/BURST/CACHE/QOS added to the
// payload only).
// -----------------------------------------------------------------------------

module axi_channel_reg_slice #(
  parameter int WIDTH = 32
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  input  wire                    s_valid,
  output wire                    s_ready,
  input  wire [WIDTH-1:0]        s_data,

  output wire                    m_valid,
  input  wire                    m_ready,
  output wire [WIDTH-1:0]        m_data
);

  generate
    if (WIDTH < 1) begin : g_illegal_width
      initial $error("axi_channel_reg_slice: WIDTH must be >= 1");
    end
  endgenerate

  logic             m_valid_q;
  logic [WIDTH-1:0] m_data_q;
  logic             skid_valid_q;
  logic [WIDTH-1:0] skid_data_q;

  wire              m_load_en;
  wire              skid_load_en;
  wire              skid_clear;
  wire [WIDTH-1:0]  m_data_next;

  // Reverse-path register. READY falls only after the skid slot is occupied,
  // and it does not combinationally depend on m_ready.
  assign s_ready = ~skid_valid_q;

  // Output register can take a new beat when it is empty or the current beat
  // is accepted downstream in this cycle.
  assign m_load_en    = ~m_valid_q | m_ready;
  assign skid_load_en = s_valid & s_ready & ~m_load_en;
  assign skid_clear   = skid_valid_q & m_load_en;

  // Skid occupancy implies the output register is full, so a stored skid beat
  // is the older one and must advance first.
  assign m_data_next = skid_valid_q ? skid_data_q : s_data;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      m_valid_q    <= 1'b0;
      skid_valid_q <= 1'b0;
    end else begin
      if (m_load_en) begin
        m_valid_q <= skid_valid_q | (s_valid & s_ready);
        if (skid_valid_q | (s_valid & s_ready)) begin
          m_data_q <= m_data_next;
        end
      end

      if (skid_load_en) begin
        skid_valid_q <= 1'b1;
        skid_data_q  <= s_data;
      end else if (skid_clear) begin
        skid_valid_q <= 1'b0;
      end
    end
  end

  assign m_valid = m_valid_q;
  assign m_data  = m_data_q;

`ifndef SYNTHESIS
  // Protocol monitors. VALID and payload must stay put until READY, on both
  // the incoming beat and the beat this slice itself presents downstream.
  logic             s_valid_d;
  logic             s_ready_d;
  logic [WIDTH-1:0] s_data_d;
  logic             m_valid_d;
  logic             m_ready_d;
  logic [WIDTH-1:0] m_data_d;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      s_valid_d <= 1'b0;
      s_ready_d <= 1'b0;
      m_valid_d <= 1'b0;
      m_ready_d <= 1'b0;
    end else begin
      if (s_valid_d && !s_ready_d) begin
        if (!s_valid) begin
          $error("%m: upstream VALID dropped before READY");
        end
        if (s_data !== s_data_d) begin
          $error("%m: upstream payload changed before handshake");
        end
      end
      if (m_valid_d && !m_ready_d) begin
        if (!m_valid) begin
          $error("%m: slice dropped VALID before READY");
        end
        if (m_data !== m_data_d) begin
          $error("%m: slice payload changed before handshake");
        end
      end
      s_valid_d <= s_valid;
      s_ready_d <= s_ready;
      s_data_d  <= s_data;
      m_valid_d <= m_valid;
      m_ready_d <= m_ready;
      m_data_d  <= m_data;
    end
  end
`endif

endmodule : axi_channel_reg_slice


module axi_register_slice #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input  wire                        aclk,
  input  wire                        aresetn,

  // Slave interface. Connect to the upstream AXI master.
  input  wire [ADDR_WIDTH-1:0]       s_axi_awaddr,
  input  wire [2:0]                  s_axi_awprot,
  input  wire                        s_axi_awvalid,
  output wire                        s_axi_awready,

  input  wire [DATA_WIDTH-1:0]       s_axi_wdata,
  input  wire [(DATA_WIDTH/8)-1:0]   s_axi_wstrb,
  input  wire                        s_axi_wvalid,
  output wire                        s_axi_wready,

  output wire [1:0]                  s_axi_bresp,
  output wire                        s_axi_bvalid,
  input  wire                        s_axi_bready,

  input  wire [ADDR_WIDTH-1:0]       s_axi_araddr,
  input  wire [2:0]                  s_axi_arprot,
  input  wire                        s_axi_arvalid,
  output wire                        s_axi_arready,

  output wire [DATA_WIDTH-1:0]       s_axi_rdata,
  output wire [1:0]                  s_axi_rresp,
  output wire                        s_axi_rvalid,
  input  wire                        s_axi_rready,

  // Master interface. Connect to the downstream AXI slave.
  output wire [ADDR_WIDTH-1:0]       m_axi_awaddr,
  output wire [2:0]                  m_axi_awprot,
  output wire                        m_axi_awvalid,
  input  wire                        m_axi_awready,

  output wire [DATA_WIDTH-1:0]       m_axi_wdata,
  output wire [(DATA_WIDTH/8)-1:0]   m_axi_wstrb,
  output wire                        m_axi_wvalid,
  input  wire                        m_axi_wready,

  input  wire [1:0]                  m_axi_bresp,
  input  wire                        m_axi_bvalid,
  output wire                        m_axi_bready,

  output wire [ADDR_WIDTH-1:0]       m_axi_araddr,
  output wire [2:0]                  m_axi_arprot,
  output wire                        m_axi_arvalid,
  input  wire                        m_axi_arready,

  input  wire [DATA_WIDTH-1:0]       m_axi_rdata,
  input  wire [1:0]                  m_axi_rresp,
  input  wire                        m_axi_rvalid,
  output wire                        m_axi_rready
);

  generate
    if ((DATA_WIDTH != 32) && (DATA_WIDTH != 64)) begin : g_illegal_data_width
      initial $error("axi_register_slice: AXI4-Lite DATA_WIDTH must be 32 or 64");
    end
    if ((ADDR_WIDTH < 1) || (ADDR_WIDTH > 64)) begin : g_illegal_addr_width
      initial $error("axi_register_slice: ADDR_WIDTH must be in 1..64");
    end
  endgenerate

  localparam int STRB_WIDTH = DATA_WIDTH / 8;
  localparam int AW_PAY_W   = ADDR_WIDTH + 3;
  localparam int W_PAY_W    = DATA_WIDTH + STRB_WIDTH;
  localparam int B_PAY_W    = 2;
  localparam int AR_PAY_W   = ADDR_WIDTH + 3;
  localparam int R_PAY_W    = DATA_WIDTH + 2;

  wire [AW_PAY_W-1:0] aw_s_payload;
  wire [AW_PAY_W-1:0] aw_m_payload;
  wire [W_PAY_W-1:0]  w_s_payload;
  wire [W_PAY_W-1:0]  w_m_payload;
  wire [AR_PAY_W-1:0] ar_s_payload;
  wire [AR_PAY_W-1:0] ar_m_payload;
  wire [R_PAY_W-1:0]  r_s_payload;
  wire [R_PAY_W-1:0]  r_m_payload;

  assign aw_s_payload = {s_axi_awaddr, s_axi_awprot};
  assign {m_axi_awaddr, m_axi_awprot} = aw_m_payload;

  assign w_s_payload = {s_axi_wdata, s_axi_wstrb};
  assign {m_axi_wdata, m_axi_wstrb} = w_m_payload;

  assign ar_s_payload = {s_axi_araddr, s_axi_arprot};
  assign {m_axi_araddr, m_axi_arprot} = ar_m_payload;

  // B and R flow from the downstream slave back to the upstream master, so
  // the channel's S side is the master-port input and its M side is the
  // slave-port output.
  assign r_s_payload = {m_axi_rdata, m_axi_rresp};
  assign {s_axi_rdata, s_axi_rresp} = r_m_payload;

  axi_channel_reg_slice #(.WIDTH(AW_PAY_W)) u_aw (
    .aclk    (aclk),
    .aresetn (aresetn),
    .s_valid (s_axi_awvalid),
    .s_ready (s_axi_awready),
    .s_data  (aw_s_payload),
    .m_valid (m_axi_awvalid),
    .m_ready (m_axi_awready),
    .m_data  (aw_m_payload)
  );

  axi_channel_reg_slice #(.WIDTH(W_PAY_W)) u_w (
    .aclk    (aclk),
    .aresetn (aresetn),
    .s_valid (s_axi_wvalid),
    .s_ready (s_axi_wready),
    .s_data  (w_s_payload),
    .m_valid (m_axi_wvalid),
    .m_ready (m_axi_wready),
    .m_data  (w_m_payload)
  );

  axi_channel_reg_slice #(.WIDTH(B_PAY_W)) u_b (
    .aclk    (aclk),
    .aresetn (aresetn),
    .s_valid (m_axi_bvalid),
    .s_ready (m_axi_bready),
    .s_data  (m_axi_bresp),
    .m_valid (s_axi_bvalid),
    .m_ready (s_axi_bready),
    .m_data  (s_axi_bresp)
  );

  axi_channel_reg_slice #(.WIDTH(AR_PAY_W)) u_ar (
    .aclk    (aclk),
    .aresetn (aresetn),
    .s_valid (s_axi_arvalid),
    .s_ready (s_axi_arready),
    .s_data  (ar_s_payload),
    .m_valid (m_axi_arvalid),
    .m_ready (m_axi_arready),
    .m_data  (ar_m_payload)
  );

  axi_channel_reg_slice #(.WIDTH(R_PAY_W)) u_r (
    .aclk    (aclk),
    .aresetn (aresetn),
    .s_valid (m_axi_rvalid),
    .s_ready (m_axi_rready),
    .s_data  (r_s_payload),
    .m_valid (s_axi_rvalid),
    .m_ready (s_axi_rready),
    .m_data  (r_m_payload)
  );

endmodule : axi_register_slice

`default_nettype wire
