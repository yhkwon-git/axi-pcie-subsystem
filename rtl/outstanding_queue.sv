`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// outstanding_queue
//
// Tracks AXI read IDs while a slow NAND read is still in flight.
//
// alloc_* fires on the AR handshake and occupies one slot with that ID and
// address. alloc_ready is low when every slot is full or that ID is already
// in flight, so the caller can hold ARREADY down and refuse the new read.
// retire_* fires on the R handshake (RLAST, one beat on the lite path) and
// frees the slot whose ID matches. Completions may arrive in any ID order.
// oldest_* is the oldest allocated slot still valid, which is the beat the
// in-order AXI4-Lite fabric is allowed to complete next.
//
// clk is the AXI clock. rst_n is asynchronously asserted and synchronously
// deasserted in that clock.
// -----------------------------------------------------------------------------

module outstanding_queue #(
  parameter int DEPTH   = 4,
  parameter int ID_W    = 4,
  parameter int ADDR_W  = 32,
  parameter int COUNT_W = $clog2(DEPTH + 1)
) (
  input  wire                      clk,
  input  wire                      rst_n,

  input  wire                      alloc_valid,
  output wire                      alloc_ready,
  input  wire [ID_W-1:0]           alloc_id,
  input  wire [ADDR_W-1:0]         alloc_addr,

  input  wire                      retire_valid,
  input  wire [ID_W-1:0]           retire_id,
  output wire                      retire_hit,
  output wire [ADDR_W-1:0]         retire_addr,

  output wire                      empty,
  output wire                      full,
  output wire [COUNT_W-1:0]        count,
  output wire                      oldest_valid,
  output wire [ID_W-1:0]           oldest_id,
  output wire [ADDR_W-1:0]         oldest_addr
);

  localparam int SLOT_W = $clog2(DEPTH);

  generate
    if ((DEPTH < 2) || (DEPTH > 16)) begin : g_depth
      initial $error("outstanding_queue: DEPTH must be in 2..16");
    end
    if ((ID_W < 1) || (ADDR_W < 1) || (COUNT_W < 1)) begin : g_width
      initial $error("outstanding_queue: ID_W, ADDR_W, and COUNT_W must be >= 1");
    end
  endgenerate

  logic [DEPTH-1:0]  valid_q;
  logic [DEPTH-1:0]  valid_next;
  logic [ID_W-1:0]   id_mem   [0:DEPTH-1];
  logic [ADDR_W-1:0] addr_mem [0:DEPTH-1];
  logic [15:0]       age_mem  [0:DEPTH-1];
  logic [15:0]       age_now;

  logic              id_busy;
  logic              any_free;
  logic [SLOT_W-1:0] free_slot;
  logic [15:0]       oldest_age;
  logic [COUNT_W-1:0] count_c;
  logic              oldest_valid_c;
  logic [ID_W-1:0]   oldest_id_c;
  logic [ADDR_W-1:0] oldest_addr_c;
  logic              retire_hit_c;
  logic [ADDR_W-1:0] retire_addr_c;

  always_comb begin
    id_busy   = 1'b0;
    any_free  = 1'b0;
    free_slot = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && (id_mem[i] == alloc_id)) begin
        id_busy = 1'b1;
      end
      if (!valid_q[i] && !any_free) begin
        any_free  = 1'b1;
        free_slot = SLOT_W'(i);
      end
    end
  end

  assign alloc_ready = any_free & ~id_busy;
  assign full        = ~any_free;
  assign empty       = ~|valid_q;

  always_comb begin
    count_c = '0;
    for (int i = 0; i < DEPTH; i++) begin
      count_c = count_c + COUNT_W'(valid_q[i]);
    end
  end
  assign count = count_c;

  always_comb begin
    oldest_valid_c = 1'b0;
    oldest_id_c    = '0;
    oldest_addr_c  = '0;
    oldest_age     = '1;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && (!oldest_valid_c || (age_mem[i] < oldest_age))) begin
        oldest_valid_c = 1'b1;
        oldest_age     = age_mem[i];
        oldest_id_c    = id_mem[i];
        oldest_addr_c  = addr_mem[i];
      end
    end
  end

  always_comb begin
    retire_hit_c  = 1'b0;
    retire_addr_c = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && (id_mem[i] == retire_id)) begin
        retire_hit_c  = 1'b1;
        retire_addr_c = addr_mem[i];
      end
    end
  end

  assign oldest_valid = oldest_valid_c;
  assign oldest_id    = oldest_id_c;
  assign oldest_addr  = oldest_addr_c;
  assign retire_hit   = retire_hit_c;
  assign retire_addr  = retire_addr_c;

  always_comb begin
    valid_next = valid_q;
    if (retire_valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (valid_q[i] && (id_mem[i] == retire_id)) begin
          valid_next[i] = 1'b0;
        end
      end
    end
    if (alloc_valid && alloc_ready) begin
      valid_next[free_slot] = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0;
      age_now <= '0;
      for (int i = 0; i < DEPTH; i++) begin
        id_mem[i]   <= '0;
        addr_mem[i] <= '0;
        age_mem[i]  <= '0;
      end
    end else begin
      valid_q <= valid_next;
      if (alloc_valid && alloc_ready) begin
        id_mem[free_slot]   <= alloc_id;
        addr_mem[free_slot] <= alloc_addr;
        age_mem[free_slot]  <= age_now;
        age_now             <= age_now + 16'd1;
      end
    end
  end

endmodule : outstanding_queue

`default_nettype wire
