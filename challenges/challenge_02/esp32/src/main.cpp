// ============================================================
// CrashTech VLSI-2026 — Challenge 2: Accelerometer 3D Cube (ESP32 side)
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

// 3D Point Definition
struct Point3D {
    float x, y, z;
};

// 8 Vertices of a Cube (centered at origin, side length = 24)
const Point3D baseVertices[8] = {
    {-12, -12, -12},
    { 12, -12, -12},
    { 12,  12, -12},
    {-12,  12, -12},
    {-12, -12,  12},
    { 12, -12,  12},
    { 12,  12,  12},
    {-12,  12,  12}
};

// 12 Edges connecting the vertices
const int edges[12][2] = {
    {0, 1}, {1, 2}, {2, 3}, {3, 0}, // Back face
    {4, 5}, {5, 6}, {6, 7}, {7, 4}, // Front face
    {0, 4}, {1, 5}, {2, 6}, {3, 7}  // Connections
};

// Rotates a point in 3D space
Point3D rotatePoint(Point3D p, float pitch, float roll) {
    Point3D rotated = p;
    
    // Rotate around X axis (pitch)
    float cosP = cos(pitch);
    float sinP = sin(pitch);
    float y1 = rotated.y * cosP - rotated.z * sinP;
    float z1 = rotated.y * sinP + rotated.z * cosP;
    rotated.y = y1;
    rotated.z = z1;
    
    // Rotate around Y axis (roll)
    float cosR = cos(roll);
    float sinR = sin(roll);
    float x2 = rotated.x * cosR + rotated.z * sinR;
    float z2 = -rotated.x * sinR + rotated.z * cosR;
    rotated.x = x2;
    rotated.z = z2;
    
    return rotated;
}

// Projection coordinates
struct Point2D {
    int x, y;
};

// Perspective projection from 3D to 2D screen
Point2D project(Point3D p) {
    float distance = 60.0;
    float cameraDistance = 60.0;
    
    int sx = (int)(OLED_WIDTH / 2 + p.x * cameraDistance / (p.z + distance));
    int sy = (int)(OLED_HEIGHT / 2 + p.y * cameraDistance / (p.z + distance));
    
    return {sx, sy};
}

void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("Challenge 2: Accelerometer 3D Cube ESP32 Setup...");

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
        oled.setTextSize(1);
        oled.setTextColor(SSD1306_WHITE);
        oled.setCursor(0, 0);
        oled.println("3D CUBE TILT DEMO");
        oled.println("Waiting for FPGA...");
        oled.display();
    }

    // Initialize UART to FPGA (9600 8N1)
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("UART initialized to FPGA at 9600 baud.");
}

// UART Buffer and synchronization state
uint8_t packet[8];
int packetIdx = 0;

void loop() {
    while (FpgaSerial.available() > 0) {
        uint8_t b = FpgaSerial.read();
        
        if (packetIdx == 0) {
            if (b == 0xAA) {
                packet[packetIdx++] = b;
            }
        } else {
            packet[packetIdx++] = b;
            if (packetIdx == 8) {
                // Verify trailer
                if (packet[7] == 0x55) {
                    // Extract raw acceleration values
                    int16_t x_raw = (int16_t)((packet[1] << 8) | packet[2]);
                    int16_t y_raw = (int16_t)((packet[3] << 8) | packet[4]);
                    int16_t z_raw = (int16_t)((packet[5] << 8) | packet[6]);
                    
                    // Pitch and Roll Calculation
                    // Raw values scale is typically +/- 2g corresponding to 10-bit or similar representation
                    float x = (float)x_raw;
                    float y = (float)y_raw;
                    float z = (float)z_raw;
                    
                    float pitch = atan2(-x, sqrt(y*y + z*z));
                    float roll = atan2(y, z);
                    
                    // Output data for debugging
                    Serial.printf("Raw X: %6d | Y: %6d | Z: %6d | Pitch: %6.2f | Roll: %6.2f\n", 
                                  x_raw, y_raw, z_raw, pitch * 180.0 / PI, roll * 180.0 / PI);
                    
                    // Render 3D Cube
                    if (oledOk) {
                        oled.clearDisplay();
                        
                        // Project all vertices
                        Point2D projected[8];
                        for (int i = 0; i < 8; i++) {
                            Point3D rotated = rotatePoint(baseVertices[i], pitch, roll);
                            projected[i] = project(rotated);
                        }
                        
                        // Draw all edges
                        for (int i = 0; i < 12; i++) {
                            int u = edges[i][0];
                            int v = edges[i][1];
                            oled.drawLine(projected[u].x, projected[u].y, 
                                          projected[v].x, projected[v].y, SSD1306_WHITE);
                        }
                        
                        // Print pitch and roll text on screen
                        oled.setTextSize(1);
                        oled.setCursor(0, 0);
                        oled.printf("P:%.1f", pitch * 180.0 / PI);
                        oled.setCursor(0, 56);
                        oled.printf("R:%.1f", roll * 180.0 / PI);
                        
                        oled.display();
                    }
                } else {
                    Serial.println("[!] Packet parsing error: Bad trailer.");
                }
                packetIdx = 0; // Reset for next packet
            }
        }
    }
}
