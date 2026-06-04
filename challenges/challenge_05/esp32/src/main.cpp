// ============================================================
// CrashTech VLSI-2026 — Challenge 5: FPGA Volt-Meter (ESP32)
// ============================================================
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

// OLED Display
Adafruit_SSD1306 oled(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
bool oledOk = false;

// UART to FPGA (9600 baud, 8N1, TX=16, RX=17)
HardwareSerial FpgaSerial(2);

// Parsing Buffer
String rxBuffer = "";
float currentVoltage = 0.0f;

void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("Challenge 5: FPGA Volt-Meter ESP32 Starting...");

    // OLED I2C Setup
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);

    // Auto-detect I2C address for OLED
    byte oledAddr = OLED_I2C_ADDR;
    Wire.beginTransmission(0x3C);
    if (Wire.endTransmission() != 0) {
        Wire.beginTransmission(0x3D);
        if (Wire.endTransmission() == 0) {
            oledAddr = 0x3D;
        }
    }

    oledOk = oled.begin(SSD1306_SWITCHCAPVCC, oledAddr);
    if (!oledOk) {
        Serial.println("[!] OLED initialization failed!");
    } else {
        Serial.printf("[+] OLED initialized at 0x%02X\n", oledAddr);
        oled.clearDisplay();
        oled.setTextColor(SSD1306_WHITE);
        oled.setTextSize(1);
        oled.setCursor(0, 0);
        oled.println("Waiting for FPGA...");
        oled.display();
    }

    // Initialize UART connection to FPGA
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART to FPGA initialized.");
}

void loop() {
    // Read serial data from FPGA
    while (FpgaSerial.available()) {
        char c = (char)FpgaSerial.read();
        if (c == '\n' || c == '\r') {
            if (rxBuffer.length() > 0) {
                // Parse float from buffer
                float parsed = rxBuffer.toFloat();
                if (parsed >= 0.0f && parsed <= 5.0f) { // Simple validity check
                    currentVoltage = parsed;
                    Serial.printf("Received Voltage: %.2f V\n", currentVoltage);
                }
                rxBuffer = "";
            }
        } else {
            // Filter printable chars
            if (c >= '0' && c <= '9' || c == '.') {
                rxBuffer += c;
            }
        }
    }

    // Update OLED Display (live)
    if (oledOk) {
        oled.clearDisplay();

        // Premium Interface Design
        oled.drawRect(0, 0, OLED_WIDTH, OLED_HEIGHT, SSD1306_WHITE);
        oled.drawRect(2, 2, OLED_WIDTH - 4, OLED_HEIGHT - 4, SSD1306_WHITE);

        // Header Title
        oled.setTextSize(1);
        oled.setCursor(15, 8);
        oled.print("FPGA VOLT-METER");
        oled.drawFastHLine(6, 18, OLED_WIDTH - 12, SSD1306_WHITE);

        // Voltage Value
        oled.setTextSize(3);
        oled.setCursor(18, 26);
        oled.printf("%.2fV", currentVoltage);

        oled.display();
    }
    delay(30);
}
