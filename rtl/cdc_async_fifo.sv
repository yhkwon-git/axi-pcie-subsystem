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
// rd_empty is low. rd_en pops that word. The word is a flop output: each
// rd_clk advances one mux2 of the binary read tree, and the tag has to match
// rd_bin before the word is shown. A pop or a newly synchronized write
// pointer makes rd_empty high until that tree finishes the new address.
// A location is written on wr_clk and is not visible to the reader until the
// Gray write pointer has landed in the second read-domain synchronizer flop,
// the pipe has been flushed, and the tag has caught the read pointer.
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

  // +1 with the carry prefix taken only from the current pointer flops.
  // wr_fire/rd_fire then AND into every bit in parallel, instead of rippling
  // through the prefix. The ss liberty makes that ripple a multi-ns arc.
  function automatic logic [PTR_W-1:0] bin_add_fire(
    input logic [PTR_W-1:0] bin,
    input logic             fire
  );
    logic [PTR_W-1:0] prefix;
    logic [PTR_W-1:0] sum;
    begin
      prefix[0] = 1'b1;
      for (int i = 1; i < PTR_W; i++) begin
        prefix[i] = prefix[i - 1] & bin[i - 1];
      end
      for (int i = 0; i < PTR_W; i++) begin
        sum[i] = bin[i] ^ (fire & prefix[i]);
      end
      return sum;
    end
  endfunction

  logic [WIDTH-1:0] mem [0:DEPTH-1];

  logic [PTR_W-1:0] wr_bin;
  logic [PTR_W-1:0] wr_gray;
  logic             wr_full_q;
  logic             wr_pend_q;
  logic [ADDR_W-1:0] wr_addr_q;
  logic [WIDTH-1:0] wr_data_q;
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
  wire              rd_ready;
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
  assign wr_bin_next  = bin_add_fire(wr_bin, wr_fire);
  assign wr_gray_next = bin2gray(wr_bin_next);
  // Next Gray write pointer meets the synchronized read pointer with the two
  // MSBs inverted exactly when this write would occupy the last free slot.
  assign wr_full_next = (wr_gray_next == {~rd_gray_in_wr[PTR_W-1:PTR_W-2],
                                          rd_gray_in_wr[PTR_W-3:0]});

  // A pop is ignored until the pipelined word is visible.
  assign rd_fire       = rd_en & rd_ready;
  assign rd_bin_next   = bin_add_fire(rd_bin, rd_fire);
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

  // The pointer advances on the accepting clock. The memory write uses the
  // address and data captured that cycle, one wr_clk later. The reader sees
  // the new slot only after cdc_sync_2ff, which is two destination clocks,
  // so the word is in mem before that pointer is visible.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_pend_q <= 1'b0;
    end else begin
      wr_pend_q <= wr_fire;
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_fire) begin
      wr_addr_q <= wr_bin[ADDR_W-1:0];
      wr_data_q <= wr_data;
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_pend_q) begin
      mem[wr_addr_q] <= wr_data_q;
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

  // One mux2 per rd_clk. mux4/or4 fall delays in this ss liberty stay above
  // 2 ns at the fastest table corner, so a 16:1 read in one cycle does not fit
  // the 8 ns read clock after clock-to-q and setup. The tag records the
  // address that entered with the data. A change in the synchronized write
  // pointer flushes the tag: the slot was just written, and the previous
  // pipe contents are the value from before that write.
  localparam int LVLS = ADDR_W;

  logic [WIDTH-1:0]  step_q [0:LVLS-1][0:(DEPTH/2)-1];
  logic [ADDR_W-1:0] tag_q  [0:LVLS-1];
  logic [LVLS-1:0]   tag_v;
  logic [PTR_W-1:0]  wr_gray_seen;

  genvar lvl, ix;
  generate
    for (lvl = 0; lvl < LVLS; lvl = lvl + 1) begin : g_rd
      localparam int NW = DEPTH >> (lvl + 1);
      for (ix = 0; ix < NW; ix = ix + 1) begin : g_w
        if (lvl == 0) begin : g_mem
          always_ff @(posedge rd_clk) begin
            if (rd_bin[0]) begin
              step_q[lvl][ix] <= mem[(ix << 1) + 1];
            end else begin
              step_q[lvl][ix] <= mem[(ix << 1) + 0];
            end
          end
        end else begin : g_mux
          always_ff @(posedge rd_clk) begin
            if (tag_q[lvl - 1][lvl]) begin
              step_q[lvl][ix] <= step_q[lvl - 1][(ix << 1) + 1];
            end else begin
              step_q[lvl][ix] <= step_q[lvl - 1][(ix << 1) + 0];
            end
          end
        end
      end
    end
  endgenerate

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      wr_gray_seen <= '0;
      tag_v        <= '0;
      for (int i = 0; i < LVLS; i++) begin
        tag_q[i] <= '0;
      end
    end else if (wr_gray_in_rd != wr_gray_seen) begin
      wr_gray_seen <= wr_gray_in_rd;
      tag_v        <= '0;
    end else begin
      wr_gray_seen <= wr_gray_in_rd;
      tag_q[0]     <= rd_bin[ADDR_W-1:0];
      tag_v[0]     <= 1'b1;
      for (int i = 1; i < LVLS; i++) begin
        tag_q[i] <= tag_q[i - 1];
        tag_v[i] <= tag_v[i - 1];
      end
    end
  end

  assign rd_ready = ~rd_empty_q && tag_v[LVLS-1] &&
                    (tag_q[LVLS-1] == rd_bin[ADDR_W-1:0]);
  assign wr_full  = wr_full_q;
  assign rd_empty = ~rd_ready;
  assign rd_data  = step_q[LVLS-1][0];

endmodule : cdc_async_fifo

`default_nettype wire
