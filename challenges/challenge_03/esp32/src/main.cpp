// Speed Loopback — ESP32 Baseline (9600 baud single UART)
// Receives N random bytes from FPGA, sums them, sends back checksum.
// This is the SLOW reference implementation. Your job: make it faster!

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

void updateOLED(const char* status, uint32_t N, uint32_t received) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.printf("N = %u\n", N);
    display.println(status);
    if (N > 0)
        display.printf("Rcvd: %u (%.0f%%)\n", received, 100.0 * received / N);
    display.display();
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback Baseline ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }

    // 5 Mbps high-speed UART
    FpgaSerial.begin(5000000, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("Waiting for FPGA...");
    display.display();
}

void loop() {
    // ---- Wait for 4-byte header (count, little-endian) ----
    while (FpgaSerial.available() < 4) {
        // tight polling loop for speed, no delay
    }

    uint32_t N = 0;
    N |= (uint32_t)FpgaSerial.read();
    N |= (uint32_t)FpgaSerial.read() << 8;
    N |= (uint32_t)FpgaSerial.read() << 16;
    N |= (uint32_t)FpgaSerial.read() << 24;

    Serial.printf("Receiving %u bytes...\n", N);
    updateOLED("Receiving...", N, 0);

    // ---- Receive N bytes and accumulate sum ----
    uint32_t sum = 0;
    uint32_t received = 0;
    uint8_t buffer[512];

    while (received < N) {
        int avail = FpgaSerial.available();
        if (avail > 0) {
            int toRead = min(avail, (int)(N - received));
            if (toRead > (int)sizeof(buffer)) toRead = sizeof(buffer);
            int readBytes = FpgaSerial.readBytes(buffer, toRead);
            for (int i = 0; i < readBytes; i++) {
                sum += buffer[i];
            }
            received += readBytes;
        }
    }

    // ---- Send back checksum ----
    uint8_t checksum = sum & 0xFF;
    FpgaSerial.write(checksum);

    Serial.printf("Done! Received=%u Sum=0x%08X Checksum=0x%02X\n",
                  received, sum, checksum);

    // ---- Show result ----
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.printf("N = %u\n", N);
    display.println("COMPLETE!");
    display.printf("Checksum: 0x%02X\n", checksum);
    display.display();

    // Wait for next run
    delay(3000);
}
