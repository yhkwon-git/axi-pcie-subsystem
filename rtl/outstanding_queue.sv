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
// Order is a head/tail list. oldest_id is the head slot's ID. The subsystem
// pops that head with retire_head, which is a 2-bit mux and does not feed
// oldest_id back into the same cycle. retire_valid/retire_id still unlink an
// arbitrary slot for a caller that completes out of order.
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
  input  wire                      retire_head,
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

  logic [DEPTH-1:0]   valid_q;
  logic [DEPTH-1:0]   valid_next;
  logic [ID_W-1:0]    id_mem   [0:DEPTH-1];
  logic [ADDR_W-1:0]  addr_mem [0:DEPTH-1];
  logic [SLOT_W-1:0]  head_q, tail_q, head_next, tail_next;
  logic [SLOT_W-1:0]  nxt_q    [0:DEPTH-1];
  logic [SLOT_W-1:0]  nxt_next [0:DEPTH-1];

  logic               id_busy;
  logic               any_free;
  logic [SLOT_W-1:0]  free_slot;
  logic [COUNT_W-1:0] count_c;
  logic               retire_hit_c;
  logic [ADDR_W-1:0]  retire_addr_c;
  logic [SLOT_W-1:0]  retire_slot;
  logic [SLOT_W-1:0]  pred_slot;
  logic               pred_found;
  logic               sole;

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
    retire_hit_c  = 1'b0;
    retire_addr_c = '0;
    retire_slot   = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && (id_mem[i] == retire_id)) begin
        retire_hit_c  = 1'b1;
        retire_addr_c = addr_mem[i];
        retire_slot   = SLOT_W'(i);
      end
    end
  end

  assign retire_hit  = retire_hit_c;
  assign retire_addr = retire_addr_c;

  // head_q is the oldest occupied slot. It is unused while empty.
  assign oldest_valid = valid_q[head_q];
  assign oldest_id    = id_mem[head_q];
  assign oldest_addr  = addr_mem[head_q];

  always_comb begin
    pred_slot  = '0;
    pred_found = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (valid_q[i] && (nxt_q[i] == retire_slot) && (SLOT_W'(i) != retire_slot)) begin
        pred_slot  = SLOT_W'(i);
        pred_found = 1'b1;
      end
    end
  end

  assign sole = valid_q[head_q] && (head_q == tail_q);

  always_comb begin
    valid_next = valid_q;
    head_next  = head_q;
    tail_next  = tail_q;
    for (int i = 0; i < DEPTH; i++) begin
      nxt_next[i] = nxt_q[i];
    end
    if (retire_head && valid_q[head_q]) begin
      valid_next[head_q] = 1'b0;
      if (head_q != tail_q) begin
        head_next = nxt_q[head_q];
      end
    end
    if (retire_valid && retire_hit_c) begin
      valid_next[retire_slot] = 1'b0;
      if (retire_slot == head_q) begin
        head_next = nxt_q[head_q];
      end else if (pred_found) begin
        nxt_next[pred_slot] = nxt_q[retire_slot];
      end
      if ((retire_slot == tail_q) && (retire_slot != head_q) && pred_found) begin
        tail_next = pred_slot;
      end
    end
    if (alloc_valid && alloc_ready) begin
      valid_next[free_slot] = 1'b1;
      if ((~|valid_q) ||
          (retire_head && valid_q[head_q] && sole) ||
          (retire_valid && retire_hit_c && sole)) begin
        head_next = free_slot;
        tail_next = free_slot;
      end else begin
        nxt_next[tail_next] = free_slot;
        tail_next           = free_slot;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0;
      head_q  <= '0;
      tail_q  <= '0;
      for (int i = 0; i < DEPTH; i++) begin
        id_mem[i]   <= '0;
        addr_mem[i] <= '0;
        nxt_q[i]    <= '0;
      end
    end else begin
      valid_q <= valid_next;
      head_q  <= head_next;
      tail_q  <= tail_next;
      for (int i = 0; i < DEPTH; i++) begin
        nxt_q[i] <= nxt_next[i];
      end
      if (alloc_valid && alloc_ready) begin
        id_mem[free_slot]   <= alloc_id;
        addr_mem[free_slot] <= alloc_addr;
      end
    end
  end

endmodule : outstanding_queue

`default_nettype wire
