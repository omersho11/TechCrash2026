# Challenge 08 Prototype

One-way control bridge:

1. FPGA samples `KEY[0]`, `KEY[1]`, and `SW[9:0]`.
2. FPGA sends a 7-byte UART frame 100 times per second.
3. ESP32 receives the FPGA UART on `GPIO17` and forwards the raw bytes over USB serial.
4. Python reads USB serial and displays the live states in a small Tkinter GUI.

## Wiring

- FPGA `ARDUINO_IO[1]` to ESP32 `GPIO17`
- FPGA `GND` to ESP32 `GND`

## Packet

`[0xA5, keys, sw_lo, sw_hi, adc0_norm, adc1_norm, checksum]`

- `keys[0]`: `KEY[0]` pressed
- `keys[1]`: `KEY[1]` pressed
- `sw_lo[7:0]`: `SW[7:0]`
- `sw_hi[1:0]`: `SW[9:8]`
- `adc0_norm`: normalized ADC0 value, `0..255`
- `adc1_norm`: normalized ADC1 value, `0..255`
- `checksum`: XOR of the first six bytes

## Potentiometer

Wire each potentiometer wiper/output to `ADC0` or `ADC1`, with a shared ground. The FPGA normalizes each ADC reading to an 8-bit `0..255` value. The effective full-scale is set to about `2.24 V`, because the observed potentiometer top travel reached about 80% of the earlier `2.8 V` scale.

## Run

FPGA project:

```powershell
cd challenges/challenge_08/fpga
quartus_sh --flow compile control_uart
```

ESP32:

```powershell
cd challenges/challenge_08/esp32
pio run -t upload
```

Python GUI:

```powershell
cd challenges/challenge_08/python
pip install -r requirements.txt
python gui.py --port COM5
```

Lock game:

```powershell
python lock_game.py --port COM5
```

In the game, the left potentiometer turns the lock and the right potentiometer turns the pick. Each attempt starts with the lock fully counter-clockwise; return the left potentiometer to its low end before play begins. Find the right pick angle, turn the lock as far as it will safely go, then readjust for the next pin. The lock stays where it was turned until the player turns the left potentiometer back. Tension only builds while trying to advance the lock and slowly releases afterward. If you force the lock beyond its stop while the pick is in the wrong place, the lock stops turning and the pick breaks. `KEY[0]` also resets the lock.
