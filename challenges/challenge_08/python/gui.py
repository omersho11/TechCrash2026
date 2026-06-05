import argparse
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    serial = None


FRAME_SYNC = 0xA5
FRAME_LEN = 7


class StateDisplay:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Challenge 08 Controls")
        self.root.geometry("420x360")

        self.status_var = tk.StringVar(value="Waiting for serial data")
        self.key_vars = [tk.StringVar(value="released") for _ in range(2)]
        self.sw_vars = [tk.IntVar(value=0) for _ in range(10)]
        self.adc_vars = [tk.StringVar(value="0 / 255") for _ in range(2)]
        self.adc_bar_vars = [tk.IntVar(value=0) for _ in range(2)]

        frame = ttk.Frame(root, padding=16)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, textvariable=self.status_var).pack(anchor="w", pady=(0, 12))

        keys = ttk.LabelFrame(frame, text="KEY")
        keys.pack(fill="x", pady=(0, 12))
        for idx, var in enumerate(self.key_vars):
            row = ttk.Frame(keys, padding=(8, 4))
            row.pack(fill="x")
            ttk.Label(row, text=f"KEY[{idx}]", width=10).pack(side="left")
            ttk.Label(row, textvariable=var).pack(side="left")

        switches = ttk.LabelFrame(frame, text="SW")
        switches.pack(fill="both", expand=True)
        for idx, var in enumerate(self.sw_vars):
            row = ttk.Frame(switches, padding=(8, 2))
            row.grid(row=idx // 2, column=idx % 2, sticky="w", padx=8, pady=2)
            ttk.Label(row, text=f"SW[{idx}]", width=8).pack(side="left")
            ttk.Checkbutton(row, variable=var, state="disabled").pack(side="left")

        analog = ttk.LabelFrame(frame, text="ADC")
        analog.pack(fill="x", pady=(12, 0))
        for idx in range(2):
            adc_row = ttk.Frame(analog, padding=(8, 4))
            adc_row.pack(fill="x")
            ttk.Label(adc_row, text=f"ADC{idx}", width=6).pack(side="left")
            ttk.Label(adc_row, textvariable=self.adc_vars[idx], width=12).pack(side="left")
            ttk.Progressbar(adc_row, variable=self.adc_bar_vars[idx], maximum=255).pack(side="left", fill="x", expand=True)

    def update_state(self, keys: int, switches: int, adc0: int, adc1: int, source: str) -> None:
        for idx in range(2):
            pressed = bool(keys & (1 << idx))
            self.key_vars[idx].set("pressed" if pressed else "released")

        for idx in range(10):
            self.sw_vars[idx].set(1 if switches & (1 << idx) else 0)

        for idx, value in enumerate((adc0, adc1)):
            percent = int((value * 100) / 255)
            self.adc_vars[idx].set(f"{value:3d} / 255  {percent:3d}%")
            self.adc_bar_vars[idx].set(value)
        self.status_var.set(
            f"{source}  keys=0b{keys:02b}  switches=0x{switches:03X}  adc0={adc0}  adc1={adc1}"
        )


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


def read_frames(port: str, baud: int, app: StateDisplay) -> None:
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
    parser = argparse.ArgumentParser(description="Display DE10-Lite KEY/SW state from ESP32 USB serial.")
    parser.add_argument("--port", help="Serial port, for example COM5 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()

    root = tk.Tk()
    app = StateDisplay(root)

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
