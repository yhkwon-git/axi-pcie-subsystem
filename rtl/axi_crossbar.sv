`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// axi_crossbar
//
// 2x2 AXI4-Lite crossbar for the control-plane interconnect.
//
//   SI0, SI1  slave interfaces, facing two upstream masters
//   MI0, MI1  master interfaces, facing two downstream slaves
//
// Address decode (default 64 KiB windows, parameters override the map):
//   MI0  M0_BASE / M0_MASK   default 0x0000_0000 - 0x0000_FFFF
//   MI1  M1_BASE / M1_MASK   default 0x0001_0000 - 0x0001_FFFF
// A hit is (addr & mask) == (base & mask). No hit, or a hit in both windows,
// completes on the SI as DECERR and does not touch a downstream slave.
//
// Each SI accepts one write and one read at a time (AXI4-Lite has no ID, so
// responses stay in order without a reorder buffer). AW and W are absorbed
// independently and only then presented together, so W-before-AW is legal and
// the two beats cannot be steered at different slaves.
//
// Arbitration is per downstream slave and per direction. Write and read locks
// are independent, so one slave can take a write from one master and a read
// from the other in the same cycles. Two masters aimed at different slaves
// run in parallel. Two masters aimed at the same slave share a round-robin
// token: the winner is moved to the back of the queue, and the slave stays
// locked until that master has accepted B or R. Payload bytes are forwarded
// unchanged; BRESP/RRESP from the target are not rewritten.
//
// aresetn is asynchronously asserted and synchronously deasserted.
// -----------------------------------------------------------------------------

module axi_crossbar #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter logic [ADDR_WIDTH-1:0] M0_BASE = '0,
  parameter logic [ADDR_WIDTH-1:0] M0_MASK = ({ADDR_WIDTH{1'b1}} << 16),
  parameter logic [ADDR_WIDTH-1:0] M1_BASE = ADDR_WIDTH'(32'h0001_0000),
  parameter logic [ADDR_WIDTH-1:0] M1_MASK = ({ADDR_WIDTH{1'b1}} << 16)
) (
  input  wire                        aclk,
  input  wire                        aresetn,

  // SI0. Upstream master 0.
  input  wire [ADDR_WIDTH-1:0]       s0_axi_awaddr,
  input  wire [2:0]                  s0_axi_awprot,
  input  wire                        s0_axi_awvalid,
  output wire                        s0_axi_awready,
  input  wire [DATA_WIDTH-1:0]       s0_axi_wdata,
  input  wire [(DATA_WIDTH/8)-1:0]   s0_axi_wstrb,
  input  wire                        s0_axi_wvalid,
  output wire                        s0_axi_wready,
  output wire [1:0]                  s0_axi_bresp,
  output wire                        s0_axi_bvalid,
  input  wire                        s0_axi_bready,
  input  wire [ADDR_WIDTH-1:0]       s0_axi_araddr,
  input  wire [2:0]                  s0_axi_arprot,
  input  wire                        s0_axi_arvalid,
  output wire                        s0_axi_arready,
  output wire [DATA_WIDTH-1:0]       s0_axi_rdata,
  output wire [1:0]                  s0_axi_rresp,
  output wire                        s0_axi_rvalid,
  input  wire                        s0_axi_rready,

  // SI1. Upstream master 1.
  input  wire [ADDR_WIDTH-1:0]       s1_axi_awaddr,
  input  wire [2:0]                  s1_axi_awprot,
  input  wire                        s1_axi_awvalid,
  output wire                        s1_axi_awready,
  input  wire [DATA_WIDTH-1:0]       s1_axi_wdata,
  input  wire [(DATA_WIDTH/8)-1:0]   s1_axi_wstrb,
  input  wire                        s1_axi_wvalid,
  output wire                        s1_axi_wready,
  output wire [1:0]                  s1_axi_bresp,
  output wire                        s1_axi_bvalid,
  input  wire                        s1_axi_bready,
  input  wire [ADDR_WIDTH-1:0]       s1_axi_araddr,
  input  wire [2:0]                  s1_axi_arprot,
  input  wire                        s1_axi_arvalid,
  output wire                        s1_axi_arready,
  output wire [DATA_WIDTH-1:0]       s1_axi_rdata,
  output wire [1:0]                  s1_axi_rresp,
  output wire                        s1_axi_rvalid,
  input  wire                        s1_axi_rready,

  // MI0. Downstream slave 0.
  output wire [ADDR_WIDTH-1:0]       m0_axi_awaddr,
  output wire [2:0]                  m0_axi_awprot,
  output wire                        m0_axi_awvalid,
  input  wire                        m0_axi_awready,
  output wire [DATA_WIDTH-1:0]       m0_axi_wdata,
  output wire [(DATA_WIDTH/8)-1:0]   m0_axi_wstrb,
  output wire                        m0_axi_wvalid,
  input  wire                        m0_axi_wready,
  input  wire [1:0]                  m0_axi_bresp,
  input  wire                        m0_axi_bvalid,
  output wire                        m0_axi_bready,
  output wire [ADDR_WIDTH-1:0]       m0_axi_araddr,
  output wire [2:0]                  m0_axi_arprot,
  output wire                        m0_axi_arvalid,
  input  wire                        m0_axi_arready,
  input  wire [DATA_WIDTH-1:0]       m0_axi_rdata,
  input  wire [1:0]                  m0_axi_rresp,
  input  wire                        m0_axi_rvalid,
  output wire                        m0_axi_rready,

  // MI1. Downstream slave 1.
  output wire [ADDR_WIDTH-1:0]       m1_axi_awaddr,
  output wire [2:0]                  m1_axi_awprot,
  output wire                        m1_axi_awvalid,
  input  wire                        m1_axi_awready,
  output wire [DATA_WIDTH-1:0]       m1_axi_wdata,
  output wire [(DATA_WIDTH/8)-1:0]   m1_axi_wstrb,
  output wire                        m1_axi_wvalid,
  input  wire                        m1_axi_wready,
  input  wire [1:0]                  m1_axi_bresp,
  input  wire                        m1_axi_bvalid,
  output wire                        m1_axi_bready,
  output wire [ADDR_WIDTH-1:0]       m1_axi_araddr,
  output wire [2:0]                  m1_axi_arprot,
  output wire                        m1_axi_arvalid,
  input  wire                        m1_axi_arready,
  input  wire [DATA_WIDTH-1:0]       m1_axi_rdata,
  input  wire [1:0]                  m1_axi_rresp,
  input  wire                        m1_axi_rvalid,
  output wire                        m1_axi_rready
);

  generate
    if ((DATA_WIDTH != 32) && (DATA_WIDTH != 64)) begin : g_illegal_data_width
      initial $error("axi_crossbar: AXI4-Lite DATA_WIDTH must be 32 or 64");
    end
    if ((ADDR_WIDTH < 32) || (ADDR_WIDTH > 64)) begin : g_illegal_addr_width
      initial $error("axi_crossbar: ADDR_WIDTH must be in 32..64");
    end
  endgenerate

  localparam int STRB_WIDTH  = DATA_WIDTH / 8;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // Per-SI phase. Write and read trackers are independent.
  //   IDLE  buffers are filling (AW and W may arrive on different cycles)
  //   ARB   both beats are stored; waiting for this slave's round-robin token
  //   SEND  token held; presenting the forward beat(s) until accepted
  //   RESP  waiting for the response, then for the upstream master to take it
  localparam logic [1:0] PH_IDLE = 2'd0;
  localparam logic [1:0] PH_ARB  = 2'd1;
  localparam logic [1:0] PH_SEND = 2'd2;
  localparam logic [1:0] PH_RESP = 2'd3;

  // --------------------------------------------------------------------------
  // Port gather. Index 0 is SI0/MI0, index 1 is SI1/MI1.
  // --------------------------------------------------------------------------

  wire [ADDR_WIDTH-1:0]     s_awaddr  [2];
  wire [2:0]                s_awprot  [2];
  wire                      s_awvalid [2];
  wire                      s_awready [2];
  wire [DATA_WIDTH-1:0]     s_wdata   [2];
  wire [STRB_WIDTH-1:0]     s_wstrb   [2];
  wire                      s_wvalid  [2];
  wire                      s_wready  [2];
  wire [1:0]                s_bresp   [2];
  wire                      s_bvalid  [2];
  wire                      s_bready  [2];
  wire [ADDR_WIDTH-1:0]     s_araddr  [2];
  wire [2:0]                s_arprot  [2];
  wire                      s_arvalid [2];
  wire                      s_arready [2];
  wire [DATA_WIDTH-1:0]     s_rdata   [2];
  wire [1:0]                s_rresp   [2];
  wire                      s_rvalid  [2];
  wire                      s_rready  [2];

  wire [ADDR_WIDTH-1:0]     m_awaddr  [2];
  wire [2:0]                m_awprot  [2];
  wire                      m_awvalid [2];
  wire                      m_awready [2];
  wire [DATA_WIDTH-1:0]     m_wdata   [2];
  wire [STRB_WIDTH-1:0]     m_wstrb   [2];
  wire                      m_wvalid  [2];
  wire                      m_wready  [2];
  wire [1:0]                m_bresp   [2];
  wire                      m_bvalid  [2];
  wire                      m_bready  [2];
  wire [ADDR_WIDTH-1:0]     m_araddr  [2];
  wire [2:0]                m_arprot  [2];
  wire                      m_arvalid [2];
  wire                      m_arready [2];
  wire [DATA_WIDTH-1:0]     m_rdata   [2];
  wire [1:0]                m_rresp   [2];
  wire                      m_rvalid  [2];
  wire                      m_rready  [2];

  assign s_awaddr[0]  = s0_axi_awaddr;
  assign s_awprot[0]  = s0_axi_awprot;
  assign s_awvalid[0] = s0_axi_awvalid;
  assign s_wdata[0]   = s0_axi_wdata;
  assign s_wstrb[0]   = s0_axi_wstrb;
  assign s_wvalid[0]  = s0_axi_wvalid;
  assign s_bready[0]  = s0_axi_bready;
  assign s_araddr[0]  = s0_axi_araddr;
  assign s_arprot[0]  = s0_axi_arprot;
  assign s_arvalid[0] = s0_axi_arvalid;
  assign s_rready[0]  = s0_axi_rready;

  assign s_awaddr[1]  = s1_axi_awaddr;
  assign s_awprot[1]  = s1_axi_awprot;
  assign s_awvalid[1] = s1_axi_awvalid;
  assign s_wdata[1]   = s1_axi_wdata;
  assign s_wstrb[1]   = s1_axi_wstrb;
  assign s_wvalid[1]  = s1_axi_wvalid;
  assign s_bready[1]  = s1_axi_bready;
  assign s_araddr[1]  = s1_axi_araddr;
  assign s_arprot[1]  = s1_axi_arprot;
  assign s_arvalid[1] = s1_axi_arvalid;
  assign s_rready[1]  = s1_axi_rready;

  assign s0_axi_awready = s_awready[0];
  assign s0_axi_wready  = s_wready[0];
  assign s0_axi_bresp   = s_bresp[0];
  assign s0_axi_bvalid  = s_bvalid[0];
  assign s0_axi_arready = s_arready[0];
  assign s0_axi_rdata   = s_rdata[0];
  assign s0_axi_rresp   = s_rresp[0];
  assign s0_axi_rvalid  = s_rvalid[0];

  assign s1_axi_awready = s_awready[1];
  assign s1_axi_wready  = s_wready[1];
  assign s1_axi_bresp   = s_bresp[1];
  assign s1_axi_bvalid  = s_bvalid[1];
  assign s1_axi_arready = s_arready[1];
  assign s1_axi_rdata   = s_rdata[1];
  assign s1_axi_rresp   = s_rresp[1];
  assign s1_axi_rvalid  = s_rvalid[1];

  assign m_awready[0] = m0_axi_awready;
  assign m_wready[0]  = m0_axi_wready;
  assign m_bresp[0]   = m0_axi_bresp;
  assign m_bvalid[0]  = m0_axi_bvalid;
  assign m_arready[0] = m0_axi_arready;
  assign m_rdata[0]   = m0_axi_rdata;
  assign m_rresp[0]   = m0_axi_rresp;
  assign m_rvalid[0]  = m0_axi_rvalid;

  assign m_awready[1] = m1_axi_awready;
  assign m_wready[1]  = m1_axi_wready;
  assign m_bresp[1]   = m1_axi_bresp;
  assign m_bvalid[1]  = m1_axi_bvalid;
  assign m_arready[1] = m1_axi_arready;
  assign m_rdata[1]   = m1_axi_rdata;
  assign m_rresp[1]   = m1_axi_rresp;
  assign m_rvalid[1]  = m1_axi_rvalid;

  assign m0_axi_awaddr  = m_awaddr[0];
  assign m0_axi_awprot  = m_awprot[0];
  assign m0_axi_awvalid = m_awvalid[0];
  assign m0_axi_wdata   = m_wdata[0];
  assign m0_axi_wstrb   = m_wstrb[0];
  assign m0_axi_wvalid  = m_wvalid[0];
  assign m0_axi_bready  = m_bready[0];
  assign m0_axi_araddr  = m_araddr[0];
  assign m0_axi_arprot  = m_arprot[0];
  assign m0_axi_arvalid = m_arvalid[0];
  assign m0_axi_rready  = m_rready[0];

  assign m1_axi_awaddr  = m_awaddr[1];
  assign m1_axi_awprot  = m_awprot[1];
  assign m1_axi_awvalid = m_awvalid[1];
  assign m1_axi_wdata   = m_wdata[1];
  assign m1_axi_wstrb   = m_wstrb[1];
  assign m1_axi_wvalid  = m_wvalid[1];
  assign m1_axi_bready  = m_bready[1];
  assign m1_axi_araddr  = m_araddr[1];
  assign m1_axi_arprot  = m_arprot[1];
  assign m1_axi_arvalid = m_arvalid[1];
  assign m1_axi_rready  = m_rready[1];

  function automatic logic [1:0] decode_slave(input logic [ADDR_WIDTH-1:0] addr);
    logic hit0;
    logic hit1;
    begin
      hit0 = ((addr & M0_MASK) == (M0_BASE & M0_MASK));
      hit1 = ((addr & M1_MASK) == (M1_BASE & M1_MASK));
      return {hit1, hit0};
    end
  endfunction

  // One-hot {SI1, SI0}. prefer_si1 selects SI1 when both request. A grant
  // with only one requester still returns that requester.
  function automatic logic [1:0] rr_pick(
    input logic prefer_si1,
    input logic req_si0,
    input logic req_si1
  );
    begin
      if (prefer_si1) begin
        if (req_si1) return 2'b10;
        if (req_si0) return 2'b01;
      end else begin
        if (req_si0) return 2'b01;
        if (req_si1) return 2'b10;
      end
      return 2'b00;
    end
  endfunction

  // --------------------------------------------------------------------------
  // Write tracker, one per upstream master.
  // --------------------------------------------------------------------------

  logic                      aw_v      [2];
  logic [ADDR_WIDTH-1:0]     aw_addr   [2];
  logic [2:0]                aw_prot   [2];
  logic                      w_v       [2];
  logic [DATA_WIDTH-1:0]     w_data    [2];
  logic [STRB_WIDTH-1:0]     w_strb    [2];
  logic [1:0]                wr_phase  [2];
  logic                      wr_decerr [2];
  logic                      wr_tgt    [2];
  logic                      aw_done   [2];
  logic                      w_done    [2];
  logic                      b_v       [2];
  logic [1:0]                b_resp    [2];

  // Per downstream slave. wr_rr == 1 gives SI1 priority on the next grant.
  logic                      wr_lock   [2];
  logic                      wr_owner  [2];
  logic                      wr_rr     [2];

  wire                       wr_grant  [2];
  wire                       wr_release[2];
  wire [1:0]                 wr_pick   [2];

  assign wr_pick[0] = rr_pick(
    wr_rr[0],
    (wr_phase[0] == PH_ARB) && !wr_decerr[0] && (wr_tgt[0] == 1'b0),
    (wr_phase[1] == PH_ARB) && !wr_decerr[1] && (wr_tgt[1] == 1'b0)
  );
  assign wr_pick[1] = rr_pick(
    wr_rr[1],
    (wr_phase[0] == PH_ARB) && !wr_decerr[0] && (wr_tgt[0] == 1'b1),
    (wr_phase[1] == PH_ARB) && !wr_decerr[1] && (wr_tgt[1] == 1'b1)
  );

  assign wr_grant[0] = (wr_phase[0] == PH_ARB) && !wr_lock[wr_tgt[0]] &&
                       wr_pick[wr_tgt[0]][0];
  assign wr_grant[1] = (wr_phase[1] == PH_ARB) && !wr_lock[wr_tgt[1]] &&
                       wr_pick[wr_tgt[1]][1];

  // Winner goes to the back: granting SI0 leaves the token pointing at SI1.
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_lock[0]  <= 1'b0;
      wr_lock[1]  <= 1'b0;
      wr_owner[0] <= 1'b0;
      wr_owner[1] <= 1'b0;
      wr_rr[0]    <= 1'b0;
      wr_rr[1]    <= 1'b0;
    end else begin
      for (int s = 0; s < 2; s++) begin
        if (!wr_lock[s] && (wr_pick[s] != 2'b00)) begin
          wr_lock[s]  <= 1'b1;
          wr_owner[s] <= wr_pick[s][1];
          wr_rr[s]    <= wr_pick[s][0];
        end else if (wr_lock[s] && wr_release[wr_owner[s]] &&
                     (wr_tgt[wr_owner[s]] == 1'(s))) begin
          wr_lock[s] <= 1'b0;
        end
      end
    end
  end

  generate
    for (genvar i = 0; i < 2; i++) begin : g_wr
      wire aw_accept;
      wire w_accept;
      wire aw_have;
      wire w_have;
      wire [ADDR_WIDTH-1:0] aw_addr_now;
      wire [1:0] aw_hit;
      wire aw_hs;
      wire w_hs;
      wire b_cap;

      assign aw_accept   = s_awvalid[i] & ~aw_v[i];
      assign w_accept    = s_wvalid[i] & ~w_v[i];
      assign aw_have     = aw_v[i] | aw_accept;
      assign w_have      = w_v[i] | w_accept;
      assign aw_addr_now = aw_accept ? s_awaddr[i] : aw_addr[i];
      assign aw_hit      = decode_slave(aw_addr_now);
      assign s_awready[i] = ~aw_v[i];
      assign s_wready[i]  = ~w_v[i];
      assign s_bvalid[i]  = b_v[i];
      assign s_bresp[i]   = b_resp[i];
      assign wr_release[i] = (wr_phase[i] == PH_RESP) && b_v[i] && s_bready[i];

      assign aw_hs = (wr_phase[i] == PH_SEND) && !aw_done[i] &&
                     wr_lock[wr_tgt[i]] && (wr_owner[wr_tgt[i]] == i) &&
                     m_awready[wr_tgt[i]];
      assign w_hs  = (wr_phase[i] == PH_SEND) && !w_done[i] &&
                     wr_lock[wr_tgt[i]] && (wr_owner[wr_tgt[i]] == i) &&
                     m_wready[wr_tgt[i]];
      assign b_cap = (wr_phase[i] == PH_RESP) && !wr_decerr[i] && !b_v[i] &&
                     wr_lock[wr_tgt[i]] && (wr_owner[wr_tgt[i]] == i) &&
                     m_bvalid[wr_tgt[i]];

      always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
          aw_v[i] <= 1'b0;
        end else if (wr_release[i]) begin
          aw_v[i] <= 1'b0;
        end else if (aw_accept) begin
          aw_v[i]    <= 1'b1;
          aw_addr[i] <= s_awaddr[i];
          aw_prot[i] <= s_awprot[i];
        end
      end

      always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
          w_v[i] <= 1'b0;
        end else if (wr_release[i]) begin
          w_v[i] <= 1'b0;
        end else if (w_accept) begin
          w_v[i]    <= 1'b1;
          w_data[i] <= s_wdata[i];
          w_strb[i] <= s_wstrb[i];
        end
      end

      always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
          wr_phase[i]  <= PH_IDLE;
          wr_decerr[i] <= 1'b0;
          wr_tgt[i]    <= 1'b0;
          aw_done[i]   <= 1'b0;
          w_done[i]    <= 1'b0;
          b_v[i]       <= 1'b0;
          b_resp[i]    <= 2'b00;
        end else begin
          case (wr_phase[i])
            PH_IDLE: begin
              aw_done[i] <= 1'b0;
              w_done[i]  <= 1'b0;
              if (aw_have && w_have) begin
                if (aw_hit == 2'b01) begin
                  wr_decerr[i] <= 1'b0;
                  wr_tgt[i]    <= 1'b0;
                  wr_phase[i]  <= PH_ARB;
                end else if (aw_hit == 2'b10) begin
                  wr_decerr[i] <= 1'b0;
                  wr_tgt[i]    <= 1'b1;
                  wr_phase[i]  <= PH_ARB;
                end else begin
                  wr_decerr[i] <= 1'b1;
                  b_resp[i]    <= RESP_DECERR;
                  b_v[i]       <= 1'b1;
                  wr_phase[i]  <= PH_RESP;
                end
              end
            end
            PH_ARB: begin
              if (wr_grant[i]) begin
                wr_phase[i] <= PH_SEND;
              end
            end
            PH_SEND: begin
              if (aw_hs) aw_done[i] <= 1'b1;
              if (w_hs)  w_done[i]  <= 1'b1;
              if ((aw_done[i] || aw_hs) && (w_done[i] || w_hs)) begin
                wr_phase[i] <= PH_RESP;
              end
            end
            PH_RESP: begin
              if (b_cap) begin
                b_v[i]    <= 1'b1;
                b_resp[i] <= m_bresp[wr_tgt[i]];
              end
              if (b_v[i] && s_bready[i]) begin
                b_v[i]       <= 1'b0;
                wr_decerr[i] <= 1'b0;
                wr_phase[i]  <= PH_IDLE;
              end
            end
            default: begin
              wr_phase[i] <= PH_IDLE;
            end
          endcase
        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Read tracker, one per upstream master. Independent of the write lock so a
  // read and a write can occupy the same downstream slave together.
  // --------------------------------------------------------------------------

  logic                      ar_v      [2];
  logic [ADDR_WIDTH-1:0]     ar_addr   [2];
  logic [2:0]                ar_prot   [2];
  logic [1:0]                rd_phase  [2];
  logic                      rd_decerr [2];
  logic                      rd_tgt    [2];
  logic                      r_v       [2];
  logic [DATA_WIDTH-1:0]     r_data    [2];
  logic [1:0]                r_resp    [2];

  logic                      rd_lock   [2];
  logic                      rd_owner  [2];
  logic                      rd_rr     [2];

  wire                       rd_grant  [2];
  wire                       rd_release[2];
  wire [1:0]                 rd_pick   [2];

  assign rd_pick[0] = rr_pick(
    rd_rr[0],
    (rd_phase[0] == PH_ARB) && !rd_decerr[0] && (rd_tgt[0] == 1'b0),
    (rd_phase[1] == PH_ARB) && !rd_decerr[1] && (rd_tgt[1] == 1'b0)
  );
  assign rd_pick[1] = rr_pick(
    rd_rr[1],
    (rd_phase[0] == PH_ARB) && !rd_decerr[0] && (rd_tgt[0] == 1'b1),
    (rd_phase[1] == PH_ARB) && !rd_decerr[1] && (rd_tgt[1] == 1'b1)
  );

  assign rd_grant[0] = (rd_phase[0] == PH_ARB) && !rd_lock[rd_tgt[0]] &&
                       rd_pick[rd_tgt[0]][0];
  assign rd_grant[1] = (rd_phase[1] == PH_ARB) && !rd_lock[rd_tgt[1]] &&
                       rd_pick[rd_tgt[1]][1];

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      rd_lock[0]  <= 1'b0;
      rd_lock[1]  <= 1'b0;
      rd_owner[0] <= 1'b0;
      rd_owner[1] <= 1'b0;
      rd_rr[0]    <= 1'b0;
      rd_rr[1]    <= 1'b0;
    end else begin
      for (int s = 0; s < 2; s++) begin
        if (!rd_lock[s] && (rd_pick[s] != 2'b00)) begin
          rd_lock[s]  <= 1'b1;
          rd_owner[s] <= rd_pick[s][1];
          rd_rr[s]    <= rd_pick[s][0];
        end else if (rd_lock[s] && rd_release[rd_owner[s]] &&
                     (rd_tgt[rd_owner[s]] == 1'(s))) begin
          rd_lock[s] <= 1'b0;
        end
      end
    end
  end

  generate
    for (genvar i = 0; i < 2; i++) begin : g_rd
      wire ar_accept;
      wire ar_have;
      wire [ADDR_WIDTH-1:0] ar_addr_now;
      wire [1:0] ar_hit;
      wire ar_hs;
      wire r_cap;

      assign ar_accept   = s_arvalid[i] & ~ar_v[i];
      assign ar_have     = ar_v[i] | ar_accept;
      assign ar_addr_now = ar_accept ? s_araddr[i] : ar_addr[i];
      assign ar_hit      = decode_slave(ar_addr_now);
      assign s_arready[i] = ~ar_v[i];
      assign s_rvalid[i]  = r_v[i];
      assign s_rdata[i]   = r_data[i];
      assign s_rresp[i]   = r_resp[i];
      assign rd_release[i] = (rd_phase[i] == PH_RESP) && r_v[i] && s_rready[i];

      assign ar_hs = (rd_phase[i] == PH_SEND) && rd_lock[rd_tgt[i]] &&
                     (rd_owner[rd_tgt[i]] == i) && m_arready[rd_tgt[i]];
      assign r_cap = (rd_phase[i] == PH_RESP) && !rd_decerr[i] && !r_v[i] &&
                     rd_lock[rd_tgt[i]] && (rd_owner[rd_tgt[i]] == i) &&
                     m_rvalid[rd_tgt[i]];

      always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
          ar_v[i] <= 1'b0;
        end else if (rd_release[i]) begin
          ar_v[i] <= 1'b0;
        end else if (ar_accept) begin
          ar_v[i]    <= 1'b1;
          ar_addr[i] <= s_araddr[i];
          ar_prot[i] <= s_arprot[i];
        end
      end

      always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
          rd_phase[i]  <= PH_IDLE;
          rd_decerr[i] <= 1'b0;
          rd_tgt[i]    <= 1'b0;
          r_v[i]       <= 1'b0;
          r_data[i]    <= '0;
          r_resp[i]    <= 2'b00;
        end else begin
          case (rd_phase[i])
            PH_IDLE: begin
              if (ar_have) begin
                if (ar_hit == 2'b01) begin
                  rd_decerr[i] <= 1'b0;
                  rd_tgt[i]    <= 1'b0;
                  rd_phase[i]  <= PH_ARB;
                end else if (ar_hit == 2'b10) begin
                  rd_decerr[i] <= 1'b0;
                  rd_tgt[i]    <= 1'b1;
                  rd_phase[i]  <= PH_ARB;
                end else begin
                  rd_decerr[i] <= 1'b1;
                  r_data[i]    <= '0;
                  r_resp[i]    <= RESP_DECERR;
                  r_v[i]       <= 1'b1;
                  rd_phase[i]  <= PH_RESP;
                end
              end
            end
            PH_ARB: begin
              if (rd_grant[i]) begin
                rd_phase[i] <= PH_SEND;
              end
            end
            PH_SEND: begin
              if (ar_hs) begin
                rd_phase[i] <= PH_RESP;
              end
            end
            PH_RESP: begin
              if (r_cap) begin
                r_v[i]    <= 1'b1;
                r_data[i] <= m_rdata[rd_tgt[i]];
                r_resp[i] <= m_rresp[rd_tgt[i]];
              end
              if (r_v[i] && s_rready[i]) begin
                r_v[i]       <= 1'b0;
                rd_decerr[i] <= 1'b0;
                rd_phase[i]  <= PH_IDLE;
              end
            end
            default: begin
              rd_phase[i] <= PH_IDLE;
            end
          endcase
        end
      end
    end
  endgenerate

  // Forward beats. VALID is a function of the flops only, so it stays asserted
  // through the cycle in which READY is high and falls on the next clock.
  assign m_awvalid[0] = wr_lock[0] && (wr_phase[wr_owner[0]] == PH_SEND) && !aw_done[wr_owner[0]];
  assign m_wvalid[0]  = wr_lock[0] && (wr_phase[wr_owner[0]] == PH_SEND) && !w_done[wr_owner[0]];
  assign m_awvalid[1] = wr_lock[1] && (wr_phase[wr_owner[1]] == PH_SEND) && !aw_done[wr_owner[1]];
  assign m_wvalid[1]  = wr_lock[1] && (wr_phase[wr_owner[1]] == PH_SEND) && !w_done[wr_owner[1]];

  assign m_awaddr[0] = wr_lock[0] ? aw_addr[wr_owner[0]] : '0;
  assign m_awprot[0] = wr_lock[0] ? aw_prot[wr_owner[0]] : '0;
  assign m_wdata[0]  = wr_lock[0] ? w_data[wr_owner[0]]  : '0;
  assign m_wstrb[0]  = wr_lock[0] ? w_strb[wr_owner[0]]  : '0;
  assign m_awaddr[1] = wr_lock[1] ? aw_addr[wr_owner[1]] : '0;
  assign m_awprot[1] = wr_lock[1] ? aw_prot[wr_owner[1]] : '0;
  assign m_wdata[1]  = wr_lock[1] ? w_data[wr_owner[1]]  : '0;
  assign m_wstrb[1]  = wr_lock[1] ? w_strb[wr_owner[1]]  : '0;

  assign m_arvalid[0] = rd_lock[0] && (rd_phase[rd_owner[0]] == PH_SEND);
  assign m_arvalid[1] = rd_lock[1] && (rd_phase[rd_owner[1]] == PH_SEND);
  assign m_araddr[0]  = rd_lock[0] ? ar_addr[rd_owner[0]] : '0;
  assign m_arprot[0]  = rd_lock[0] ? ar_prot[rd_owner[0]] : '0;
  assign m_araddr[1]  = rd_lock[1] ? ar_addr[rd_owner[1]] : '0;
  assign m_arprot[1]  = rd_lock[1] ? ar_prot[rd_owner[1]] : '0;

  // Take B/R only once the tracker is in RESP and has not latched them yet.
  assign m_bready[0] = wr_lock[0] && (wr_phase[wr_owner[0]] == PH_RESP) &&
                       !b_v[wr_owner[0]] && !wr_decerr[wr_owner[0]] &&
                       (wr_tgt[wr_owner[0]] == 1'b0);
  assign m_bready[1] = wr_lock[1] && (wr_phase[wr_owner[1]] == PH_RESP) &&
                       !b_v[wr_owner[1]] && !wr_decerr[wr_owner[1]] &&
                       (wr_tgt[wr_owner[1]] == 1'b1);
  assign m_rready[0] = rd_lock[0] && (rd_phase[rd_owner[0]] == PH_RESP) &&
                       !r_v[rd_owner[0]] && !rd_decerr[rd_owner[0]] &&
                       (rd_tgt[rd_owner[0]] == 1'b0);
  assign m_rready[1] = rd_lock[1] && (rd_phase[rd_owner[1]] == PH_RESP) &&
                       !r_v[rd_owner[1]] && !rd_decerr[rd_owner[1]] &&
                       (rd_tgt[rd_owner[1]] == 1'b1);

endmodule : axi_crossbar

`default_nettype wire
