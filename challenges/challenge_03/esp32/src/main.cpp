// Speed Loopback — ESP32 SPI Slave with DMA Receiver
// Receives compressed LSB data from FPGA using SPI Slave + DMA,
// reconstructs the original 10,000 bytes on-the-fly,
// and returns the checksum over high-speed UART.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <driver/spi_slave.h>
#include "../../../../projects/common/esp32/pin_config.h"

// OLED display setup
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

// SPI Pin Definitions (Default VSPI hardware pins for IOMUX)
const int PIN_MOSI   = 23;
const int PIN_SCLK   = 18;
const int PIN_CS     = 5;
const int PIN_ESP_TX = 16; // UART TX back to FPGA

// SPI DMA Buffer
#define BUFFER_SIZE 1280
uint8_t* rx_buffer = NULL;

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback High-Speed SPI Slave Receiver ---");

    // Initialize OLED
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("SPI Slave + DMA");
    display.println("Ready...");
    display.display();

    // Hardware Serial for return path (TX only) at 921600 baud
    FpgaSerial.begin(921600, SERIAL_8N1, -1, PIN_ESP_TX);

    // Allocate DMA-capable memory for SPI receiver
    rx_buffer = (uint8_t*)heap_caps_malloc(BUFFER_SIZE, MALLOC_CAP_DMA);
    if (rx_buffer == NULL) {
        Serial.println("Failed to allocate DMA buffer!");
        while (1);
    }
    memset(rx_buffer, 0, BUFFER_SIZE);

    // Configure SPI Slave bus and interface
    spi_bus_config_t buscfg = {
        .mosi_io_num = PIN_MOSI,
        .miso_io_num = -1,
        .sclk_io_num = PIN_SCLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = BUFFER_SIZE,
        .flags = SPICOMMON_BUSFLAG_SLAVE
    };

    spi_slave_interface_config_t slvcfg = {
        .spics_io_num = PIN_CS,
        .flags = 0,
        .queue_size = 1,
        .mode = 0, // SPI mode 0
        .post_setup_cb = NULL,
        .post_trans_cb = NULL
    };

    // Enable internal pull-ups and pull-downs to prevent floating line glitches
    pinMode(PIN_CS, INPUT_PULLUP);
    pinMode(PIN_SCLK, INPUT_PULLDOWN);
    pinMode(PIN_MOSI, INPUT_PULLDOWN);

    // Initialize SPI Slave on VSPI (SPI3) with DMA auto channel
    esp_err_t ret = spi_slave_initialize(VSPI_HOST, &buscfg, &slvcfg, SPI_DMA_CH_AUTO);
    if (ret != ESP_OK) {
        Serial.printf("SPI Slave Init Failed: 0x%X\n", ret);
        while (1);
    }

    Serial.println("SPI Slave initialized and waiting for transfer...");
}

void loop() {
    // Set up SPI transaction
    spi_slave_transaction_t transaction;
    memset(&transaction, 0, sizeof(spi_slave_transaction_t));
    transaction.length = 1255 * 8; // 1255 bytes * 8 bits/byte
    transaction.rx_buffer = rx_buffer;

    // Wait for the transmission to complete (handled by hardware DMA)
    esp_err_t ret = spi_slave_transmit(VSPI_HOST, &transaction, portMAX_DELAY);
    if (ret != ESP_OK) {
        Serial.printf("SPI Transmission failed: 0x%X\n", ret);
        return;
    }

    // Process received data
    uint32_t total_count = rx_buffer[0] | (rx_buffer[1] << 8) | (rx_buffer[2] << 16) | (rx_buffer[3] << 24);
    uint8_t first_byte = rx_buffer[4];

    // On-the-fly reconstruction and checksum sum calculation
    uint8_t current_byte = first_byte;
    uint32_t sum = current_byte;

    for (uint32_t k = 1; k < 10000; k++) {
        uint32_t byte_offset = 5 + (k - 1) / 8;
        uint32_t bit_offset = (k - 1) % 8;
        uint8_t lsb = (rx_buffer[byte_offset] >> bit_offset) & 1;
        current_byte = (current_byte << 1) | lsb;
        sum += current_byte;
    }

    uint8_t checksum = sum & 0xFF;

    // Send back checksum over UART
    FpgaSerial.write(checksum);

    // Print status
    Serial.printf("Received N=%u, FirstByte=0x%02X, Checksum=0x%02X\n", total_count, first_byte, checksum);

    // Show result on OLED
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("SPI Loopback");
    display.printf("N = %u\n", total_count);
    display.println("COMPLETE!");
    display.printf("Checksum: 0x%02X\n", checksum);
    display.display();

    // Clear buffer for the next transaction
    memset(rx_buffer, 0, BUFFER_SIZE);
}
