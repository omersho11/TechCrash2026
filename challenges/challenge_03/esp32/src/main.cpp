// Speed Loopback — ESP32 8-Bit Parallel SPI Receiver
// Receives N random bytes in parallel from FPGA using SCLK sync,
// computes checksum, and returns checksum over high-speed UART.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

// Use default OLED pins from pin_config.h

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

// Parallel Bus Pins
const int PIN_D0     = 15;
const int PIN_D1     = 2;
const int PIN_D2     = 4;
const int PIN_D3     = 12; // Moved to GPIO 12
const int PIN_D4     = 17;
const int PIN_D5     = 13; // Moved from GPIO 5 (strapping pin w/ pull-up)
const int PIN_D6     = 18;
const int PIN_D7     = 19;
const int PIN_SCLK   = 23;
const int PIN_ESP_TX = 16; // Moved to GPIO 16
const int PIN_CS     = 14; // Chip Select (Active Low)

// Buffer to store raw GPIO readings during the high-speed transfer
#define MAX_BYTES 10004
uint32_t rx_buffer[MAX_BYTES];

inline uint8_t readByteFromGPIO(uint32_t reg_val) {
    uint8_t b = 0;
    if (reg_val & (1 << 15)) b |= (1 << 0);
    if (reg_val & (1 << 2))  b |= (1 << 1);
    if (reg_val & (1 << 4))  b |= (1 << 2);
    if (reg_val & (1 << 12)) b |= (1 << 3); // Read GPIO 12
    if (reg_val & (1 << 17)) b |= (1 << 4);
    if (reg_val & (1 << 13)) b |= (1 << 5); // GPIO 13
    if (reg_val & (1 << 18)) b |= (1 << 6);
    if (reg_val & (1 << 19)) b |= (1 << 7);
    return b;
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback 8-Bit Parallel SPI Receiver ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }

    pinMode(PIN_D0, INPUT_PULLDOWN);
    pinMode(PIN_D1, INPUT_PULLDOWN);
    pinMode(PIN_D2, INPUT_PULLDOWN);
    pinMode(PIN_D3, INPUT_PULLDOWN);
    pinMode(PIN_D4, INPUT_PULLDOWN);
    pinMode(PIN_D5, INPUT_PULLDOWN);
    pinMode(PIN_D6, INPUT_PULLDOWN);
    pinMode(PIN_D7, INPUT_PULLDOWN);
    pinMode(PIN_SCLK, INPUT_PULLDOWN);
    pinMode(PIN_CS, INPUT_PULLUP);

    // Hardware Serial for return path (TX only) at 921600 baud
    FpgaSerial.begin(921600, SERIAL_8N1, -1, PIN_ESP_TX);

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("Parallel 8-bit SPI");
    display.println("Waiting for FPGA...");
    display.display();

    // Let GPIOs settle after boot before listening for CS
    delay(50);
}

void loop() {
    Serial.println("Waiting for parallel transfer...");

    // Wait for CS to go low (active state) with debounce
    while (true) {
        while ((GPIO.in & (1 << PIN_CS)) != 0); // Wait for first low
        delayMicroseconds(5);                    // Debounce
        if ((GPIO.in & (1 << PIN_CS)) == 0) break; // Confirm still low
    }

    // Read 4-byte header and 10,000 data bytes into the fast buffer
    uint32_t i = 0;
    noInterrupts(); // Disable interrupts during the critical transfer
    while (i < MAX_BYTES) {
        uint32_t reg = GPIO.in;
        if (reg & (1 << PIN_CS)) break; // CS went high, transfer finished
        
        // If SCLK is high, sample!
        if (reg & (1 << PIN_SCLK)) {
            rx_buffer[i++] = reg;
            // Now wait for SCLK to go low or CS to go high
            while (true) {
                uint32_t reg2 = GPIO.in;
                if (reg2 & (1 << PIN_CS)) goto transfer_done;
                if ((reg2 & (1 << PIN_SCLK)) == 0) break;
            }
        }
    }
transfer_done:
    interrupts(); // Re-enable interrupts post-transfer

    // Reconstruction phase (post-transfer)
    uint8_t h0 = readByteFromGPIO(rx_buffer[0]);
    uint8_t h1 = readByteFromGPIO(rx_buffer[1]);
    uint8_t h2 = readByteFromGPIO(rx_buffer[2]);
    uint8_t h3 = readByteFromGPIO(rx_buffer[3]);
    uint32_t total_count = h0 | (h1 << 8) | (h2 << 16) | (h3 << 24);


    uint32_t sum = 0;
    for (uint32_t j = 4; j < i; j++) {
        sum += readByteFromGPIO(rx_buffer[j]);
    }

    // Send back checksum
    uint8_t checksum = sum & 0xFF;
    FpgaSerial.write(checksum);

    // Clear buffer to prevent stale data
    memset(rx_buffer, 0, sizeof(rx_buffer));

    Serial.printf("Done! N=%u Checksum=0x%02X\n", total_count, checksum);

    // Show result on OLED
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.printf("N = %u\n", total_count);
    display.println("COMPLETE!");
    display.printf("Checksum: 0x%02X\n", checksum);
    display.display();

}
