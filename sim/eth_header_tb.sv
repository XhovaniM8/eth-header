// eth_header_tb.sv
//
// Self-checking testbench for eth_header: drives payloads of a few sizes
// (short single-beat, exact-borrow-boundary, and multi-beat) through the
// DUT and reconstructs the output byte stream from tdata/tkeep/tlast to
// compare against the expected header ++ payload byte sequence. Both AXI4-
// Stream sides are handshake-aware (tvalid/tready), and one run exercises
// random backpressure on data_out_tready to check the FSM holds up when
// the sink stalls mid-frame.

`timescale 1ns/1ps

module eth_header_tb;

  logic clk = 1'b0;
  logic rst;

  logic [47:0] dst_mac  = 48'h00_11_22_33_44_55;
  logic [47:0] src_mac  = 48'hAA_BB_CC_DD_EE_FF;
  logic [15:0] eth_type = 16'h0800;

  logic [63:0] data_in_tdata;
  logic        data_in_tvalid;
  logic        data_in_tready;
  logic        data_in_tlast;
  logic [7:0]  data_in_tkeep;

  logic [63:0] data_out_tdata;
  logic        data_out_tvalid;
  logic        data_out_tready;
  logic        data_out_tlast;
  logic [7:0]  data_out_tkeep;

  eth_header dut (.*);

  always #5 clk = ~clk;

  int errors_total = 0;
  bit stall_enable  = 1'b0;

  // Drives the downstream-ready signal: always ready, or randomly stalling
  // when a backpressure test is active.
  always @(posedge clk) begin
    if (rst)               data_out_tready <= 1'b1;
    else if (!stall_enable) data_out_tready <= 1'b1;
    else                    data_out_tready <= $urandom_range(0, 1);
  end

  // Drives one AXI4-Stream beat per iteration and waits for the DUT to
  // assert data_in_tready before moving to the next beat, per spec.
  // Signals are driven with nonblocking assignment so DUT always_ff blocks
  // triggered by the same posedge always sample the beat that was stable
  // going into that edge, never a value this task updates in that same
  // edge (a classic testbench/DUT race on shared clock edges).
  task automatic send_packet(input byte payload[]);
    int idx, n;
    logic [63:0] beat_data;
    logic [7:0]  beat_keep;
    bit          beat_last;
    idx = 0;
    while (idx < payload.size()) begin
      n = (payload.size() - idx) > 8 ? 8 : (payload.size() - idx);
      beat_data = '0;
      beat_keep = '0;
      for (int b = 0; b < n; b++) begin
        beat_data[b*8 +: 8] = payload[idx+b];
        beat_keep[b]        = 1'b1;
      end
      beat_last = (idx + n == payload.size());
      data_in_tdata  <= beat_data;
      data_in_tkeep  <= beat_keep;
      data_in_tvalid <= 1'b1;
      data_in_tlast  <= beat_last;
      do begin
        @(posedge clk);
      end while (!data_in_tready);
      idx += n;
    end
    data_in_tvalid <= 1'b0;
    data_in_tlast  <= 1'b0;
    data_in_tdata  <= '0;
    data_in_tkeep  <= '0;
  endtask

  task automatic collect_packet(output byte actual[]);
    byte q[$];
    bit  done;
    q.delete();
    done = 1'b0;
    while (!done) begin
      @(posedge clk);
      if (data_out_tvalid && data_out_tready) begin
        for (int b = 0; b < 8; b++)
          if (data_out_tkeep[b]) q.push_back(data_out_tdata[b*8 +: 8]);
        if (data_out_tlast) done = 1'b1;
      end
    end
    actual = q;
  endtask

  function automatic void build_payload(input int len, output byte p[]);
    p = new[len];
    for (int i = 0; i < len; i++) p[i] = i[7:0];
  endfunction

  function automatic void build_expected(input byte payload[], output byte exp[]);
    byte q[$];
    q = '{dst_mac[47:40], dst_mac[39:32], dst_mac[31:24],
          dst_mac[23:16], dst_mac[15:8],  dst_mac[7:0],
          src_mac[47:40], src_mac[39:32], src_mac[31:24],
          src_mac[23:16], src_mac[15:8],  src_mac[7:0],
          eth_type[15:8], eth_type[7:0]};
    foreach (payload[i]) q.push_back(payload[i]);
    exp = q;
  endfunction

  task automatic run_test(string name, int payload_len);
    byte payload[], expected[], actual[];
    int  mismatches;

    build_payload(payload_len, payload);
    build_expected(payload, expected);

    fork
      send_packet(payload);
      collect_packet(actual);
    join

    mismatches = 0;
    if (actual.size() != expected.size()) begin
      $display("[%s] FAIL: length mismatch exp=%0d got=%0d", name, expected.size(), actual.size());
      mismatches++;
    end else begin
      for (int i = 0; i < expected.size(); i++) begin
        if (actual[i] !== expected[i]) begin
          $display("[%s] FAIL byte %0d: exp=%02h got=%02h", name, i, expected[i], actual[i]);
          mismatches++;
        end
      end
    end

    if (mismatches == 0) $display("[%s] PASS (%0d bytes)", name, expected.size());
    errors_total += mismatches;

    repeat (2) @(posedge clk);
  endtask

  initial begin
    rst             = 1'b1;
    data_in_tvalid  = 1'b0;
    data_in_tlast   = 1'b0;
    data_in_tdata   = '0;
    data_in_tkeep   = '0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);

    run_test("1-byte payload",  1);   // ends inside the borrowed bytes of hdr_word2
    run_test("2-byte payload",  2);   // exactly fills the borrowed bytes of hdr_word2
    run_test("3-byte payload",  3);   // needs one forward_data flush beat
    run_test("8-byte payload",  8);   // one full forward_data beat, then flush
    run_test("20-byte payload", 20);  // multiple input beats, back-to-back

    stall_enable = 1'b1;
    run_test("20-byte payload, random backpressure", 20);
    stall_enable = 1'b0;

    if (errors_total == 0) $display("ALL TESTS PASSED");
    else                   $display("%0d TOTAL MISMATCHES", errors_total);

    $finish;
  end

endmodule
