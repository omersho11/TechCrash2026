# AI Agent Context: Challenge 9 (Neural Flappy Bird)

## Overview & Architecture
- **ESP32 Role**:
  - **Manual Mode**: Runs the Flappy Bird game engine and renders it on the SSD1306 OLED screen (I2C address `0x3C`, `SDA=GPIO21`, `SCL=GPIO22`). Listens for flap commands and difficulty settings over UART from the FPGA.
  - **Training Mode**: Simulates a population of $\ge 30$ birds in parallel. Each bird has a neural network structure (4 inputs, 1 hidden layer with 4 neurons, and 1 output neuron deciding whether to flap or not). Evaluates fitness based on survival time or score on a deterministic obstacle course. Executes genetic selection and mutation/crossover to evolve weights. Displays live training stats on the OLED.
  - **Inference Mode**: Transmits current game state inputs (bird height, velocity, distance to next obstacle, distance to obstacle gap) to the FPGA via UART. Receives the compute result (flap/no-flap decision) back via UART from the FPGA to drive the bird. Sends trained network weights to the FPGA after training mode completes.
- **FPGA Role**:
  - **Manual Mode**: Reads `KEY[0]` (flap) and `SW[3:0]` (difficulty). Displays difficulty (0-15) on the 7-segment display (HEX). Transmits flap triggers and difficulty commands to the ESP32 over UART.
  - **Inference Mode**: Receives the best neural network weights and game state inputs from the ESP32 via UART. Performs feedforward neural network inference in hardware (using fixed-point math for weights/biases and activation functions). Sends the resulting single-bit flap decision back to the ESP32 via UART.
  - **Mode Selection**: Reads `SW[9]` to switch between ESP32 training mode and FPGA inference mode, sending this state to the ESP32.

## Useful Hardware Info & Pinout
- **ESP32 ↔ FPGA UART Wiring**:
  - Common GND.
  - ESP32 TX2 (GPIO17) ↔ FPGA RX (PIN_AB5 / `ARDUINO_IO[0]`).
  - ESP32 RX2 (GPIO16) ↔ FPGA TX (PIN_AB6 / `ARDUINO_IO[1]`).

## Firmware & HDL Tips
- **Neural Network Architecture**:
  - 4 inputs: Bird Y, Bird Velocity, Dist to Obstacle X, Dist to Obstacle Gap Y.
  - Hidden Layer: 4 neurons. Output: 1 neuron (threshold logic).
  - Use scaled integer / fixed-point representations for weights (e.g., Q8.8 or Q16.16) to make FPGA implementation simple.
- **Weight Transfer**:
  - Define a packet format (e.g., header, payload of weights, checksum, footer) to securely transfer the weights from ESP32 to FPGA over UART when switching from training to inference.
