// eth_header.sv
//
// Prepends a fixed Ethernet II header (dst MAC, src MAC, EtherType) onto a
// 64-bit AXI4-Stream payload. The header is 14 bytes, which is not a
// multiple of the 8-byte bus width, so the header's tail (last 6 bytes)
// shares a beat with the first 2 bytes of payload, and every beat after
// that carries 6 "leftover" payload bytes from the previous input beat
// alongside 2 new bytes from the current one until tlast, at which point
// any still-unshipped leftover bytes are flushed in one final beat.
//
// Full AXI4-Stream handshaking (tvalid/tready) on both sides: data_in_tready
// deasserts while a header beat is being drained (hdr_word1/hdr_word2), so a
// compliant source holds its beat stable until the module is ready for it,
// per the AXI4-Stream spec. That's what makes back-to-back multi-beat
// frames work correctly despite the 2-beat header-emission bubble.

`timescale 1ns/1ps

module eth_header (
    input  logic        clk,
    input  logic        rst,          // synchronous, active-high

    // Header fields, sampled at the start of each frame (idle -> hdr_word1)
    input  logic [47:0] dst_mac,
    input  logic [47:0] src_mac,
    input  logic [15:0] eth_type,

    // AXI4-Stream slave: payload in
    input  logic [63:0] data_in_tdata,
    input  logic        data_in_tvalid,
    output logic        data_in_tready,
    input  logic        data_in_tlast,
    input  logic [7:0]  data_in_tkeep,

    // AXI4-Stream master: header ++ payload out
    output logic [63:0] data_out_tdata,
    output logic        data_out_tvalid,
    input  logic        data_out_tready,
    output logic        data_out_tlast,
    output logic [7:0]  data_out_tkeep
);

  localparam int TDATA_BYTES    = 8;
  localparam int HDR_BYTES      = 14;                        // 6 + 6 + 2
  localparam int HDR_TAIL_BYTES = HDR_BYTES - TDATA_BYTES;    // 6: header bytes in beat 2
  localparam int BORROW_BYTES   = TDATA_BYTES - HDR_TAIL_BYTES; // 2: payload bytes borrowed into beat 2

  typedef enum logic [1:0] {
    IDLE,
    HDR_WORD1,
    HDR_WORD2,
    FORWARD_DATA
  } state_t;

  state_t state, next_state;

  // Frame-start snapshot of the header fields
  logic [47:0] dst_mac_q, src_mac_q;
  logic [15:0] eth_type_q;

  // First input beat of the frame, captured in IDLE, consumed in HDR_WORD2
  logic [63:0] captured_data;
  logic [7:0]  captured_keep;
  logic        captured_last;

  // Steady-state carry: HDR_TAIL_BYTES worth of payload not yet shipped
  logic [8*HDR_TAIL_BYTES-1:0] saved_data;
  logic [HDR_TAIL_BYTES-1:0]   saved_keep;
  logic                        saved_last;

  function automatic logic [63:0] make_hdr_word1(logic [47:0] dm, logic [47:0] sm);
    // bytes 0..5 = dst_mac, bytes 6..7 = top 2 bytes of src_mac
    return {sm[39:32], sm[47:40], dm[7:0], dm[15:8], dm[23:16], dm[31:24], dm[39:32], dm[47:40]};
  endfunction

  function automatic logic [8*HDR_TAIL_BYTES-1:0] make_hdr_tail(logic [47:0] sm, logic [15:0] et);
    // bytes 8..13 = remaining 4 bytes of src_mac + eth_type
    return {et[7:0], et[15:8], sm[7:0], sm[15:8], sm[23:16], sm[31:24]};
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state         <= IDLE;
      dst_mac_q     <= '0;
      src_mac_q     <= '0;
      eth_type_q    <= '0;
      captured_data <= '0;
      captured_keep <= '0;
      captured_last <= 1'b0;
      saved_data    <= '0;
      saved_keep    <= '0;
      saved_last    <= 1'b0;
    end else begin
      state <= next_state;

      unique case (state)
        IDLE: begin
          if (data_in_tvalid && data_in_tready) begin
            dst_mac_q     <= dst_mac;
            src_mac_q     <= src_mac;
            eth_type_q    <= eth_type;
            captured_data <= data_in_tdata;
            captured_keep <= data_in_tkeep;
            captured_last <= data_in_tlast;
          end
        end

        HDR_WORD2: begin
          if (data_out_tready) begin
            saved_data <= captured_data[63:16];
            saved_keep <= captured_keep[7:2];
            saved_last <= captured_last;
          end
        end

        FORWARD_DATA: begin
          if (!saved_last && data_in_tvalid && data_out_tready) begin
            saved_data <= data_in_tdata[63:16];
            saved_keep <= data_in_tkeep[7:2];
            saved_last <= data_in_tlast;
          end
        end

        default: ;
      endcase
    end
  end

  always_comb begin
    next_state      = state;
    data_in_tready  = 1'b0;
    data_out_tvalid = 1'b0;
    data_out_tdata  = '0;
    data_out_tkeep  = '0;
    data_out_tlast  = 1'b0;

    unique case (state)
      IDLE: begin
        data_in_tready = 1'b1;
        if (data_in_tvalid) next_state = HDR_WORD1;
      end

      HDR_WORD1: begin
        data_out_tvalid = 1'b1;
        data_out_tdata  = make_hdr_word1(dst_mac_q, src_mac_q);
        data_out_tkeep  = 8'hFF;
        data_out_tlast  = 1'b0; // header tail always follows
        if (data_out_tready) next_state = HDR_WORD2;
      end

      HDR_WORD2: begin
        data_out_tvalid = 1'b1;
        data_out_tdata  = {captured_data[8*BORROW_BYTES-1:0], make_hdr_tail(src_mac_q, eth_type_q)};
        data_out_tkeep  = {captured_keep[BORROW_BYTES-1:0], {HDR_TAIL_BYTES{1'b1}}};
        if (captured_last && (captured_keep[7:BORROW_BYTES] == '0)) begin
          data_out_tlast = 1'b1;
          if (data_out_tready) next_state = IDLE;
        end else begin
          data_out_tlast = 1'b0;
          if (data_out_tready) next_state = FORWARD_DATA;
        end
      end

      FORWARD_DATA: begin
        if (saved_last) begin
          // No further input beats are coming: flush the carried tail.
          data_out_tvalid = 1'b1;
          data_out_tdata  = {{8 * BORROW_BYTES{1'b0}}, saved_data};
          data_out_tkeep  = {{BORROW_BYTES{1'b0}}, saved_keep};
          data_out_tlast  = 1'b1;
          if (data_out_tready) next_state = IDLE;
        end else begin
          // Combinational merge of the carried tail with a fresh input
          // beat: one output beat requires exactly one input beat here,
          // so tready/tvalid tie straight through.
          data_in_tready  = data_out_tready;
          data_out_tvalid = data_in_tvalid;
          data_out_tdata  = {data_in_tdata[8*BORROW_BYTES-1:0], saved_data};
          data_out_tkeep  = {data_in_tkeep[BORROW_BYTES-1:0], saved_keep};
          data_out_tlast  = data_in_tvalid && data_in_tlast && (data_in_tkeep[7:BORROW_BYTES] == '0);
          if (data_in_tvalid && data_out_tready) begin
            next_state = (data_in_tlast && (data_in_tkeep[7:BORROW_BYTES] == '0)) ? IDLE : FORWARD_DATA;
          end
        end
      end

      default: next_state = IDLE;
    endcase
  end

endmodule
