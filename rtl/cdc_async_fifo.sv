`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// cdc_sync_2ff
//
// Two flip-flops in the destination clock. This is the only path a pointer
// takes into the other domain. The source must be Gray coded so that at most
// one bit changes on any source clock; a multi-bit binary pointer would be
// sampled mid-transition.
//
// rst_n is asynchronously asserted and must be synchronously deasserted in
// `clk`'s domain. Both stages reset to 0 so an empty FIFO (pointers at 0)
// stays empty through reset release.
// -----------------------------------------------------------------------------

module cdc_sync_2ff #(
  parameter int WIDTH = 4
) (
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire [WIDTH-1:0]      din_async,
  output wire [WIDTH-1:0]      dout
);

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] stage1;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] stage2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage1 <= '0;
      stage2 <= '0;
    end else begin
      stage1 <= din_async;
      stage2 <= stage1;
    end
  end

  assign dout = stage2;

endmodule : cdc_sync_2ff


// -----------------------------------------------------------------------------
// cdc_async_fifo
//
// Dual-clock FIFO for the PCIe-clock to AXI-clock hop.
//
// Pointers are binary inside their own clock and Gray on the way across.
// Each direction uses cdc_sync_2ff. Full is decided in the write clock from
// the write pointer and the synchronized read pointer; empty is decided in
// the read clock from the read pointer and the synchronized write pointer.
// The extra pointer bit distinguishes full from empty after the address wraps.
//
// rd_data is the word at the current read address and is valid while
// rd_empty is low. rd_en pops that word. A location is written on wr_clk and
// is not visible to the reader until the Gray write pointer has landed in the
// second read-domain synchronizer flop and the empty flag has been registered,
// which is at least two rising edges of rd_clk after the write.
//
// DEPTH is a power of two and at least 4. wr_rst_n / rd_rst_n must both be
// asserted before use and each deasserted synchronously to its own clock.
// -----------------------------------------------------------------------------

module cdc_async_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 16
) (
  input  wire                  wr_clk,
  input  wire                  wr_rst_n,
  input  wire                  wr_en,
  input  wire [WIDTH-1:0]      wr_data,
  output wire                  wr_full,

  input  wire                  rd_clk,
  input  wire                  rd_rst_n,
  input  wire                  rd_en,
  output wire [WIDTH-1:0]      rd_data,
  output wire                  rd_empty
);

  localparam int ADDR_W = $clog2(DEPTH);
  localparam int PTR_W  = ADDR_W + 1;

  generate
    if ((WIDTH < 1) || (DEPTH < 4) || (DEPTH != (1 << ADDR_W))) begin : g_illegal
      initial $error("cdc_async_fifo: WIDTH >= 1 and DEPTH must be a power of two >= 4");
    end
  endgenerate

  function automatic logic [PTR_W-1:0] bin2gray(input logic [PTR_W-1:0] bin);
    return bin ^ (bin >> 1);
  endfunction

  logic [WIDTH-1:0] mem [0:DEPTH-1];

  logic [PTR_W-1:0] wr_bin;
  logic [PTR_W-1:0] wr_gray;
  logic             wr_full_q;
  logic [PTR_W-1:0] rd_bin;
  logic [PTR_W-1:0] rd_gray;
  logic             rd_empty_q;

  wire [PTR_W-1:0] rd_gray_in_wr;
  wire [PTR_W-1:0] wr_gray_in_rd;

  wire              wr_fire;
  wire [PTR_W-1:0]  wr_bin_next;
  wire [PTR_W-1:0]  wr_gray_next;
  wire              wr_full_next;
  wire              rd_fire;
  wire [PTR_W-1:0]  rd_bin_next;
  wire [PTR_W-1:0]  rd_gray_next;
  wire              rd_empty_next;

  // Read pointer as seen by the writer, and write pointer as seen by the reader.
  cdc_sync_2ff #(.WIDTH(PTR_W)) u_sync_rd_to_wr (
    .clk       (wr_clk),
    .rst_n     (wr_rst_n),
    .din_async (rd_gray),
    .dout      (rd_gray_in_wr)
  );

  cdc_sync_2ff #(.WIDTH(PTR_W)) u_sync_wr_to_rd (
    .clk       (rd_clk),
    .rst_n     (rd_rst_n),
    .din_async (wr_gray),
    .dout      (wr_gray_in_rd)
  );

  assign wr_fire      = wr_en & ~wr_full_q;
  assign wr_bin_next  = wr_bin + {{(PTR_W-1){1'b0}}, wr_fire};
  assign wr_gray_next = bin2gray(wr_bin_next);
  // Next Gray write pointer meets the synchronized read pointer with the two
  // MSBs inverted exactly when this write would occupy the last free slot.
  assign wr_full_next = (wr_gray_next == {~rd_gray_in_wr[PTR_W-1:PTR_W-2],
                                          rd_gray_in_wr[PTR_W-3:0]});

  assign rd_fire       = rd_en & ~rd_empty_q;
  assign rd_bin_next   = rd_bin + {{(PTR_W-1){1'b0}}, rd_fire};
  assign rd_gray_next  = bin2gray(rd_bin_next);
  assign rd_empty_next = (rd_gray_next == wr_gray_in_rd);

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_bin    <= '0;
      wr_gray   <= '0;
      wr_full_q <= 1'b0;
    end else begin
      wr_bin    <= wr_bin_next;
      wr_gray   <= wr_gray_next;
      wr_full_q <= wr_full_next;
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_fire) begin
      mem[wr_bin[ADDR_W-1:0]] <= wr_data;
    end
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_bin     <= '0;
      rd_gray    <= '0;
      rd_empty_q <= 1'b1;
    end else begin
      rd_bin     <= rd_bin_next;
      rd_gray    <= rd_gray_next;
      rd_empty_q <= rd_empty_next;
    end
  end

  assign wr_full  = wr_full_q;
  assign rd_empty = rd_empty_q;
  assign rd_data  = mem[rd_bin[ADDR_W-1:0]];

endmodule : cdc_async_fifo

`default_nettype wire
