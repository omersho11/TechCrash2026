// ============================================================
// CrashTech VLSI-2026 — Challenge 6: Frequency Detector (ESP32 side)
// ============================================================
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>
#include "../../../../projects/common/esp32/pin_config.h"

// ---- OLED Display ----
Adafruit_SSD1306 oled(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
bool oledOk = false;

// ---- UART to FPGA ----
HardwareSerial FpgaSerial(2);

// ---- Configuration ----
const float SAMPLE_RATE = 8000.0f;
const int NUM_SAMPLES = 256;
int8_t sine_buffer[NUM_SAMPLES];

// ---- Timing Throttles ----
unsigned long lastSendTime = 0;
const unsigned long SEND_INTERVAL_MS = 100; // Send sample frames every 100ms

unsigned long lastDisplayTime = 0;
const unsigned long DISPLAY_INTERVAL_MS = 100; // Update display every 100ms

void setup() {
    // Debug serial output
    Serial.begin(115200);
    delay(1000);
    Serial.println("Challenge 6: Frequency Detector ESP32 Setup...");

    // OLED I2C Bus setup
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);

    // Scan I2C bus for the OLED address
    byte discoveredAddr = 0;
    Serial.println("Scanning I2C bus...");
    for (byte address = 1; address < 127; address++) {
        Wire.beginTransmission(address);
        byte error = Wire.endTransmission();
        if (error == 0) {
            Serial.printf("I2C device found at address 0x%02X\n", address);
            if (address == 0x3C || address == 0x3D) {
                discoveredAddr = address;
            }
        }
    }

    if (discoveredAddr == 0) {
        Serial.println("[!] No I2C display discovered! Trying default 0x3C...");
        discoveredAddr = OLED_I2C_ADDR;
    }

    oledOk = oled.begin(SSD1306_SWITCHCAPVCC, discoveredAddr);
    if (!oledOk) {
        Serial.printf("[!] OLED initialization failed at address 0x%02X!\n", discoveredAddr);
    } else {
        Serial.printf("[+] OLED successfully initialized at address 0x%02X\n", discoveredAddr);
        oled.clearDisplay();
        oled.setTextColor(SSD1306_WHITE);
        oled.setTextSize(1);
        oled.setCursor(0, 0);
        oled.println("Freq Detector Init...");
        oled.display();
    }

    // Initialize UART to FPGA at 115200 baud (Required for Challenge 6)
    FpgaSerial.begin(115200, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART initialized to FPGA at 115200 baud.");
}

void loop() {
    unsigned long now = millis();

    // Read potentiometer voltage (GPIO34)
    int adcRaw = analogRead(PIN_ANALOG_IN);
    // Map 0-4095 to 100-2000 Hz
    float frequency = 100.0f + (adcRaw / 4095.0f) * 1900.0f;

    // Send frequency samples over UART to FPGA periodically
    if (now - lastSendTime >= SEND_INTERVAL_MS) {
        lastSendTime = now;

        // Generate 256 samples of a digital sine wave
        for (int n = 0; n < NUM_SAMPLES; n++) {
            float t = (float)n / SAMPLE_RATE;
            sine_buffer[n] = (int8_t)(127.0f * sin(2.0f * M_PI * frequency * t));
        }

        // Send raw signed 8-bit bytes
        FpgaSerial.write((uint8_t*)sine_buffer, NUM_SAMPLES);
        FpgaSerial.flush(); // Ensure everything is sent

        // Print to host PC Serial Monitor for debugging
        Serial.printf("ADC: %d | Freq: %.1f Hz\n", adcRaw, frequency);
    }

    // Update OLED Display
    if (oledOk && (now - lastDisplayTime >= DISPLAY_INTERVAL_MS)) {
        lastDisplayTime = now;

        oled.clearDisplay();
        
        // Header
        oled.setTextSize(1);
        oled.setTextColor(SSD1306_WHITE);
        oled.setCursor(0, 0);
        oled.println("   FREQ GENERATOR   ");
        oled.drawFastHLine(0, 10, 128, SSD1306_WHITE);

        // Large Frequency Display
        oled.setTextSize(2);
        oled.setCursor(10, 20);
        oled.printf("%.1f Hz", frequency);

        // Progress/Level Bar
        oled.drawRect(10, 48, 108, 10, SSD1306_WHITE);
        int barWidth = map(adcRaw, 0, 4095, 0, 106);
        oled.fillRect(11, 49, barWidth, 8, SSD1306_WHITE);

        oled.display();
    }
}
