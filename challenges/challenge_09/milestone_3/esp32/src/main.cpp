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
#define POPULATION_SIZE 30

// Cute 12x8 Flappy Bird Bitmap
static const unsigned char PROGMEM bird_bmp[] = {
  0b00011111, 0b00000000,
  0b00100000, 0b11000000,
  0b01001010, 0b01000000,
  0b10000000, 0b00100000,
  0b10011000, 0b00100000,
  0b10000001, 0b11100000,
  0b01000010, 0b00000000,
  0b00111100, 0b00000000
};

// Neural Network definition
struct NeuralNetwork {
    float w1[4][4];
    float b1[4];
    float w2[4][4];
    float b2[4];
    float w3[4];
    float b3;
};

struct Bird {
    float y;
    float velocity;
    bool alive;
    unsigned long fitness;
    int score;
    NeuralNetwork brain;
};

Bird population[POPULATION_SIZE];
int generation = 0;
int bestScore = 0;
int bestFitness = 0;
int aliveCount = POPULATION_SIZE;

// Obstacles
float obstacleX[2];
float obstacleGapY[2];
int difficulty = 0;
float obstacleSpeed = 1.0;
int obstacleGapSize = 28;
int pipeDistance = 64;

// Display and operating modes
bool showOnlyBest = false;
bool fpgaInferenceMode = false; // false = ESP32 training, true = FPGA inference
bool lastFpgaInferenceMode = false;

// Pseudo-RNG for obstacle course
uint32_t course_state = 42;
void my_srand(uint32_t seed) { course_state = seed; }
uint32_t my_rand() {
    course_state = course_state * 1664525 + 1013904223;
    return course_state;
}

float random_float(float min_val, float max_val) {
    return min_val + ((float)random(10000)/10000.0) * (max_val - min_val);
}

void initBrain(NeuralNetwork &brain) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            brain.w1[i][j] = random_float(-1.0, 1.0);
            brain.w2[i][j] = random_float(-1.0, 1.0);
        }
        brain.b1[i] = random_float(-1.0, 1.0);
        brain.b2[i] = random_float(-1.0, 1.0);
        brain.w3[i] = random_float(-1.0, 1.0);
    }
    brain.b3 = random_float(-1.0, 1.0);
}

void mutateBrain(NeuralNetwork &brain, float rate) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            if (random_float(0, 1.0) < rate) brain.w1[i][j] += random_float(-0.3, 0.3);
            if (random_float(0, 1.0) < rate) brain.w2[i][j] += random_float(-0.3, 0.3);
        }
        if (random_float(0, 1.0) < rate) brain.b1[i] += random_float(-0.3, 0.3);
        if (random_float(0, 1.0) < rate) brain.b2[i] += random_float(-0.3, 0.3);
        if (random_float(0, 1.0) < rate) brain.w3[i] += random_float(-0.3, 0.3);
    }
    if (random_float(0, 1.0) < rate) brain.b3 += random_float(-0.3, 0.3);
}

float sigmoid(float x) { return 1.0 / (1.0 + exp(-x)); }

bool decideFlap(Bird &bird, float nextPipeX, float nextPipeGapY) {
    float in0 = bird.y / GROUND_Y;
    float in1 = (bird.velocity + 5.0) / 10.0;
    float in2 = (nextPipeX - (OLED_WIDTH / 4.0)) / OLED_WIDTH;
    float in3 = (nextPipeGapY - bird.y) / GROUND_Y;

    float h1[4];
    for (int i = 0; i < 4; i++) {
        float sum = bird.brain.w1[i][0] * in0 +
                    bird.brain.w1[i][1] * in1 +
                    bird.brain.w1[i][2] * in2 +
                    bird.brain.w1[i][3] * in3 +
                    bird.brain.b1[i];
        h1[i] = sigmoid(sum);
    }

    float h2[4];
    for (int i = 0; i < 4; i++) {
        float sum = bird.brain.w2[i][0] * h1[0] +
                    bird.brain.w2[i][1] * h1[1] +
                    bird.brain.w2[i][2] * h1[2] +
                    bird.brain.w2[i][3] * h1[3] +
                    bird.brain.b2[i];
        h2[i] = sigmoid(sum);
    }

    float out = bird.brain.w3[0] * h2[0] +
                bird.brain.w3[1] * h2[1] +
                bird.brain.w3[2] * h2[2] +
                bird.brain.w3[3] * h2[3] +
                bird.brain.b3;
    return sigmoid(out) > 0.5;
}

void resetCourse(uint32_t seed) {
    my_srand(seed);
    obstacleX[0] = OLED_WIDTH;
    obstacleGapY[0] = 16 + (my_rand() % (GROUND_Y - 32));
    obstacleX[1] = OLED_WIDTH + pipeDistance;
    obstacleGapY[1] = 16 + (my_rand() % (GROUND_Y - 32));
}

void updateDifficultySettings() {
    obstacleSpeed = 1.0 + (difficulty / 5.0);
    obstacleGapSize = 28 - difficulty;
    if (obstacleGapSize < 12) obstacleGapSize = 12;
    pipeDistance = 70 - (difficulty * 2);
    if (pipeDistance < 40) pipeDistance = 40;
}

// Convert float to Q2.6 fixed point
int8_t floatToQ2_6(float val) {
    return (int8_t)constrain(round(val * 64.0), -128, 127);
}

// Transmit best weights to FPGA
void transferWeightsToFPGA(NeuralNetwork &brain) {
    uint8_t packet[47];
    packet[0] = 0xA0; // Header for weights
    
    int idx = 1;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            packet[idx++] = (uint8_t)floatToQ2_6(brain.w1[i][j]);
        }
        packet[idx++] = (uint8_t)floatToQ2_6(brain.b1[i]);
        for (int j = 0; j < 4; j++) {
            packet[idx++] = (uint8_t)floatToQ2_6(brain.w2[i][j]);
        }
        packet[idx++] = (uint8_t)floatToQ2_6(brain.b2[i]);
        packet[idx++] = (uint8_t)floatToQ2_6(brain.w3[i]);
    }
    packet[idx++] = (uint8_t)floatToQ2_6(brain.b3);
    
    // Checksum calculation (sum of payload bytes)
    uint8_t checksum = 0;
    for (int i = 1; i < 46; i++) {
        checksum += packet[i];
    }
    packet[46] = checksum;
    
    // Transmit
    Serial2.write(packet, 47);
    Serial.println("Transferred best weights (3 layers) to FPGA.");
}

void nextGeneration() {
    // Sort
    for (int i = 0; i < POPULATION_SIZE - 1; i++) {
        for (int j = 0; j < POPULATION_SIZE - i - 1; j++) {
            if (population[j].fitness < population[j + 1].fitness) {
                Bird temp = population[j];
                population[j] = population[j + 1];
                population[j + 1] = temp;
            }
        }
    }
    if ((int)population[0].score > bestScore) bestScore = population[0].score;
    if ((int)population[0].fitness > bestFitness) bestFitness = population[0].fitness;

    // Clone/mutate
    for (int i = 6; i < POPULATION_SIZE; i++) {
        population[i].brain = population[i % 6].brain;
        mutateBrain(population[i].brain, 0.15);
    }
    // Reset birds
    for (int i = 0; i < POPULATION_SIZE; i++) {
        population[i].y = 25.0;
        population[i].velocity = 0;
        population[i].alive = true;
        population[i].fitness = 0;
        population[i].score = 0;
    }
    generation++;
    aliveCount = POPULATION_SIZE;
    resetCourse(42 + generation);
}

void processUART() {
    while (Serial2.available() > 0) {
        uint8_t incomingByte = Serial2.read();
        if ((incomingByte & 0xF0) == 0x10) {
            difficulty = incomingByte & 0x0F;
            updateDifficultySettings();
        } 
        else if (incomingByte == 0x20) {
            showOnlyBest = false;
        } 
        else if (incomingByte == 0x21) {
            showOnlyBest = true;
        } 
        else if (incomingByte == 0x30) {
            fpgaInferenceMode = false;
        } 
        else if (incomingByte == 0x31) {
            fpgaInferenceMode = true;
        }
    }
}

// Single bird state for FPGA inference mode
float inferenceBirdY = 25.0;
float inferenceBirdVel = 0;
int inferenceScore = 0;
bool inferenceBirdAlive = true;

void resetInferenceBird() {
    inferenceBirdY = 25.0;
    inferenceBirdVel = 0;
    inferenceScore = 0;
    inferenceBirdAlive = true;
    resetCourse(esp_random());
}

// Query FPGA for inference decision
bool queryFPGAInference(float nextPipeX, float nextPipeGapY) {
    int8_t in0 = floatToQ2_6(inferenceBirdY / GROUND_Y);
    int8_t in1 = floatToQ2_6((inferenceBirdVel + 5.0) / 10.0);
    int8_t in2 = floatToQ2_6((nextPipeX - (OLED_WIDTH / 4.0)) / OLED_WIDTH);
    int8_t in3 = floatToQ2_6((nextPipeGapY - inferenceBirdY) / GROUND_Y);

    uint8_t packet[6];
    packet[0] = 0xB0; // Inputs header
    packet[1] = (uint8_t)in0;
    packet[2] = (uint8_t)in1;
    packet[3] = (uint8_t)in2;
    packet[4] = (uint8_t)in3;
    packet[5] = (uint8_t)(in0 + in1 + in2 + in3); // Checksum

    Serial2.write(packet, 6);

    // Wait with a timeout for FPGA decision, parsing any sync packets on the fly
    uint32_t start_t = millis();
    while (millis() - start_t < 25) {
        if (Serial2.available() > 0) {
            uint8_t incomingByte = Serial2.read();
            if ((incomingByte & 0xF0) == 0x10) {
                difficulty = incomingByte & 0x0F;
                updateDifficultySettings();
            } else if (incomingByte == 0x20) {
                showOnlyBest = false;
            } else if (incomingByte == 0x21) {
                showOnlyBest = true;
            } else if (incomingByte == 0x30) {
                fpgaInferenceMode = false;
            } else if (incomingByte == 0x31) {
                fpgaInferenceMode = true;
            } else if (incomingByte == 0x00 || incomingByte == 0x01) {
                return (incomingByte == 0x01);
            }
        }
    }
    return false; // Timeout safety
}

void setup() {
    Serial.begin(115200);
    Serial2.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if(!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        for(;;);
    }
    
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.display();

    randomSeed(analogRead(34));
    for (int i = 0; i < POPULATION_SIZE; i++) {
        population[i].y = 25.0;
        population[i].velocity = 0;
        population[i].alive = true;
        population[i].fitness = 0;
        population[i].score = 0;
        initBrain(population[i].brain);
    }
    updateDifficultySettings();
    resetCourse(42);
}

void drawGameBorder() {
    display.drawFastHLine(0, GROUND_Y, OLED_WIDTH, SSD1306_WHITE);
    for (int i = 0; i < OLED_WIDTH; i += 16) {
        display.drawLine(i, GROUND_Y, i + 2, GROUND_Y + 2, SSD1306_WHITE);
    }
}

void loop() {
    processUART();
    display.clearDisplay();

    // Handle mode transition: copy weights to FPGA
    if (fpgaInferenceMode && !lastFpgaInferenceMode) {
        // Sort current population to get the best bird
        for (int i = 0; i < POPULATION_SIZE - 1; i++) {
            for (int j = 0; j < POPULATION_SIZE - i - 1; j++) {
                if (population[j].fitness < population[j + 1].fitness) {
                    Bird temp = population[j];
                    population[j] = population[j + 1];
                    population[j + 1] = temp;
                }
            }
        }
        transferWeightsToFPGA(population[0].brain);
        delay(100); // Wait for UART transmission to fully complete
        resetInferenceBird();
    }
    lastFpgaInferenceMode = fpgaInferenceMode;

    // Obstacle determination
    int nextPipeIdx = 0;
    float nextPipeX = obstacleX[0];
    float nextPipeGapY = obstacleGapY[0];
    float birdX = OLED_WIDTH / 4.0;
    
    if (obstacleX[0] + OBSTACLE_WIDTH < birdX) {
        nextPipeIdx = 1;
        nextPipeX = obstacleX[1];
        nextPipeGapY = obstacleGapY[1];
    } else if (obstacleX[1] + OBSTACLE_WIDTH < birdX && obstacleX[1] > obstacleX[0]) {
        nextPipeIdx = 0;
        nextPipeX = obstacleX[0];
        nextPipeGapY = obstacleGapY[0];
    }

    if (!fpgaInferenceMode) {
        // ESP32 Genetic Algorithm Loop
        aliveCount = 0;
        int bestBirdIdx = -1;
        unsigned long maxFitnessSoFar = 0;

        for (int i = 0; i < POPULATION_SIZE; i++) {
            if (population[i].alive) {
                aliveCount++;
                if (decideFlap(population[i], nextPipeX, nextPipeGapY)) {
                    population[i].velocity = FLAP_VELOCITY;
                }
                population[i].velocity += GRAVITY;
                population[i].y += population[i].velocity;
                population[i].fitness++;

                if (population[i].y < 0 || population[i].y + BIRD_HEIGHT > GROUND_Y) {
                    population[i].alive = false;
                }
                for (int p = 0; p < 2; p++) {
                    if (obstacleX[p] < birdX + BIRD_WIDTH && (obstacleX[p] + OBSTACLE_WIDTH) > birdX) {
                        float topPipeBottom = obstacleGapY[p] - (obstacleGapSize / 2.0);
                        float bottomPipeTop = obstacleGapY[p] + (obstacleGapSize / 2.0);
                        if (population[i].y < topPipeBottom || (population[i].y + BIRD_HEIGHT) > bottomPipeTop) {
                            population[i].alive = false;
                        }
                    }
                }
                if (population[i].alive && population[i].fitness > maxFitnessSoFar) {
                    maxFitnessSoFar = population[i].fitness;
                    bestBirdIdx = i;
                }
            }
        }

        if (aliveCount == 0) {
            nextGeneration();
            return;
        }

        // Move obstacles
        for (int p = 0; p < 2; p++) {
            obstacleX[p] -= obstacleSpeed;
            if (obstacleX[p] < -OBSTACLE_WIDTH) {
                obstacleX[p] = obstacleX[1 - p] + pipeDistance;
                obstacleGapY[p] = 16 + (my_rand() % (GROUND_Y - 32));
                for (int i = 0; i < POPULATION_SIZE; i++) {
                    if (population[i].alive) population[i].score++;
                }
            }
        }

        // Draw Obstacles
        for (int p = 0; p < 2; p++) {
            display.fillRect(obstacleX[p], 0, OBSTACLE_WIDTH, obstacleGapY[p] - (obstacleGapSize / 2.0), SSD1306_WHITE);
            display.drawRect(obstacleX[p] - 1, obstacleGapY[p] - (obstacleGapSize / 2.0) - 3, OBSTACLE_WIDTH + 2, 3, SSD1306_WHITE);
            display.fillRect(obstacleX[p], obstacleGapY[p] + (obstacleGapSize / 2.0), OBSTACLE_WIDTH, GROUND_Y - (obstacleGapY[p] + (obstacleGapSize / 2.0)), SSD1306_WHITE);
            display.drawRect(obstacleX[p] - 1, obstacleGapY[p] + (obstacleGapSize / 2.0), OBSTACLE_WIDTH + 2, 3, SSD1306_WHITE);
        }

        // Draw Birds
        if (showOnlyBest) {
            if (bestBirdIdx != -1) {
                display.drawBitmap(birdX, (int)population[bestBirdIdx].y, bird_bmp, BIRD_WIDTH, BIRD_HEIGHT, SSD1306_WHITE);
            }
        } else {
            for (int i = 0; i < POPULATION_SIZE; i++) {
                if (population[i].alive) {
                    if (i == bestBirdIdx) {
                        display.drawBitmap(birdX, (int)population[i].y, bird_bmp, BIRD_WIDTH, BIRD_HEIGHT, SSD1306_WHITE);
                    } else {
                        display.fillRect(birdX + 4, (int)population[i].y + 2, 3, 3, SSD1306_WHITE);
                    }
                }
            }
        }
        drawGameBorder();
        
        // HUD - Training mode
        display.setTextSize(1);
        display.setCursor(2, 2);
        display.printf("TRN G:%d A:%d B:%d", generation, aliveCount, bestScore);
    } 
    else {
        // FPGA Hardware Inference Mode Loop (Single Bird)
        if (!inferenceBirdAlive) {
            resetInferenceBird();
        }

        // Query the hardware neural network on the FPGA
        if (queryFPGAInference(nextPipeX, nextPipeGapY)) {
            inferenceBirdVel = FLAP_VELOCITY;
        }

        inferenceBirdVel += GRAVITY;
        inferenceBirdY += inferenceBirdVel;

        if (inferenceBirdY < 0 || inferenceBirdY + BIRD_HEIGHT > GROUND_Y) {
            inferenceBirdAlive = false;
        }
        for (int p = 0; p < 2; p++) {
            if (obstacleX[p] < birdX + BIRD_WIDTH && (obstacleX[p] + OBSTACLE_WIDTH) > birdX) {
                float topPipeBottom = obstacleGapY[p] - (obstacleGapSize / 2.0);
                float bottomPipeTop = obstacleGapY[p] + (obstacleGapSize / 2.0);
                if (inferenceBirdY < topPipeBottom || (inferenceBirdY + BIRD_HEIGHT) > bottomPipeTop) {
                    inferenceBirdAlive = false;
                }
            }
        }

        // Move obstacles
        for (int p = 0; p < 2; p++) {
            obstacleX[p] -= obstacleSpeed;
            if (obstacleX[p] < -OBSTACLE_WIDTH) {
                obstacleX[p] = obstacleX[1 - p] + pipeDistance;
                obstacleGapY[p] = 16 + (my_rand() % (GROUND_Y - 32));
                if (inferenceBirdAlive) inferenceScore++;
            }
        }

        // Draw Obstacles
        for (int p = 0; p < 2; p++) {
            display.fillRect(obstacleX[p], 0, OBSTACLE_WIDTH, obstacleGapY[p] - (obstacleGapSize / 2.0), SSD1306_WHITE);
            display.drawRect(obstacleX[p] - 1, obstacleGapY[p] - (obstacleGapSize / 2.0) - 3, OBSTACLE_WIDTH + 2, 3, SSD1306_WHITE);
            display.fillRect(obstacleX[p], obstacleGapY[p] + (obstacleGapSize / 2.0), OBSTACLE_WIDTH, GROUND_Y - (obstacleGapY[p] + (obstacleGapSize / 2.0)), SSD1306_WHITE);
            display.drawRect(obstacleX[p] - 1, obstacleGapY[p] + (obstacleGapSize / 2.0), OBSTACLE_WIDTH + 2, 3, SSD1306_WHITE);
        }

        // Draw Bird
        if (inferenceBirdAlive) {
            display.drawBitmap(birdX, (int)inferenceBirdY, bird_bmp, BIRD_WIDTH, BIRD_HEIGHT, SSD1306_WHITE);
        }
        drawGameBorder();

        // HUD - FPGA Inference mode
        display.setTextSize(1);
        display.setCursor(2, 2);
        display.printf("HW-INF Score:%d Best:%d", inferenceScore, bestScore);
    }

    display.display();
    delay(33);
}
