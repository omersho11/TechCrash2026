#include <Arduino.h>

static constexpr uint32_t USB_BAUD = 115200;
static constexpr uint32_t FPGA_BAUD = 115200;

// Wire FPGA ARDUINO_IO[1] to this ESP32 pin. Also connect FPGA GND to ESP32 GND.
static constexpr int PIN_FPGA_RX = 17;

void setup() {
    Serial.begin(USB_BAUD);
    Serial2.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, -1);
    Serial.println("Challenge 08 UART bridge ready");
}

void loop() {
    while (Serial2.available() > 0) {
        Serial.write(static_cast<uint8_t>(Serial2.read()));
    }
}
