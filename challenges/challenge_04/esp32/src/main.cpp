// ============================================================
// CrashTech VLSI-2026 — Challenge 4: Press Right (ESP32 side)
// ============================================================
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

// ---- OLED Display ----
Adafruit_SSD1306 oled(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
bool oledOk = false;

// ---- UART to FPGA ----
HardwareSerial FpgaSerial(2);

void playVictoryMelody() {
    Serial.println("Playing victory melody...");
    tone(PIN_BUZZER, 1000);
    delay(150);
    tone(PIN_BUZZER, 1200);
    delay(150);
    tone(PIN_BUZZER, 1500);
    delay(300);
    noTone(PIN_BUZZER);
}

void playFailureMelody() {
    Serial.println("Playing failure melody...");
    tone(PIN_BUZZER, 300);
    delay(350);
    tone(PIN_BUZZER, 200);
    delay(400);
    noTone(PIN_BUZZER);
}

void showInitialScreen() {
    if (!oledOk) return;
    oled.clearDisplay();
    oled.setTextSize(1);
    oled.setTextColor(SSD1306_WHITE);
    
    // Title header
    oled.setCursor(0, 0);
    oled.println("   STOPWATCH GAME   ");
    oled.drawFastHLine(0, 10, 128, SSD1306_WHITE);
    
    // Instructions
    oled.setCursor(0, 20);
    oled.println("Target: 10.00s (1000)");
    oled.println("Press KEY[0] to Start");
    oled.println("Press KEY[0] to Stop ");
    oled.println("Goal: +/- 10 (0.1s)");
    
    oled.display();
}

void setup() {
    // Debug serial output to host PC
    Serial.begin(115200);
    delay(1000);
    Serial.println("Challenge 4: Press Right ESP32 Setup...");

    // Setup Buzzer pin
    pinMode(PIN_BUZZER, OUTPUT);
    noTone(PIN_BUZZER);

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
        showInitialScreen();
    }

    // Initialize UART to FPGA (9600 8N1)
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART initialized to FPGA at 9600 baud.");
}

void loop() {
    // Check if there is data from the FPGA UART
    if (FpgaSerial.available() > 0) {
        int stoppedValue = FpgaSerial.parseInt();
        
        // Print value to PC Serial Monitor
        Serial.printf("Received stopped value: %d\n", stoppedValue);

        // Clear OLED for updating results
        if (oledOk) {
            oled.clearDisplay();
            oled.setTextSize(1);
            oled.setTextColor(SSD1306_WHITE);
            oled.setCursor(0, 0);
            oled.println("    STOPWATCH GAME    ");
            oled.drawFastHLine(0, 10, 128, SSD1306_WHITE);
            
            // Draw stopped value
            oled.setCursor(0, 18);
            oled.printf("Stopped: %.2fs (%d)\n", stoppedValue / 100.0f, stoppedValue);
            
            // Check win/lose criteria (+/- 10 around 1000)
            int diff = stoppedValue - 1000;
            bool isWin = (abs(diff) <= 10);
            
            oled.setCursor(0, 32);
            if (isWin) {
                oled.setTextSize(2);
                oled.println("  WIN!  ");
                oled.setTextSize(1);
                oled.printf("Offset: %+d (%.2fs)\n", diff, diff / 100.0f);
                oled.display();
                
                // Play victory tone
                playVictoryMelody();
            } else {
                oled.setTextSize(2);
                oled.println(" TRY AGAIN ");
                oled.setTextSize(1);
                oled.printf("Offset: %+d (%.2fs)\n", diff, diff / 100.0f);
                oled.display();
                
                // Play failure tone
                playFailureMelody();
            }
            
            // Wait 3 seconds then return to initial screen
            delay(3000);
            // Clear serial buffer to ignore stale commands/inputs during delay
            while (FpgaSerial.available() > 0) {
                FpgaSerial.read();
            }
            showInitialScreen();
        }
    }
}
