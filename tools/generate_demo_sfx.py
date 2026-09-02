#!/usr/bin/env python3
"""生成 Demo 用的原创合成音效（16-bit PCM WAV，可商用、无外部采样）。"""

from __future__ import annotations

import math
import os
import struct
import wave

SAMPLE_RATE = 44100
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets",
    "audio",
    "sfx",
)


def clamp(value: float, low: float = -1.0, high: float = 1.0) -> float:
    return low if value < low else high if value > high else value


def write_wav(name: str, samples: list[float]) -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    path = os.path.join(OUTPUT_DIR, name)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        frames = b"".join(
            struct.pack("<h", int(clamp(sample) * 32767.0)) for sample in samples
        )
        handle.writeframes(frames)


def noise(index: int, seed: int) -> float:
    x = (index * 1103515245 + seed * 12345) & 0x7FFFFFFF
    return (x / 0x7FFFFFFF) * 2.0 - 1.0


def envelope(time: float, attack: float, hold: float, release: float) -> float:
    if time < 0.0:
        return 0.0
    if time < attack:
        return time / attack if attack > 0.0 else 1.0
    if time < attack + hold:
        return 1.0
    if time < attack + hold + release:
        return 1.0 - (time - attack - hold) / release
    return 0.0


def tone(time: float, frequency: float) -> float:
    return math.sin(2.0 * math.pi * frequency * time)


def render(seconds: float, fn) -> list[float]:
    count = int(SAMPLE_RATE * seconds)
    return [clamp(fn(index / SAMPLE_RATE, index)) for index in range(count)]


def make_ui_click() -> list[float]:
    return render(
        0.06,
        lambda t, i: (
            tone(t, 2100.0) * 0.35 + tone(t, 4200.0) * 0.12 + noise(i, 3) * 0.08
        )
        * envelope(t, 0.002, 0.008, 0.04),
    )


def make_unit_select() -> list[float]:
    return render(
        0.11,
        lambda t, i: (
            tone(t, 520.0 if t < 0.045 else 780.0) * 0.42
            + tone(t, 1560.0) * 0.06
        )
        * envelope(t, 0.004, 0.03, 0.07),
    )


def make_cannon_fire() -> list[float]:
    return render(
        0.32,
        lambda t, i: (
            tone(t, 78.0 - t * 40.0) * 0.55 * math.exp(-t * 7.0)
            + tone(t, 190.0) * 0.18 * math.exp(-t * 12.0)
            + noise(i, 11) * 0.42 * math.exp(-t * 16.0)
        ),
    )


def make_rocket_fire() -> list[float]:
    return render(
        0.28,
        lambda t, i: (
            tone(t, 220.0 + t * 900.0) * 0.22
            + (noise(i, 21) - noise(i - 1, 21)) * 0.28 * math.exp(-t * 4.0)
            + tone(t, 90.0) * 0.12 * math.exp(-t * 5.0)
        )
        * envelope(t, 0.01, 0.08, 0.18),
    )


def make_impact() -> list[float]:
    return render(
        0.24,
        lambda t, i: (
            tone(t, 130.0) * 0.5 * math.exp(-t * 14.0)
            + tone(t, 340.0) * 0.16 * math.exp(-t * 22.0)
            + noise(i, 41) * 0.38 * math.exp(-t * 18.0)
        ),
    )


def make_unit_death() -> list[float]:
    return render(
        0.42,
        lambda t, i: (
            tone(t, 320.0 - t * 520.0) * 0.38
            + tone(t, 160.0 - t * 220.0) * 0.22
            + noise(i, 61) * 0.18 * math.exp(-t * 6.0)
        )
        * envelope(t, 0.008, 0.12, 0.28),
    )


def make_construction() -> list[float]:
    return render(
        0.38,
        lambda t, i: (
            tone(t, 523.25) * 0.28 * math.exp(-t * 5.5)
            + tone(t, 659.25) * 0.22 * math.exp(-max(t - 0.06, 0.0) * 5.0)
            + tone(t, 784.0) * 0.1 * math.exp(-max(t - 0.12, 0.0) * 6.0)
        ),
    )


def main() -> None:
    write_wav("ui_click.wav", make_ui_click())
    write_wav("unit_select.wav", make_unit_select())
    write_wav("cannon_fire.wav", make_cannon_fire())
    write_wav("rocket_fire.wav", make_rocket_fire())
    write_wav("impact.wav", make_impact())
    write_wav("unit_death.wav", make_unit_death())
    write_wav("construction_complete.wav", make_construction())
    print("wrote 7 original wav files to", OUTPUT_DIR)


if __name__ == "__main__":
    main()
