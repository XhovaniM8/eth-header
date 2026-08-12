#!/usr/bin/env bash
# Non-project xsim flow: compile, elaborate, and run the eth_header testbench.
# Usage: ./scripts/sim.sh   (requires Vivado's xvlog/xelab/xsim on PATH)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

xvlog -sv rtl/eth_header.sv sim/eth_header_tb.sv
xelab -debug typical eth_header_tb -s eth_header_tb_sim
xsim eth_header_tb_sim -R
