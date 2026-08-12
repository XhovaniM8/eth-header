# eth_header

Small AXI4-Stream SystemVerilog block that prepends a fixed Ethernet II
header (destination MAC, source MAC, EtherType) onto a 64-bit AXI4-Stream
data path.

This is a personal, from-scratch SystemVerilog implementation written for
practice / portfolio purposes, targeting Xilinx Vivado (non-project Tcl
flow). It has no affiliation with, and shares no source with, any employer
or job-application exercise.

## Interface

`rtl/eth_header.sv`, module `eth_header`:

| Port | Width | Description |
|---|---|---|
| `clk` | 1 | Clock |
| `rst` | 1 | Synchronous, active-high reset |
| `dst_mac` | 48 | Destination MAC, sampled at the start of each frame |
| `src_mac` | 48 | Source MAC, sampled at the start of each frame |
| `eth_type` | 16 | EtherType, sampled at the start of each frame |
| `data_in_t*` | AXI4-Stream slave | 64-bit payload input (`tdata`/`tvalid`/`tready`/`tlast`/`tkeep`) |
| `data_out_t*` | AXI4-Stream master | 64-bit output: header ++ payload (`tdata`/`tvalid`/`tready`/`tlast`/`tkeep`) |

Both sides implement full `tvalid`/`tready` handshaking. `data_in_tready`
deasserts while a header beat is draining (`hdr_word1`/`hdr_word2`), so a
spec-compliant upstream source just holds its next beat stable until the
module is ready for it — that's what lets back-to-back multi-beat frames
work despite the 2-beat header-emission bubble at the start of each frame.

## Design

A 4-state FSM (`idle -> hdr_word1 -> hdr_word2 -> forward_data`) emits the
14-byte header as two 8-byte beats, borrowing the first 2 payload bytes
into the second header beat. Since 14 isn't a multiple of 8, the rest of
the payload stream is then continuously re-aligned by carrying 6 leftover
bytes from each input beat into the next output beat, until the source's
`tlast`, at which point any still-unshipped leftover bytes are flushed in
one final beat.

## Directory layout

- `rtl/` — synthesizable SystemVerilog sources
- `sim/` — self-checking testbench (byte-exact frame comparison)
- `constraints/` — XDC (clock definition; add board pin constraints as needed)
- `scripts/build.tcl` — non-project Vivado synthesis flow
- `scripts/sim.sh` — non-project xsim simulation flow (xvlog/xelab/xsim)

## Usage

Simulate:

    ./scripts/sim.sh

Synthesize (edit the `part` variable in `scripts/build.tcl` first to match
your target device/board):

    vivado -mode batch -source scripts/build.tcl
