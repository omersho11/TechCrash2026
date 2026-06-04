#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../../projects/common/esp32/pin_config.h"

// SSD1306 OLED setup
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// Game constants
#define BIRD_WIDTH 12
#define BIRD_HEIGHT 8
#define OBSTACLE_WIDTH 10
#define GRAVITY 0.35
#define FLAP_VELOCITY -2.3
#define GROUND_Y 60

// Cute 12x8 Flappy Bird Bitmap
static const unsigned char PROGMEM bird_bmp[] = {
  0b00011111, 0b00000000, //    #####
  0b00100000, 0b11000000, //   *     ##
  0b01001010, 0b01000000, //  * * * *  *
  0b10000000, 0b00100000, // *        *
  0b10011000, 0b00100000, // *  ##    *
  0b10000001, 0b11100000, // *       ***
  0b01000010, 0b00000000, //  *    *
  0b00111100, 0b00000000  //   ****
};

// Game states
enum GameState {
    STATE_START,
    STATE_PLAYING,
    STATE_GAME_OVER
};

GameState currentState = STATE_START;

// Game variables
float birdY = 25.0;
float birdVelocity = 0;
float obstacleX = OLED_WIDTH;
float obstacleGapY = 30.0;
int difficulty = 0; // 0 to 15
float obstacleSpeed = 1.0;
int obstacleGapSize = 28;
int score = 0;
int highSc = 0;
bool wingUp = false;

void resetGame() {
    birdY = 25.0;
    birdVelocity = 0;
    obstacleX = OLED_WIDTH;
    obstacleGapY = random(16, GROUND_Y - 16);
    score = 0;
    currentState = STATE_PLAYING;
}

void updateDifficultySettings() {
    // Map difficulty (0-15) to obstacle speed and gap size
    obstacleSpeed = 1.0 + (difficulty / 5.0);
    obstacleGapSize = 28 - difficulty;
    if (obstacleGapSize < 12) obstacleGapSize = 12; // Safety limit
}

void processUART() {
    while (Serial2.available() > 0) {
        uint8_t incomingByte = Serial2.read();
        
        if (incomingByte == 0x01) {
            // Flap or Restart action
            if (currentState == STATE_START || currentState == STATE_GAME_OVER) {
                resetGame();
            } else if (currentState == STATE_PLAYING) {
                birdVelocity = FLAP_VELOCITY;
                wingUp = !wingUp; // Toggle wing state for animation
            }
        } 
        else if ((incomingByte & 0xF0) == 0x10) {
            // Set difficulty (0 to 15)
            difficulty = incomingByte & 0x0F;
            updateDifficultySettings();
        }
    }
}

void setup() {
    Serial.begin(115200);
    
    // UART2 communication with FPGA
    Serial2.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    
    // Initialize OLED
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if(!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println(F("SSD1306 allocation failed"));
        for(;;);
    }
    
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.display();
    
    randomSeed(analogRead(34));
    updateDifficultySettings();
}

void drawGameBorder() {
    // Draw ground line
    display.drawFastHLine(0, GROUND_Y, OLED_WIDTH, SSD1306_WHITE);
    // Tiny grass marks on ground
    for (int i = 0; i < OLED_WIDTH; i += 16) {
        display.drawLine(i, GROUND_Y, i + 2, GROUND_Y + 2, SSD1306_WHITE);
    }
}

void loop() {
    processUART();
    display.clearDisplay();
    
    if (currentState == STATE_START) {
        // Main title with border
        display.drawRect(0, 0, OLED_WIDTH, OLED_HEIGHT, SSD1306_WHITE);
        display.setTextSize(1);
        display.setCursor(12, 6);
        display.print(F("=== FLAPPY BIRD ==="));
        
        display.setCursor(8, 22);
        display.printf("Difficulty: %d", difficulty);
        display.setCursor(8, 32);
        display.printf("Speed:%.1f  Gap:%d", obstacleSpeed, obstacleGapSize);
        
        display.setCursor(10, 48);
        display.print(F("Press KEY0 to Start"));
    } 
    else if (currentState == STATE_PLAYING) {
        // Physics
        birdVelocity += GRAVITY;
        birdY += birdVelocity;
        
        // Obstacle movement
        obstacleX -= obstacleSpeed;
        if (obstacleX < -OBSTACLE_WIDTH) {
            obstacleX = OLED_WIDTH;
            obstacleGapY = random(16, GROUND_Y - 16);
            score++;
            if (score > highSc) highSc = score;
        }
        
        // Collisions: floor (ground) and ceiling
        if (birdY < 0 || birdY + BIRD_HEIGHT > GROUND_Y) {
            currentState = STATE_GAME_OVER;
        }
        
        // Collisions: obstacles
        float birdLeft = OLED_WIDTH / 4.0;
        float birdRight = birdLeft + BIRD_WIDTH;
        if (obstacleX < birdRight && (obstacleX + OBSTACLE_WIDTH) > birdLeft) {
            float topPipeBottom = obstacleGapY - (obstacleGapSize / 2.0);
            float bottomPipeTop = obstacleGapY + (obstacleGapSize / 2.0);
            if (birdY < topPipeBottom || (birdY + BIRD_HEIGHT) > bottomPipeTop) {
                currentState = STATE_GAME_OVER;
            }
        }
        
        // Draw Obstacles (pipes) with decorative lips
        display.fillRect(obstacleX, 0, OBSTACLE_WIDTH, obstacleGapY - (obstacleGapSize / 2.0), SSD1306_WHITE);
        display.drawRect(obstacleX - 1, obstacleGapY - (obstacleGapSize / 2.0) - 3, OBSTACLE_WIDTH + 2, 3, SSD1306_WHITE); // pipe lip top
        
        display.fillRect(obstacleX, obstacleGapY + (obstacleGapSize / 2.0), OBSTACLE_WIDTH, GROUND_Y - (obstacleGapY + (obstacleGapSize / 2.0)), SSD1306_WHITE);
        display.drawRect(obstacleX - 1, obstacleGapY + (obstacleGapSize / 2.0), OBSTACLE_WIDTH + 2, 3, SSD1306_WHITE); // pipe lip bottom
        
        // Draw Bird Bitmap
        display.drawBitmap(OLED_WIDTH / 4.0, (int)birdY, bird_bmp, BIRD_WIDTH, BIRD_HEIGHT, SSD1306_WHITE);
        // Animated wing pixel
        if (wingUp) {
            display.drawPixel(OLED_WIDTH / 4.0 + 3, (int)birdY + 4, SSD1306_BLACK);
            display.drawPixel(OLED_WIDTH / 4.0 + 3, (int)birdY + 3, SSD1306_WHITE);
        } else {
            display.drawPixel(OLED_WIDTH / 4.0 + 3, (int)birdY + 4, SSD1306_WHITE);
            display.drawPixel(OLED_WIDTH / 4.0 + 3, (int)birdY + 3, SSD1306_BLACK);
        }
        
        drawGameBorder();
        
        // Draw HUD
        display.setTextSize(1);
        display.setCursor(2, 2);
        display.printf("S:%d H:%d D:%d", score, highSc, difficulty);
    } 
    else if (currentState == STATE_GAME_OVER) {
        display.drawRect(0, 0, OLED_WIDTH, OLED_HEIGHT, SSD1306_WHITE);
        display.setTextSize(1);
        display.setCursor(34, 8);
        display.print(F("GAME OVER"));
        display.setCursor(18, 24);
        display.printf("Score: %d  High: %d", score, highSc);
        display.setCursor(20, 34);
        display.printf("Difficulty: %d", difficulty);
        display.setCursor(8, 48);
        display.print(F("Press KEY0 to Restart"));
    }
    
    display.display();
    delay(33);
}
