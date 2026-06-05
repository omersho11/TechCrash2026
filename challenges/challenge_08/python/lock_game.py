import argparse
import math
import random
import sys
import threading
import time
import tkinter as tk

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    serial = None


FRAME_SYNC = 0xA5
FRAME_LEN = 7
ADC0_RESET_THRESHOLD = 18
START_LOCK_ANGLE = -92.0
UNLOCK_TURN_THRESHOLD = 0.97
LOCK_JITTER_DEADBAND = 0.025
TARGET_ANCHOR_COUNT = 7
TARGET_MIN_ANGLE = -76.0
TARGET_MAX_ANGLE = 76.0
TARGET_MIN_STEP = 28.0
KEY0_MASK = 0x01
KEY1_MASK = 0x02


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def adc_to_angle(value: int) -> float:
    return (clamp(value, 0, 255) / 255.0) * 180.0 - 90.0


def blend_color(a: str, b: str, amount: float) -> str:
    amount = clamp(amount, 0.0, 1.0)
    ar, ag, ab = int(a[1:3], 16), int(a[3:5], 16), int(a[5:7], 16)
    br, bg, bb = int(b[1:3], 16), int(b[3:5], 16), int(b[5:7], 16)
    rr = round(ar + (br - ar) * amount)
    rg = round(ag + (bg - ag) * amount)
    rb = round(ab + (bb - ab) * amount)
    return f"#{rr:02x}{rg:02x}{rb:02x}"


def autodetect_port() -> str | None:
    if serial is None:
        return None

    ports = list(list_ports.comports())
    if not ports:
        return None

    for port in ports:
        text = f"{port.description} {port.hwid}".lower()
        if "usb" in text or "uart" in text or "cp210" in text or "ch340" in text:
            return port.device
    return ports[0].device


class LockGame:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Challenge 08 Lock Game")
        self.root.geometry("760x560")
        self.root.configure(bg="#111318")

        self.canvas = tk.Canvas(root, width=760, height=520, bg="#111318", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)

        self.status_var = tk.StringVar(value="Waiting for serial data")
        self.status = tk.Label(
            root,
            textvariable=self.status_var,
            bg="#111318",
            fg="#e8edf2",
            anchor="w",
            padx=14,
            pady=8,
            font=("Segoe UI", 10),
        )
        self.status.pack(fill="x")

        self.keys = 0
        self.prev_keys = 0
        self.key_press_events = 0
        self.switches = 0
        self.adc0 = 128
        self.adc1 = 128
        self.lock_angle = 0.0
        self.pick_angle = 0.0
        self.lock_turn = 0.0
        self.prev_desired_turn = 0.0
        self.unlock_progress = 0.0
        self.tension = 0.0
        self.pick_health = 1.0
        self.break_flash = 0.0
        self.is_forcing = False
        self.unlocked = False
        self.waiting_for_adc0_reset = True
        self.stage = 0
        self.stage_count = 1
        self.stage_targets = self.make_targets()
        self.last_update = time.monotonic()

        self.root.after(16, self.tick)

    def make_targets(self) -> list[float]:
        targets = [random.uniform(TARGET_MIN_ANGLE, TARGET_MAX_ANGLE)]
        while len(targets) < TARGET_ANCHOR_COUNT:
            candidate = random.uniform(TARGET_MIN_ANGLE, TARGET_MAX_ANGLE)
            if abs(candidate - targets[-1]) >= TARGET_MIN_STEP:
                targets.append(candidate)
        return targets

    def target_angle_at(self, progress: float) -> float:
        if len(self.stage_targets) == 1:
            return self.stage_targets[0]

        scaled = clamp(progress, 0.0, 1.0) * (len(self.stage_targets) - 1)
        idx = min(int(math.floor(scaled)), len(self.stage_targets) - 2)
        local = scaled - idx
        smooth = local * local * (3.0 - 2.0 * local)
        return self.stage_targets[idx] + (self.stage_targets[idx + 1] - self.stage_targets[idx]) * smooth

    def reset(self) -> None:
        self.lock_turn = 0.0
        self.prev_desired_turn = 0.0
        self.unlock_progress = 0.0
        self.tension = 0.0
        self.pick_health = 1.0
        self.break_flash = 0.0
        self.is_forcing = False
        self.unlocked = False
        self.waiting_for_adc0_reset = True
        self.stage = 0
        self.stage_targets = self.make_targets()

    def break_pick(self) -> None:
        self.lock_turn = 0.0
        self.prev_desired_turn = 0.0
        self.unlock_progress = 0.0
        self.tension = 0.0
        self.pick_health = 1.0
        self.break_flash = 0.8
        self.is_forcing = False
        self.unlocked = False
        self.waiting_for_adc0_reset = True
        self.stage = 0
        self.stage_targets = self.make_targets()

    def update_state(self, keys: int, switches: int, adc0: int, adc1: int, source: str) -> None:
        self.key_press_events |= keys & ~self.keys
        self.prev_keys = self.keys
        self.keys = keys
        self.switches = switches
        self.adc0 = adc0
        self.adc1 = adc1
        self.status_var.set(
            f"{source}  lock={adc0:3d}  pick={adc1:3d}  keys=0b{keys:02b}  switches=0x{switches:03X}"
        )

    def tick(self) -> None:
        now = time.monotonic()
        dt = min(0.05, now - self.last_update)
        self.last_update = now

        self.lock_angle = adc_to_angle(self.adc0)
        self.pick_angle = adc_to_angle(self.adc1)

        if self.waiting_for_adc0_reset:
            if self.adc0 <= ADC0_RESET_THRESHOLD:
                self.waiting_for_adc0_reset = False
            self.break_flash = max(0.0, self.break_flash - dt)
            if self.key_pressed(KEY1_MASK):
                self.reset()
            self.draw(0.0, 0.13)
            self.prev_keys = self.keys
            self.root.after(16, self.tick)
            return

        raw_desired_turn = clamp((self.adc0 - ADC0_RESET_THRESHOLD) / (255 - ADC0_RESET_THRESHOLD), 0.0, 1.0)
        if abs(raw_desired_turn - self.prev_desired_turn) < LOCK_JITTER_DEADBAND:
            desired_turn = self.prev_desired_turn
        else:
            desired_turn = raw_desired_turn
        trying_advance = desired_turn > self.lock_turn + 0.015
        lock_input_increasing = desired_turn > self.prev_desired_turn + LOCK_JITTER_DEADBAND
        turning_back = desired_turn < self.lock_turn - 0.015

        target_angle = self.target_angle_at(self.lock_turn)
        alignment = abs(self.pick_angle - target_angle)
        alignment_window = 38.0 if self.tension > 0.15 else 25.0
        quality = max(0.0, 1.0 - alignment / alignment_window)
        misalignment = clamp(alignment / alignment_window, 0.0, 1.0)
        safe_turn = 0.13 + 0.87 * (quality * quality)
        self.is_forcing = False

        if lock_input_increasing:
            self.tension = min(1.0, self.tension + dt * (0.35 + 3.4 * misalignment))
        else:
            self.tension = max(0.0, self.tension - dt * (1.8 + 1.2 * quality))

        if self.unlocked:
            self.lock_turn = 1.0
            self.unlock_progress = 1.0
        elif turning_back:
            self.lock_turn += (desired_turn - self.lock_turn) * min(1.0, dt * 12.0)
        else:
            stopped_turn = min(desired_turn, safe_turn)
            if stopped_turn > self.lock_turn:
                self.lock_turn += (stopped_turn - self.lock_turn) * min(1.0, dt * 10.0)

            if lock_input_increasing and desired_turn > safe_turn + 0.015 and self.lock_turn >= safe_turn - 0.02:
                self.is_forcing = True
                self.pick_health -= dt * (0.45 + 4.4 * misalignment + 2.2 * (desired_turn - safe_turn))
                if self.pick_health <= 0.0:
                    self.break_pick()

        self.unlock_progress = self.lock_turn
        self.prev_desired_turn = desired_turn

        self.break_flash = max(0.0, self.break_flash - dt)

        if self.key_pressed(KEY1_MASK):
            self.reset()
        elif self.key_pressed(KEY0_MASK):
            if self.lock_turn >= UNLOCK_TURN_THRESHOLD:
                self.unlocked = True
                self.lock_turn = 1.0
                self.unlock_progress = 1.0
                self.tension = 0.0
                self.is_forcing = False
            else:
                self.break_pick()

        self.draw(quality, safe_turn)
        self.prev_keys = self.keys
        self.root.after(16, self.tick)

    def key_pressed(self, mask: int) -> bool:
        pressed = bool(self.key_press_events & mask)
        self.key_press_events &= ~mask
        return pressed

    def draw(self, quality: float, safe_turn: float) -> None:
        self.canvas.delete("all")
        w = self.canvas.winfo_width()
        h = self.canvas.winfo_height()
        cx = w / 2
        cy = h / 2 + 18

        if self.unlocked:
            self.draw_congratulations(w, h)
            return

        self.canvas.create_text(
            24,
            22,
            text="The left potentiometer turns the lock    The right potentiometer turns the pick",
            fill="#c8d2dc",
            anchor="w",
            font=("Segoe UI", 13),
        )

        if self.break_flash > 0.0:
            body_color = "#7b2630"
        elif self.unlocked:
            body_color = "#1f8a5b"
        else:
            body_color = "#45606f"

        if self.waiting_for_adc0_reset:
            visual_lock_angle = START_LOCK_ANGLE
        else:
            visual_lock_angle = START_LOCK_ANGLE + self.lock_turn * 184.0

        self.draw_lock_body(cx, cy, body_color, visual_lock_angle, self.tension, quality)
        self.draw_pick(cx, cy, self.pick_angle)
        self.draw_progress(w, self.unlock_progress)
        self.draw_health(cx, cy)

        state_text = f"PIN {self.stage + 1}/{self.stage_count}"
        if self.waiting_for_adc0_reset:
            state_text = "RESET LOCK"
        if self.break_flash > 0.0:
            state_text = "PICK BROKE"
        state_color = "#dce7ee"
        self.canvas.create_text(cx, cy + 132, text=state_text, fill=state_color, font=("Segoe UI", 26, "bold"))
        if self.waiting_for_adc0_reset:
            self.canvas.create_text(
                cx,
                cy - 180,
                text="Turn LOCK all the way counter-clockwise to start.",
                fill="#f0c15a",
                font=("Segoe UI", 17, "bold"),
            )

    def draw_lock_body(self, cx: float, cy: float, body_color: str, cylinder_angle: float, tension: float, quality: float) -> None:
        shackle_color = "#b8c4cc"
        self.canvas.create_arc(cx - 98, cy - 212, cx + 98, cy - 28, start=0, extent=180, style="arc", outline=shackle_color, width=22)
        self.canvas.create_line(cx - 98, cy - 120, cx - 98, cy - 76, fill=shackle_color, width=22)
        self.canvas.create_line(cx + 98, cy - 120, cx + 98, cy - 76, fill=shackle_color, width=22)
        self.canvas.create_rectangle(cx - 154, cy - 86, cx + 154, cy + 118, fill=body_color, outline="#d8e5ee", width=4)
        self.canvas.create_rectangle(cx - 132, cy - 64, cx + 132, cy + 96, fill="#263642", outline="#7f95a5", width=2)
        self.canvas.create_oval(cx - 82, cy - 82, cx + 82, cy + 82, fill="#151b22", outline="#c8d2dc", width=4)
        self.canvas.create_oval(cx - 52, cy - 52, cx + 52, cy + 52, fill="#0d1116", outline="#6a7886", width=2)
        self.draw_cylinder(cx, cy, cylinder_angle, self.correctness_color(quality), tension)

    def correctness_color(self, quality: float) -> str:
        if quality < 0.55:
            return blend_color("#50262e", "#d0a23f", quality / 0.55)
        return blend_color("#d0a23f", "#4fc37a", (quality - 0.55) / 0.45)

    def draw_cylinder(self, cx: float, cy: float, angle: float, fill: str, tension: float) -> None:
        outline = blend_color("#d0a23f", "#f37b7b", tension)
        self.canvas.create_oval(cx - 42, cy - 42, cx + 42, cy + 42, fill=fill, outline=outline, width=3)
        self.draw_rotated_bar(cx, cy, 82, 17, angle, "#05070a", "#9fb1bf")
        radians = math.radians(angle - 90.0)
        knob_x = cx + math.cos(radians) * 54
        knob_y = cy + math.sin(radians) * 54
        self.canvas.create_oval(knob_x - 8, knob_y - 8, knob_x + 8, knob_y + 8, fill="#d0a23f", outline="#fff0bd", width=2)

    def draw_pick(self, cx: float, cy: float, angle: float) -> None:
        self.draw_rotated_bar(cx, cy, 188, 7, angle, "#8edcff", "#e0f8ff")
        radians = math.radians(angle - 90.0)
        tip_x = cx + math.cos(radians) * 152
        tip_y = cy + math.sin(radians) * 152
        hook_x = tip_x + math.cos(radians + 1.2) * 18
        hook_y = tip_y + math.sin(radians + 1.2) * 18
        self.canvas.create_line(tip_x, tip_y, hook_x, hook_y, fill="#e0f8ff", width=4, capstyle="round")

    def draw_rotated_bar(self, cx: float, cy: float, length: float, width: float, angle: float, fill: str, outline: str) -> None:
        radians = math.radians(angle - 90.0)
        dx = math.cos(radians)
        dy = math.sin(radians)
        px = -dy * width / 2
        py = dx * width / 2
        tail = length * 0.18
        tip = length * 0.82
        points = [
            cx - dx * tail + px,
            cy - dy * tail + py,
            cx + dx * tip + px,
            cy + dy * tip + py,
            cx + dx * tip - px,
            cy + dy * tip - py,
            cx - dx * tail - px,
            cy - dy * tail - py,
        ]
        self.canvas.create_polygon(points, fill=fill, outline=outline, width=2)

    def draw_progress(self, width: int, progress: float) -> None:
        x0 = width / 2 - 160
        y0 = 50
        x1 = width / 2 + 160
        y1 = y0 + 8
        self.canvas.create_rectangle(x0, y0, x1, y1, fill="#27313a", outline="#5a6976")
        fill_x = x0 + (x1 - x0) * clamp(progress, 0.0, 1.0)
        self.canvas.create_rectangle(x0, y0, fill_x, y1, fill="#d0a23f", outline="")

    def draw_health(self, cx: float, cy: float) -> None:
        x0 = cx - 120
        y0 = cy + 174
        x1 = cx + 120
        y1 = y0 + 14
        self.canvas.create_rectangle(x0, y0, x1, y1, fill="#252d35", outline="#6a7886")
        health_x = x0 + (x1 - x0) * self.pick_health
        color = "#6ff2a4" if self.pick_health > 0.55 else "#f0c15a" if self.pick_health > 0.25 else "#f37b7b"
        self.canvas.create_rectangle(x0, y0, health_x, y1, fill=color, outline="")
        self.canvas.create_text(cx, y0 - 12, text="pick health", fill="#c8d2dc", font=("Segoe UI", 10))

    def draw_congratulations(self, w: int, h: int) -> None:
        cx = w / 2
        cy = h / 2
        self.canvas.create_rectangle(0, 0, w, h, fill="#111318", outline="")
        self.canvas.create_arc(cx - 92, cy - 184, cx + 92, cy - 8, start=0, extent=180, style="arc", outline="#6ff2a4", width=20)
        self.canvas.create_line(cx - 92, cy - 96, cx - 92, cy - 54, fill="#6ff2a4", width=20)
        self.canvas.create_line(cx + 92, cy - 96, cx + 92, cy - 54, fill="#6ff2a4", width=20)
        self.canvas.create_rectangle(cx - 132, cy - 64, cx + 132, cy + 92, fill="#1f8a5b", outline="#b9ffd3", width=4)
        self.canvas.create_oval(cx - 42, cy - 24, cx + 42, cy + 60, fill="#102419", outline="#b9ffd3", width=3)
        self.canvas.create_text(cx, cy + 130, text="LOCK PICKED", fill="#6ff2a4", font=("Segoe UI", 34, "bold"))
        self.canvas.create_text(cx, cy + 172, text="KEY1 starts a new lock", fill="#dce7ee", font=("Segoe UI", 15))


def read_frames(port: str, baud: int, app: LockGame) -> None:
    if serial is None:
        app.root.after(0, app.status_var.set, "Install pyserial: pip install -r requirements.txt")
        return

    while True:
        try:
            with serial.Serial(port, baud, timeout=1) as ser:
                app.root.after(0, app.status_var.set, f"Connected to {port}")
                while True:
                    byte = ser.read(1)
                    if not byte or byte[0] != FRAME_SYNC:
                        continue

                    payload = ser.read(FRAME_LEN - 1)
                    if len(payload) != FRAME_LEN - 1:
                        continue

                    keys = payload[0] & 0x03
                    switches = payload[1] | ((payload[2] & 0x03) << 8)
                    adc0 = payload[3]
                    adc1 = payload[4]
                    expected = FRAME_SYNC ^ payload[0] ^ payload[1] ^ payload[2] ^ payload[3] ^ payload[4]
                    if payload[5] != expected:
                        continue
                    app.root.after(0, app.update_state, keys, switches, adc0, adc1, port)
        except Exception as exc:
            app.root.after(0, app.status_var.set, f"Serial error: {exc}")
            time.sleep(1)


def main() -> int:
    parser = argparse.ArgumentParser(description="Lock-picking game controlled by Challenge 08 ADC inputs.")
    parser.add_argument("--port", help="Serial port, for example COM5 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()

    root = tk.Tk()
    app = LockGame(root)

    port = args.port or autodetect_port()
    if port is None:
        app.status_var.set("No serial ports found. Reconnect ESP32 or pass --port COMx.")
    else:
        worker = threading.Thread(target=read_frames, args=(port, args.baud, app), daemon=True)
        worker.start()

    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
