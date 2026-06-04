// Speed Loopback — ESP32 I2S Hardware Receiver (8x Decompression)
// Receives N random bytes compressed 8x from FPGA via custom I2S interface,
// decompresses on the fly, and returns checksum over UART.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "driver/i2s.h"
#include "../../../../projects/common/esp32/pin_config.h"

// Override OLED pins for Challenge 3 to free up contiguous pins on the left side
#undef PIN_OLED_SDA
#undef PIN_OLED_SCL
#define PIN_OLED_SDA        32      // Contiguous on right side
#define PIN_OLED_SCL        33      // Contiguous on right side

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

// Pin configurations for I2S Interface
const int PIN_I2S_BCLK = 15;
const int PIN_I2S_WS   = 2;
const int PIN_I2S_SD   = 4;
const int PIN_ESP_TX   = 21; // ESP32 TX -> FPGA UART RX

void initI2S() {
    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = 96000, // 96 kHz -> BCLK ~ 3.072 MHz
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S, // Standard I2S (1-bit delay)
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 1024,
        .use_apll = false,
        .tx_desc_auto_clear = false,
        .fixed_mclk = 0
    };

    i2s_pin_config_t pin_config = {
        .bck_io_num = PIN_I2S_BCLK,
        .ws_io_num = PIN_I2S_WS,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = PIN_I2S_SD
    };

    i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
    i2s_set_pin(I2S_NUM_0, &pin_config);
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback I2S Receiver ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }

    initI2S();

    // Hardware Serial for return path (TX only)
    FpgaSerial.begin(9600, SERIAL_8N1, -1, PIN_ESP_TX);

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("I2S 8x Decompression");
    display.println("Waiting for FPGA...");
    display.display();
}

void loop() {
    // Clear residual DMA buffer before each run to ensure proper frame alignment
    i2s_stop(I2S_NUM_0);
    i2s_start(I2S_NUM_0);

    // We expect 628 16-bit words (1256 bytes) total
    // Word 0: Header[0] (MSB) + Header[1] (LSB)
    // Word 1: Header[2] (MSB) + Header[3] (LSB)
    // Word 2: Byte0 (MSB) + Padding (LSB)
    // Word 3..627 (625 words): 1250 compressed bytes
    const uint32_t expected_words = 628;
    uint16_t i2s_buffer[expected_words] = {0};
    size_t bytes_read = 0;

    Serial.println("Waiting for I2S transfer...");

    // Wait for the first non-zero word (Header Word 0)
    uint16_t first_word = 0;
    while (first_word == 0) {
        esp_err_t err = i2s_read(I2S_NUM_0, &first_word, 2, &bytes_read, portMAX_DELAY);
        if (err != ESP_OK) {
            delay(10);
        }
    }

    i2s_buffer[0] = first_word;
    
    // Read the remaining 627 words
    esp_err_t err = i2s_read(I2S_NUM_0, &i2s_buffer[1], (expected_words - 1) * 2, &bytes_read, portMAX_DELAY);

    if (err != ESP_OK || bytes_read < (expected_words - 1) * 2) {
        Serial.printf("I2S read error or timeout, read %u bytes\n", bytes_read);
        delay(1000);
        return;
    }

    // ---- Unpack Header ----
    uint32_t total_count = (i2s_buffer[0] >> 8) |
                           ((i2s_buffer[0] & 0xFF) << 8) |
                           ((i2s_buffer[1] >> 8) << 16) |
                           (((uint32_t)(i2s_buffer[1] & 0xFF)) << 24);

    Serial.printf("Total Count: %u\n", total_count);

    // ---- Unpack Initial Byte (Byte 0) ----
    uint8_t window = i2s_buffer[2] >> 8;
    uint32_t sum = window;
    uint32_t received = 1;

    // ---- Unpack and Decompress Remaining 1250 Bytes ----
    for (uint32_t w = 0; w < 625; w++) {
        uint16_t val = i2s_buffer[3 + w];
        uint8_t bytes[2] = { (uint8_t)(val >> 8), (uint8_t)(val & 0xFF) };

        for (int byte_idx = 0; byte_idx < 2; byte_idx++) {
            uint8_t compressed_byte = bytes[byte_idx];
            for (int bit = 0; bit < 8; bit++) {
                if (received < total_count) {
                    uint8_t bit_val = (compressed_byte >> bit) & 1;
                    window = ((window << 1) & 0xFF) | bit_val;
                    sum += window;
                    received++;
                }
            }
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
    display.printf("N = %u\n", total_count);
    display.println("COMPLETE!");
    display.printf("Checksum: 0x%02X\n", checksum);
    display.display();

    // Small delay before next wait loop to prevent immediate double triggering
    delay(2000);
}
