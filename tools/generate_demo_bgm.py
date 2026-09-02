#!/usr/bin/env python3
"""生成 Demo 用原创循环 BGM（16-bit PCM WAV，无外部采样）。

对局曲按工业管弦 + 电子节奏的 RTS 战斗乐来写，不使用任何现成游戏原曲。
"""

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
    "music",
)


def clamp(value: float, low: float = -1.0, high: float = 1.0) -> float:
    return low if value < low else high if value > high else value


def write_wav(name: str, samples) -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    path = os.path.join(OUTPUT_DIR, name)
    if hasattr(samples, "astype"):
        pcm = (samples.clip(-1.0, 1.0) * 32767.0).astype("<i2").tobytes()
    else:
        pcm = b"".join(struct.pack("<h", int(clamp(float(sample)) * 32767.0)) for sample in samples)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm)


def midi(note: float) -> float:
    return 440.0 * (2.0 ** ((note - 69.0) / 12.0))


def sine(phase: float) -> float:
    return math.sin(phase)


def soft_square(phase: float) -> float:
    return math.tanh(2.4 * math.sin(phase))


def render_menu_theme() -> list[float]:
    seconds = 32.0
    bpm = 84.0
    chords = [
        [57, 60, 64],
        [53, 57, 60],
        [48, 52, 55],
        [55, 59, 62],
    ]
    count = int(SAMPLE_RATE * seconds)
    beat = 60.0 / bpm
    bar = beat * 4.0
    samples = [0.0] * count
    for index in range(count):
        time = index / SAMPLE_RATE
        chord = chords[int(time / bar) % len(chords)]
        local = time % bar
        pad = 0.0
        for note in chord:
            freq = midi(note)
            pad += sine(2.0 * math.pi * freq * time) * 0.16
            pad += sine(2.0 * math.pi * freq * 0.5 * time) * 0.07
        eighth = beat * 0.5
        arp = sine(2.0 * math.pi * midi(chord[index % len(chord)] + 12) * time)
        arp *= 0.08 * max(0.0, 1.0 - ((time % eighth) / eighth))
        bass = soft_square(2.0 * math.pi * midi(chord[0] - 12) * time) * 0.11
        lift = 0.55 + 0.45 * math.sin(2.0 * math.pi * local / bar)
        samples[index] = (pad * lift + arp + bass) * 0.72
    return _make_seamless(samples)


def render_match_theme(np):
    """对局曲：弦乐垫、持续低音和长铜管，不含军鼓/踩镲脉冲。"""
    bpm = 96.0
    beat = 60.0 / bpm
    bar = beat * 4.0
    bars = 32
    count = int(SAMPLE_RATE * bar * bars)
    time = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    bar_index = np.minimum((time / bar).astype(np.int32), bars - 1)
    local = time % bar

    cycle = [
        (48, 51, 55, 60),
        (48, 51, 55, 58),
        (44, 48, 51, 56),
        (51, 55, 58, 63),
        (46, 50, 53, 58),
        (43, 46, 50, 55),
        (44, 48, 51, 58),
        (47, 50, 53, 59),
    ]
    roots = np.array([cycle[int(i) % 8][0] for i in bar_index], dtype=np.float64)
    thirds = np.array([cycle[int(i) % 8][1] for i in bar_index], dtype=np.float64)
    fifths = np.array([cycle[int(i) % 8][2] for i in bar_index], dtype=np.float64)
    highs = np.array([cycle[int(i) % 8][3] for i in bar_index], dtype=np.float64)
    section = bar_index // 8

    bass_freq = _midi_np(np, roots - 12.0)
    bass = np.tanh(1.8 * np.sin(2.0 * math.pi * bass_freq * time)) * 0.16
    bass += np.sin(2.0 * math.pi * bass_freq * 0.5 * time) * 0.05

    pad = (
        np.sin(2.0 * math.pi * _midi_np(np, roots) * time) * 0.12
        + np.sin(2.0 * math.pi * _midi_np(np, thirds) * time) * 0.11
        + np.sin(2.0 * math.pi * _midi_np(np, fifths) * time) * 0.10
        + np.sin(2.0 * math.pi * _midi_np(np, roots) * 1.002 * time) * 0.04
    )
    pad *= 0.72 + 0.28 * np.sin(2.0 * math.pi * local / bar)

    line = np.sin(2.0 * math.pi * _midi_np(np, highs) * time)
    line += 0.35 * np.sin(2.0 * math.pi * _midi_np(np, fifths + 12.0) * time)
    line *= (0.35 + 0.65 * (0.5 + 0.5 * np.sin(2.0 * math.pi * local / (bar * 2.0)))) * 0.08
    line *= np.where(section >= 1, 1.0, 0.45)

    brass = np.tanh(
        2.2
        * (
            np.sin(2.0 * math.pi * _midi_np(np, fifths) * time)
            + 0.28 * np.sin(4.0 * math.pi * _midi_np(np, fifths) * time)
        )
    )
    brass_env = 0.5 + 0.5 * np.sin(math.pi * local / bar)
    brass *= brass_env * 0.09 * np.where(section >= 2, 1.0, 0.4)

    mix = bass + pad + line + brass
    mix = np.tanh(mix * 1.05)
    return _make_seamless_np(np, mix)


def _midi_np(np, notes):
    return 440.0 * (2.0 ** ((notes - 69.0) / 12.0))


def _highpass_np(np, values, amount: float):
    delayed = np.empty_like(values)
    delayed[0] = values[0]
    delayed[1:] = values[:-1]
    return values - delayed * amount


def _make_seamless(samples: list[float]) -> list[float]:
    count = len(samples)
    fade = int(SAMPLE_RATE * 0.14)
    seamless = [0.0] * (count - fade)
    for index in range(count - fade):
        if index < fade:
            mix = index / fade
            seamless[index] = samples[index] * mix + samples[count - fade + index] * (1.0 - mix)
        else:
            seamless[index] = samples[index]
    peak = max(abs(sample) for sample in seamless) or 1.0
    return [sample * 0.88 / peak for sample in seamless]


def _make_seamless_np(np, samples):
    fade = int(SAMPLE_RATE * 0.14)
    body = samples[:-fade].copy()
    ramp = np.linspace(0.0, 1.0, fade)
    body[:fade] = samples[:fade] * ramp + samples[-fade:] * (1.0 - ramp)
    peak = float(np.max(np.abs(body))) or 1.0
    return body * (0.88 / peak)


def main() -> None:
    try:
        import numpy as np
    except ImportError as error:
        raise SystemExit("生成对局曲需要 numpy：python -m pip install numpy") from error

    write_wav("match_theme.wav", render_match_theme(np))
    print("wrote original BGM to", OUTPUT_DIR)


if __name__ == "__main__":
    main()
