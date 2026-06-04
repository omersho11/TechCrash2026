---
name: FPGA UART RX/TX Communication
description: Guide and source modules for implementing robust UART RX and TX communication on the DE10-Lite FPGA.
---

# FPGA UART RX/TX Communication

This skill provides verified, reusable hardware modules for async UART communication on the DE10-Lite FPGA.

---

## Source Files

- [uart_rx.sv](file:///c:/Users/Omer/Desktop/Coding/Hackathons/TechCrash2026/.copilot/skills/fpga-uart-rxtx/uart_rx.sv): UART Receiver with double-flop input sync.
- [uart_tx.sv](file:///c:/Users/Omer/Desktop/Coding/Hackathons/TechCrash2026/.copilot/skills/fpga-uart-rxtx/uart_tx.sv): UART Transmitter with active-busy flag.

---

## How to Include Modules in a Project

If a challenge or demo project requires UART RX or TX:

1. **Copy the source files** into the project's `src/` directory (e.g. `challenges/challenge_XX/fpga/src/` or similar).
   > [!IMPORTANT]
   > **DO NOT** reference files directly from the `.copilot/skills/` path in your Quartus project. When submissions are graded or zipped, they only bundle the specific challenge directory. The modules **MUST** be physically copied to the project directory to be included in the submission `.zip` file.

2. **Add the files to the `.qsf` configuration** of the project:
   ```tcl
   set_global_assignment -name SYSTEMVERILOG_FILE src/uart_rx.sv
   set_global_assignment -name SYSTEMVERILOG_FILE src/uart_tx.sv
   ```

---

## Module Interfaces & Parameterization

Both modules are parameterized by clock frequency and baud rate.

### `uart_rx` (Receiver)

```systemverilog
uart_rx #(
    .CLK_FREQ(50_000_000), // FPGA main clock frequency (e.g. 50 MHz)
    .BAUD(115200)          // Target baud rate
) u_rx (
    .clk(MAX10_CLK1_50),
    .rst_n(reset_n),
    .rx(uart_rx_pin),
    .rx_data(rx_byte),      // output [7:0]
    .rx_valid(rx_strobe)    // output logic (1-cycle pulse when byte is ready)
);
```

### `uart_tx` (Transmitter)

```systemverilog
uart_tx #(
    .CLK_FREQ(50_000_000), // FPGA main clock frequency
    .BAUD(115200)          // Target baud rate
) u_tx (
    .clk(MAX10_CLK1_50),
    .rst_n(reset_n),
    .tx_data(tx_byte),     // input [7:0]
    .tx_start(tx_trigger),  // input logic (1-cycle pulse to start transmitting)
    .tx(uart_tx_pin),       // output serial data line
    .tx_busy(uart_tx_busy)  // output logic (high during transmission)
);
```
