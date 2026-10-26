`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// nand_sol_subsystem_top
//
// Control-plane top for the NAND-solution subsystem.
//
//   clk_pcie : host TLP DWORD stream and completion DWORD stream
//   clk_axi  : bridge, register slices, crossbar, outstanding queue,
//              firmware CPU port, CSR port (MI0), NAND window (MI1)
//
// The two clocks meet only in u_tlp_ingress and u_cpl_egress, both
// cdc_async_fifo. The bridge's own pclk and aclk are clk_axi: after the
// ingress FIFO, header parsing and the AXI master run in one domain, and the
// bridge's internal FIFOs keep that request stream in order. Completions
// cross back to the host in u_cpl_egress.
//
// The bridge master is AXI4. This top carries it onto an AXI4-Lite fabric,
// so a TLP length of 1 (AWLEN/ARLEN == 0) is the transaction the slices and
// the 2x2 crossbar accept. MI0 is 0x0000_0000-0x0000_FFFF and MI1 is
// 0x0001_0000-0x0001_FFFF, each behind a register slice. SI0 is the host
// bridge. SI1 is the firmware CPU, also behind a register slice.
//
// outstanding_queue watches the host AR/R handshake. A new AR is accepted
// only while the queue has a free slot and that read ID is not already in
// flight. The lite slaves have no RID, so the queue puts the oldest in-flight
// ID back on the bridge's RID with RLAST when the R beat returns.
// -----------------------------------------------------------------------------

module nand_sol_subsystem_top #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int OQ_DEPTH   = 4
) (
  input  wire                        clk_pcie,
  input  wire                        rst_pcie_n,
  input  wire                        clk_axi,
  input  wire                        rst_axi_n,

  input  wire                        tlp_valid,
  output wire                        tlp_ready,
  input  wire                        tlp_sop,
  input  wire                        tlp_eop,
  input  wire [31:0]                 tlp_data,
  // Parser runs in clk_axi, after u_tlp_ingress.
  output wire                        tlp_error,

  output wire                        cpl_valid,
  input  wire                        cpl_ready,
  output wire                        cpl_sop,
  output wire                        cpl_eop,
  output wire [31:0]                 cpl_data,

  // Firmware CPU. AXI4-Lite slave port on clk_axi. Crossbar SI1.
  input  wire [ADDR_WIDTH-1:0]       cpu_axi_awaddr,
  input  wire [2:0]                  cpu_axi_awprot,
  input  wire                        cpu_axi_awvalid,
  output wire                        cpu_axi_awready,
  input  wire [DATA_WIDTH-1:0]       cpu_axi_wdata,
  input  wire [(DATA_WIDTH/8)-1:0]   cpu_axi_wstrb,
  input  wire                        cpu_axi_wvalid,
  output wire                        cpu_axi_wready,
  output wire [1:0]                  cpu_axi_bresp,
  output wire                        cpu_axi_bvalid,
  input  wire                        cpu_axi_bready,
  input  wire [ADDR_WIDTH-1:0]       cpu_axi_araddr,
  input  wire [2:0]                  cpu_axi_arprot,
  input  wire                        cpu_axi_arvalid,
  output wire                        cpu_axi_arready,
  output wire [DATA_WIDTH-1:0]       cpu_axi_rdata,
  output wire [1:0]                  cpu_axi_rresp,
  output wire                        cpu_axi_rvalid,
  input  wire                        cpu_axi_rready,

  // CSR window, crossbar MI0, after a register slice.
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

  // NAND window, crossbar MI1, after a register slice.
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
  output wire                        m1_axi_rready,

  output wire                        oq_empty,
  output wire                        oq_full,
  output wire [2:0]                  oq_count
);

  localparam int STRB_W = DATA_WIDTH / 8;
  localparam int FIFO_W = 34;

  generate
    if ((ADDR_WIDTH != 32) || (DATA_WIDTH != 32)) begin : g_width
      initial $error("nand_sol_subsystem_top: this integration is 32-bit AXI");
    end
    if ($clog2(OQ_DEPTH + 1) != 3) begin : g_oq
      initial $error("nand_sol_subsystem_top: oq_count is 3 bits, so OQ_DEPTH must stay in 4..7");
    end
  endgenerate

  // Request crosses clk_pcie -> clk_axi. Completion crosses back.
  wire                  ing_full;
  wire                  ing_empty;
  wire [FIFO_W-1:0]     ing_data;
  wire                  egr_full;
  wire                  egr_empty;
  wire [FIFO_W-1:0]     egr_data;

  wire                  br_tlp_valid;
  wire                  br_tlp_ready;
  wire                  br_cpl_valid;
  wire                  br_cpl_ready;
  wire                  br_cpl_sop;
  wire                  br_cpl_eop;
  wire [31:0]           br_cpl_data;

  wire [3:0]            br_awid;
  wire [ADDR_WIDTH-1:0] br_awaddr;
  wire [7:0]            br_awlen;
  wire [2:0]            br_awsize;
  wire [1:0]            br_awburst;
  wire                  br_awlock;
  wire [3:0]            br_awcache;
  wire [2:0]            br_awprot;
  wire                  br_awvalid;
  wire                  br_awready;
  wire [31:0]           br_wdata;
  wire [3:0]            br_wstrb;
  wire                  br_wlast;
  wire                  br_wvalid;
  wire                  br_wready;
  wire [3:0]            br_bid;
  wire [1:0]            br_bresp;
  wire                  br_bvalid;
  wire                  br_bready;
  wire [3:0]            br_arid;
  wire [ADDR_WIDTH-1:0] br_araddr;
  wire [7:0]            br_arlen;
  wire [2:0]            br_arsize;
  wire [1:0]            br_arburst;
  wire                  br_arlock;
  wire [3:0]            br_arcache;
  wire [2:0]            br_arprot;
  wire                  br_arvalid;
  wire                  br_arready;
  wire [3:0]            br_rid;
  wire [31:0]           br_rdata;
  wire [1:0]            br_rresp;
  wire                  br_rlast;
  wire                  br_rvalid;
  wire                  br_rready;

  wire                  host_arready;
  wire                  alloc_ready;
  wire                  oldest_valid;
  wire [3:0]            oldest_id;
  wire [ADDR_WIDTH-1:0] oldest_addr;
  wire                  retire_hit;
  wire [ADDR_WIDTH-1:0] retire_addr;
  logic [3:0]           bid_q;

  // Host slice master side -> crossbar SI0.
  wire [ADDR_WIDTH-1:0] p0_awaddr;
  wire [2:0]            p0_awprot;
  wire                  p0_awvalid;
  wire                  p0_awready;
  wire [DATA_WIDTH-1:0] p0_wdata;
  wire [STRB_W-1:0]     p0_wstrb;
  wire                  p0_wvalid;
  wire                  p0_wready;
  wire [1:0]            p0_bresp;
  wire                  p0_bvalid;
  wire                  p0_bready;
  wire [ADDR_WIDTH-1:0] p0_araddr;
  wire [2:0]            p0_arprot;
  wire                  p0_arvalid;
  wire                  p0_arready;
  wire [DATA_WIDTH-1:0] p0_rdata;
  wire [1:0]            p0_rresp;
  wire                  p0_rvalid;
  wire                  p0_rready;

  // CPU slice master side -> crossbar SI1.
  wire [ADDR_WIDTH-1:0] p1_awaddr;
  wire [2:0]            p1_awprot;
  wire                  p1_awvalid;
  wire                  p1_awready;
  wire [DATA_WIDTH-1:0] p1_wdata;
  wire [STRB_W-1:0]     p1_wstrb;
  wire                  p1_wvalid;
  wire                  p1_wready;
  wire [1:0]            p1_bresp;
  wire                  p1_bvalid;
  wire                  p1_bready;
  wire [ADDR_WIDTH-1:0] p1_araddr;
  wire [2:0]            p1_arprot;
  wire                  p1_arvalid;
  wire                  p1_arready;
  wire [DATA_WIDTH-1:0] p1_rdata;
  wire [1:0]            p1_rresp;
  wire                  p1_rvalid;
  wire                  p1_rready;

  // Crossbar MI0 -> CSR slice slave side.
  wire [ADDR_WIDTH-1:0] x0_awaddr;
  wire [2:0]            x0_awprot;
  wire                  x0_awvalid;
  wire                  x0_awready;
  wire [DATA_WIDTH-1:0] x0_wdata;
  wire [STRB_W-1:0]     x0_wstrb;
  wire                  x0_wvalid;
  wire                  x0_wready;
  wire [1:0]            x0_bresp;
  wire                  x0_bvalid;
  wire                  x0_bready;
  wire [ADDR_WIDTH-1:0] x0_araddr;
  wire [2:0]            x0_arprot;
  wire                  x0_arvalid;
  wire                  x0_arready;
  wire [DATA_WIDTH-1:0] x0_rdata;
  wire [1:0]            x0_rresp;
  wire                  x0_rvalid;
  wire                  x0_rready;

  // Crossbar MI1 -> NAND slice slave side.
  wire [ADDR_WIDTH-1:0] x1_awaddr;
  wire [2:0]            x1_awprot;
  wire                  x1_awvalid;
  wire                  x1_awready;
  wire [DATA_WIDTH-1:0] x1_wdata;
  wire [STRB_W-1:0]     x1_wstrb;
  wire                  x1_wvalid;
  wire                  x1_wready;
  wire [1:0]            x1_bresp;
  wire                  x1_bvalid;
  wire                  x1_bready;
  wire [ADDR_WIDTH-1:0] x1_araddr;
  wire [2:0]            x1_arprot;
  wire                  x1_arvalid;
  wire                  x1_arready;
  wire [DATA_WIDTH-1:0] x1_rdata;
  wire [1:0]            x1_rresp;
  wire                  x1_rvalid;
  wire                  x1_rready;

  cdc_async_fifo #(
    .WIDTH(FIFO_W),
    .DEPTH(16)
  ) u_tlp_ingress (
    .wr_clk   (clk_pcie),
    .wr_rst_n (rst_pcie_n),
    .wr_en    (tlp_valid & ~ing_full),
    .wr_data  ({tlp_eop, tlp_sop, tlp_data}),
    .wr_full  (ing_full),
    .rd_clk   (clk_axi),
    .rd_rst_n (rst_axi_n),
    .rd_en    (br_tlp_valid & br_tlp_ready),
    .rd_data  (ing_data),
    .rd_empty (ing_empty)
  );

  cdc_async_fifo #(
    .WIDTH(FIFO_W),
    .DEPTH(16)
  ) u_cpl_egress (
    .wr_clk   (clk_axi),
    .wr_rst_n (rst_axi_n),
    .wr_en    (br_cpl_valid & ~egr_full),
    .wr_data  ({br_cpl_eop, br_cpl_sop, br_cpl_data}),
    .wr_full  (egr_full),
    .rd_clk   (clk_pcie),
    .rd_rst_n (rst_pcie_n),
    .rd_en    (cpl_valid & cpl_ready),
    .rd_data  (egr_data),
    .rd_empty (egr_empty)
  );

  assign tlp_ready    = ~ing_full;
  assign br_tlp_valid = ~ing_empty;
  assign br_cpl_ready = ~egr_full;
  assign cpl_valid    = ~egr_empty;
  assign cpl_data     = egr_data[31:0];
  assign cpl_sop      = egr_data[32];
  assign cpl_eop      = egr_data[33];

  pcie_to_axi_bridge #(
    .ADDR_WIDTH(32)
  ) u_bridge (
    .pclk          (clk_axi),
    .p_rst_n       (rst_axi_n),
    .aclk          (clk_axi),
    .a_rst_n       (rst_axi_n),
    .tlp_valid     (br_tlp_valid),
    .tlp_ready     (br_tlp_ready),
    .tlp_sop       (ing_data[32]),
    .tlp_eop       (ing_data[33]),
    .tlp_data      (ing_data[31:0]),
    .tlp_error     (tlp_error),
    .cpl_valid     (br_cpl_valid),
    .cpl_ready     (br_cpl_ready),
    .cpl_sop       (br_cpl_sop),
    .cpl_eop       (br_cpl_eop),
    .cpl_data      (br_cpl_data),
    .m_axi_awid    (br_awid),
    .m_axi_awaddr  (br_awaddr),
    .m_axi_awlen   (br_awlen),
    .m_axi_awsize  (br_awsize),
    .m_axi_awburst (br_awburst),
    .m_axi_awlock  (br_awlock),
    .m_axi_awcache (br_awcache),
    .m_axi_awprot  (br_awprot),
    .m_axi_awvalid (br_awvalid),
    .m_axi_awready (br_awready),
    .m_axi_wdata   (br_wdata),
    .m_axi_wstrb   (br_wstrb),
    .m_axi_wlast   (br_wlast),
    .m_axi_wvalid  (br_wvalid),
    .m_axi_wready  (br_wready),
    .m_axi_bid     (br_bid),
    .m_axi_bresp   (br_bresp),
    .m_axi_bvalid  (br_bvalid),
    .m_axi_bready  (br_bready),
    .m_axi_arid    (br_arid),
    .m_axi_araddr  (br_araddr),
    .m_axi_arlen   (br_arlen),
    .m_axi_arsize  (br_arsize),
    .m_axi_arburst (br_arburst),
    .m_axi_arlock  (br_arlock),
    .m_axi_arcache (br_arcache),
    .m_axi_arprot  (br_arprot),
    .m_axi_arvalid (br_arvalid),
    .m_axi_arready (br_arready),
    .m_axi_rid     (br_rid),
    .m_axi_rdata   (br_rdata),
    .m_axi_rresp   (br_rresp),
    .m_axi_rlast   (br_rlast),
    .m_axi_rvalid  (br_rvalid),
    .m_axi_rready  (br_rready)
  );

  // Hold a new host AR while its ID cannot be tracked. The slice sees the
  // beat only on the same cycle the queue accepts it.
  assign br_arready = host_arready & alloc_ready;
  assign br_rid     = oldest_id;
  assign br_rlast   = 1'b1;
  assign br_bid     = bid_q;

  always_ff @(posedge clk_axi or negedge rst_axi_n) begin
    if (!rst_axi_n) begin
      bid_q <= 4'd0;
    end else if (br_awvalid && br_awready) begin
      bid_q <= br_awid;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_axi) begin
    if (rst_axi_n && br_awvalid && br_awready && (br_awlen != 8'd0)) begin
      $error("nand_sol_subsystem_top: control plane accepts AWLEN 0");
    end
    if (rst_axi_n && br_arvalid && br_arready && (br_arlen != 8'd0)) begin
      $error("nand_sol_subsystem_top: control plane accepts ARLEN 0");
    end
  end
`endif

  outstanding_queue #(
    .DEPTH   (OQ_DEPTH),
    .ID_W    (4),
    .ADDR_W  (ADDR_WIDTH),
    .COUNT_W (3)
  ) u_oq (
    .clk          (clk_axi),
    .rst_n        (rst_axi_n),
    .alloc_valid  (br_arvalid & host_arready & alloc_ready),
    .alloc_ready  (alloc_ready),
    .alloc_id     (br_arid),
    .alloc_addr   (br_araddr),
    .retire_valid (br_rvalid & br_rready & oldest_valid),
    .retire_id    (oldest_id),
    .retire_hit   (retire_hit),
    .retire_addr  (retire_addr),
    .empty        (oq_empty),
    .full         (oq_full),
    .count        (oq_count),
    .oldest_valid (oldest_valid),
    .oldest_id    (oldest_id),
    .oldest_addr  (oldest_addr)
  );

  axi_register_slice #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_slice_host (
    .aclk          (clk_axi),
    .aresetn       (rst_axi_n),
    .s_axi_awaddr  (br_awaddr),
    .s_axi_awprot  (br_awprot),
    .s_axi_awvalid (br_awvalid),
    .s_axi_awready (br_awready),
    .s_axi_wdata   (br_wdata),
    .s_axi_wstrb   (br_wstrb),
    .s_axi_wvalid  (br_wvalid),
    .s_axi_wready  (br_wready),
    .s_axi_bresp   (br_bresp),
    .s_axi_bvalid  (br_bvalid),
    .s_axi_bready  (br_bready),
    .s_axi_araddr  (br_araddr),
    .s_axi_arprot  (br_arprot),
    .s_axi_arvalid (br_arvalid & alloc_ready),
    .s_axi_arready (host_arready),
    .s_axi_rdata   (br_rdata),
    .s_axi_rresp   (br_rresp),
    .s_axi_rvalid  (br_rvalid),
    .s_axi_rready  (br_rready),
    .m_axi_awaddr  (p0_awaddr),
    .m_axi_awprot  (p0_awprot),
    .m_axi_awvalid (p0_awvalid),
    .m_axi_awready (p0_awready),
    .m_axi_wdata   (p0_wdata),
    .m_axi_wstrb   (p0_wstrb),
    .m_axi_wvalid  (p0_wvalid),
    .m_axi_wready  (p0_wready),
    .m_axi_bresp   (p0_bresp),
    .m_axi_bvalid  (p0_bvalid),
    .m_axi_bready  (p0_bready),
    .m_axi_araddr  (p0_araddr),
    .m_axi_arprot  (p0_arprot),
    .m_axi_arvalid (p0_arvalid),
    .m_axi_arready (p0_arready),
    .m_axi_rdata   (p0_rdata),
    .m_axi_rresp   (p0_rresp),
    .m_axi_rvalid  (p0_rvalid),
    .m_axi_rready  (p0_rready)
  );

  axi_register_slice #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_slice_cpu (
    .aclk          (clk_axi),
    .aresetn       (rst_axi_n),
    .s_axi_awaddr  (cpu_axi_awaddr),
    .s_axi_awprot  (cpu_axi_awprot),
    .s_axi_awvalid (cpu_axi_awvalid),
    .s_axi_awready (cpu_axi_awready),
    .s_axi_wdata   (cpu_axi_wdata),
    .s_axi_wstrb   (cpu_axi_wstrb),
    .s_axi_wvalid  (cpu_axi_wvalid),
    .s_axi_wready  (cpu_axi_wready),
    .s_axi_bresp   (cpu_axi_bresp),
    .s_axi_bvalid  (cpu_axi_bvalid),
    .s_axi_bready  (cpu_axi_bready),
    .s_axi_araddr  (cpu_axi_araddr),
    .s_axi_arprot  (cpu_axi_arprot),
    .s_axi_arvalid (cpu_axi_arvalid),
    .s_axi_arready (cpu_axi_arready),
    .s_axi_rdata   (cpu_axi_rdata),
    .s_axi_rresp   (cpu_axi_rresp),
    .s_axi_rvalid  (cpu_axi_rvalid),
    .s_axi_rready  (cpu_axi_rready),
    .m_axi_awaddr  (p1_awaddr),
    .m_axi_awprot  (p1_awprot),
    .m_axi_awvalid (p1_awvalid),
    .m_axi_awready (p1_awready),
    .m_axi_wdata   (p1_wdata),
    .m_axi_wstrb   (p1_wstrb),
    .m_axi_wvalid  (p1_wvalid),
    .m_axi_wready  (p1_wready),
    .m_axi_bresp   (p1_bresp),
    .m_axi_bvalid  (p1_bvalid),
    .m_axi_bready  (p1_bready),
    .m_axi_araddr  (p1_araddr),
    .m_axi_arprot  (p1_arprot),
    .m_axi_arvalid (p1_arvalid),
    .m_axi_arready (p1_arready),
    .m_axi_rdata   (p1_rdata),
    .m_axi_rresp   (p1_rresp),
    .m_axi_rvalid  (p1_rvalid),
    .m_axi_rready  (p1_rready)
  );

  axi_crossbar #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_xbar (
    .aclk          (clk_axi),
    .aresetn       (rst_axi_n),
    .s0_axi_awaddr (p0_awaddr),
    .s0_axi_awprot (p0_awprot),
    .s0_axi_awvalid(p0_awvalid),
    .s0_axi_awready(p0_awready),
    .s0_axi_wdata  (p0_wdata),
    .s0_axi_wstrb  (p0_wstrb),
    .s0_axi_wvalid (p0_wvalid),
    .s0_axi_wready (p0_wready),
    .s0_axi_bresp  (p0_bresp),
    .s0_axi_bvalid (p0_bvalid),
    .s0_axi_bready (p0_bready),
    .s0_axi_araddr (p0_araddr),
    .s0_axi_arprot (p0_arprot),
    .s0_axi_arvalid(p0_arvalid),
    .s0_axi_arready(p0_arready),
    .s0_axi_rdata  (p0_rdata),
    .s0_axi_rresp  (p0_rresp),
    .s0_axi_rvalid (p0_rvalid),
    .s0_axi_rready (p0_rready),
    .s1_axi_awaddr (p1_awaddr),
    .s1_axi_awprot (p1_awprot),
    .s1_axi_awvalid(p1_awvalid),
    .s1_axi_awready(p1_awready),
    .s1_axi_wdata  (p1_wdata),
    .s1_axi_wstrb  (p1_wstrb),
    .s1_axi_wvalid (p1_wvalid),
    .s1_axi_wready (p1_wready),
    .s1_axi_bresp  (p1_bresp),
    .s1_axi_bvalid (p1_bvalid),
    .s1_axi_bready (p1_bready),
    .s1_axi_araddr (p1_araddr),
    .s1_axi_arprot (p1_arprot),
    .s1_axi_arvalid(p1_arvalid),
    .s1_axi_arready(p1_arready),
    .s1_axi_rdata  (p1_rdata),
    .s1_axi_rresp  (p1_rresp),
    .s1_axi_rvalid (p1_rvalid),
    .s1_axi_rready (p1_rready),
    .m0_axi_awaddr (x0_awaddr),
    .m0_axi_awprot (x0_awprot),
    .m0_axi_awvalid(x0_awvalid),
    .m0_axi_awready(x0_awready),
    .m0_axi_wdata  (x0_wdata),
    .m0_axi_wstrb  (x0_wstrb),
    .m0_axi_wvalid (x0_wvalid),
    .m0_axi_wready (x0_wready),
    .m0_axi_bresp  (x0_bresp),
    .m0_axi_bvalid (x0_bvalid),
    .m0_axi_bready (x0_bready),
    .m0_axi_araddr (x0_araddr),
    .m0_axi_arprot (x0_arprot),
    .m0_axi_arvalid(x0_arvalid),
    .m0_axi_arready(x0_arready),
    .m0_axi_rdata  (x0_rdata),
    .m0_axi_rresp  (x0_rresp),
    .m0_axi_rvalid (x0_rvalid),
    .m0_axi_rready (x0_rready),
    .m1_axi_awaddr (x1_awaddr),
    .m1_axi_awprot (x1_awprot),
    .m1_axi_awvalid(x1_awvalid),
    .m1_axi_awready(x1_awready),
    .m1_axi_wdata  (x1_wdata),
    .m1_axi_wstrb  (x1_wstrb),
    .m1_axi_wvalid (x1_wvalid),
    .m1_axi_wready (x1_wready),
    .m1_axi_bresp  (x1_bresp),
    .m1_axi_bvalid (x1_bvalid),
    .m1_axi_bready (x1_bready),
    .m1_axi_araddr (x1_araddr),
    .m1_axi_arprot (x1_arprot),
    .m1_axi_arvalid(x1_arvalid),
    .m1_axi_arready(x1_arready),
    .m1_axi_rdata  (x1_rdata),
    .m1_axi_rresp  (x1_rresp),
    .m1_axi_rvalid (x1_rvalid),
    .m1_axi_rready (x1_rready)
  );

  axi_register_slice #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_slice_csr (
    .aclk          (clk_axi),
    .aresetn       (rst_axi_n),
    .s_axi_awaddr  (x0_awaddr),
    .s_axi_awprot  (x0_awprot),
    .s_axi_awvalid (x0_awvalid),
    .s_axi_awready (x0_awready),
    .s_axi_wdata   (x0_wdata),
    .s_axi_wstrb   (x0_wstrb),
    .s_axi_wvalid  (x0_wvalid),
    .s_axi_wready  (x0_wready),
    .s_axi_bresp   (x0_bresp),
    .s_axi_bvalid  (x0_bvalid),
    .s_axi_bready  (x0_bready),
    .s_axi_araddr  (x0_araddr),
    .s_axi_arprot  (x0_arprot),
    .s_axi_arvalid (x0_arvalid),
    .s_axi_arready (x0_arready),
    .s_axi_rdata   (x0_rdata),
    .s_axi_rresp   (x0_rresp),
    .s_axi_rvalid  (x0_rvalid),
    .s_axi_rready  (x0_rready),
    .m_axi_awaddr  (m0_axi_awaddr),
    .m_axi_awprot  (m0_axi_awprot),
    .m_axi_awvalid (m0_axi_awvalid),
    .m_axi_awready (m0_axi_awready),
    .m_axi_wdata   (m0_axi_wdata),
    .m_axi_wstrb   (m0_axi_wstrb),
    .m_axi_wvalid  (m0_axi_wvalid),
    .m_axi_wready  (m0_axi_wready),
    .m_axi_bresp   (m0_axi_bresp),
    .m_axi_bvalid  (m0_axi_bvalid),
    .m_axi_bready  (m0_axi_bready),
    .m_axi_araddr  (m0_axi_araddr),
    .m_axi_arprot  (m0_axi_arprot),
    .m_axi_arvalid (m0_axi_arvalid),
    .m_axi_arready (m0_axi_arready),
    .m_axi_rdata   (m0_axi_rdata),
    .m_axi_rresp   (m0_axi_rresp),
    .m_axi_rvalid  (m0_axi_rvalid),
    .m_axi_rready  (m0_axi_rready)
  );

  axi_register_slice #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_slice_nand (
    .aclk          (clk_axi),
    .aresetn       (rst_axi_n),
    .s_axi_awaddr  (x1_awaddr),
    .s_axi_awprot  (x1_awprot),
    .s_axi_awvalid (x1_awvalid),
    .s_axi_awready (x1_awready),
    .s_axi_wdata   (x1_wdata),
    .s_axi_wstrb   (x1_wstrb),
    .s_axi_wvalid  (x1_wvalid),
    .s_axi_wready  (x1_wready),
    .s_axi_bresp   (x1_bresp),
    .s_axi_bvalid  (x1_bvalid),
    .s_axi_bready  (x1_bready),
    .s_axi_araddr  (x1_araddr),
    .s_axi_arprot  (x1_arprot),
    .s_axi_arvalid (x1_arvalid),
    .s_axi_arready (x1_arready),
    .s_axi_rdata   (x1_rdata),
    .s_axi_rresp   (x1_rresp),
    .s_axi_rvalid  (x1_rvalid),
    .s_axi_rready  (x1_rready),
    .m_axi_awaddr  (m1_axi_awaddr),
    .m_axi_awprot  (m1_axi_awprot),
    .m_axi_awvalid (m1_axi_awvalid),
    .m_axi_awready (m1_axi_awready),
    .m_axi_wdata   (m1_axi_wdata),
    .m_axi_wstrb   (m1_axi_wstrb),
    .m_axi_wvalid  (m1_axi_wvalid),
    .m_axi_wready  (m1_axi_wready),
    .m_axi_bresp   (m1_axi_bresp),
    .m_axi_bvalid  (m1_axi_bvalid),
    .m_axi_bready  (m1_axi_bready),
    .m_axi_araddr  (m1_axi_araddr),
    .m_axi_arprot  (m1_axi_arprot),
    .m_axi_arvalid (m1_axi_arvalid),
    .m_axi_arready (m1_axi_arready),
    .m_axi_rdata   (m1_axi_rdata),
    .m_axi_rresp   (m1_axi_rresp),
    .m_axi_rvalid  (m1_axi_rvalid),
    .m_axi_rready  (m1_axi_rready)
  );

  // Sideband the lite fabric does not carry. Read so the bits stay live.
  wire _unused_sideband = &{1'b0,
    br_awsize, br_awburst, br_awlock, br_awcache, br_wlast,
    br_arsize, br_arburst, br_arlock, br_arcache,
    retire_hit, retire_addr, oldest_addr
  };

endmodule : nand_sol_subsystem_top

`default_nettype wire
