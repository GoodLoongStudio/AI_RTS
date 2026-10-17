#!/usr/bin/env python3
"""Record one Windows client area and extract timestamped review sheets.

Requires the existing OpenCV, numpy and Pillow environment. Does not control
game input, change game settings, record audio, or capture the entire desktop.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import sys
import threading
import time

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageGrab


RUNS = Path(__file__).resolve().parents[2] / "agent" / "runs"


def evidence_path(value: str) -> Path:
    path = Path(value).resolve()
    if not path.is_relative_to(RUNS.resolve()):
        raise ValueError(f"Evidence must stay inside {RUNS}")
    return path


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def frame_size(width: int, height: int, max_width: int) -> tuple[int, int]:
    ratio = min(1.0, max_width / width)
    return max(2, int(width * ratio) // 2 * 2), max(2, int(height * ratio) // 2 * 2)


class BitmapInfoHeader(ctypes.Structure):
    _fields_ = [
        ("size", wintypes.DWORD), ("width", wintypes.LONG),
        ("height", wintypes.LONG), ("planes", wintypes.WORD),
        ("bit_count", wintypes.WORD), ("compression", wintypes.DWORD),
        ("size_image", wintypes.DWORD), ("x_ppm", wintypes.LONG),
        ("y_ppm", wintypes.LONG), ("clr_used", wintypes.DWORD),
        ("clr_important", wintypes.DWORD),
    ]


class WindowCapture:
    def __init__(self, pid: int, hwnd: int | None, method: str):
        if os.name != "nt":
            raise RuntimeError("Live capture requires Windows")
        self.user = ctypes.WinDLL("user32", use_last_error=True)
        self.gdi = ctypes.WinDLL("gdi32", use_last_error=True)
        signatures = {
            "GetDC": ([wintypes.HWND], wintypes.HDC),
            "ReleaseDC": ([wintypes.HWND, wintypes.HDC], ctypes.c_int),
            "GetWindowThreadProcessId": ([wintypes.HWND, ctypes.POINTER(wintypes.DWORD)], wintypes.DWORD),
            "GetClientRect": ([wintypes.HWND, ctypes.POINTER(wintypes.RECT)], wintypes.BOOL),
            "ClientToScreen": ([wintypes.HWND, ctypes.POINTER(wintypes.POINT)], wintypes.BOOL),
            "IsWindowVisible": ([wintypes.HWND], wintypes.BOOL),
            "IsIconic": ([wintypes.HWND], wintypes.BOOL),
            "GetForegroundWindow": ([], wintypes.HWND),
            "PrintWindow": ([wintypes.HWND, wintypes.HDC, wintypes.UINT], wintypes.BOOL),
            "GetWindowTextW": ([wintypes.HWND, wintypes.LPWSTR, ctypes.c_int], ctypes.c_int),
        }
        for name, (args, result) in signatures.items():
            func = getattr(self.user, name)
            func.argtypes, func.restype = args, result
        for name, args, result in [
            ("CreateCompatibleDC", [wintypes.HDC], wintypes.HDC),
            ("CreateCompatibleBitmap", [wintypes.HDC, ctypes.c_int, ctypes.c_int], wintypes.HBITMAP),
            ("SelectObject", [wintypes.HDC, wintypes.HANDLE], wintypes.HANDLE),
            ("DeleteObject", [wintypes.HANDLE], wintypes.BOOL),
            ("DeleteDC", [wintypes.HDC], wintypes.BOOL),
            ("GetDIBits", [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                           ctypes.c_void_p, ctypes.POINTER(BitmapInfoHeader), wintypes.UINT], ctypes.c_int),
        ]:
            func = getattr(self.gdi, name)
            func.argtypes, func.restype = args, result
        self.user.SetProcessDPIAware.argtypes = []
        self.user.SetProcessDPIAware.restype = wintypes.BOOL
        self.user.SetProcessDPIAware()
        self.pid, self.method = pid, method
        if hwnd is None:
            windows = []
            callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
            self.user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
            self.user.EnumWindows.restype = wintypes.BOOL

            @callback_type
            def callback(handle, _):
                owner = wintypes.DWORD()
                self.user.GetWindowThreadProcessId(handle, ctypes.byref(owner))
                if owner.value == pid and self.user.IsWindowVisible(handle):
                    rect = wintypes.RECT()
                    self.user.GetClientRect(handle, ctypes.byref(rect))
                    if rect.right > 0 and rect.bottom > 0:
                        windows.append(handle)
                return True

            if not self.user.EnumWindows(callback, 0):
                raise RuntimeError("EnumWindows failed")
            if len(windows) != 1:
                raise RuntimeError(f"PID has {len(windows)} visible windows; supply exact --hwnd")
            hwnd = windows[0]
        self.hwnd = hwnd
        self.dimensions = self.check()[0]
        title = ctypes.create_unicode_buffer(1024)
        self.user.GetWindowTextW(hwnd, title, len(title))
        self.title = title.value

    def check(self):
        owner = wintypes.DWORD()
        self.user.GetWindowThreadProcessId(self.hwnd, ctypes.byref(owner))
        if owner.value != self.pid:
            raise RuntimeError("Window disappeared or no longer belongs to target PID")
        if not self.user.IsWindowVisible(self.hwnd) or self.user.IsIconic(self.hwnd):
            raise RuntimeError("Target is hidden/minimized; capture is not gameplay evidence")
        rect, point = wintypes.RECT(), wintypes.POINT()
        if not self.user.GetClientRect(self.hwnd, ctypes.byref(rect)):
            raise RuntimeError("GetClientRect failed")
        if rect.right < 2 or rect.bottom < 2:
            raise RuntimeError("Empty client area")
        self.user.ClientToScreen(self.hwnd, ctypes.byref(point))
        foreground = self.user.GetForegroundWindow() == self.hwnd
        if self.method == "screen" and not foreground:
            raise RuntimeError("Target lost foreground; refusing to capture other application pixels")
        return (rect.right, rect.bottom), (point.x, point.y), foreground

    def grab(self):
        dimensions, origin, foreground = self.check()
        if dimensions != self.dimensions:
            raise RuntimeError("Window resized; stop and start a separate clip")
        width, height = dimensions
        if self.method == "screen":
            x, y = origin
            rgb = ImageGrab.grab(bbox=(x, y, x + width, y + height), all_screens=True)
            # A foreground change during capture invalidates this frame too.
            self.check()
            frame = cv2.cvtColor(np.asarray(rgb), cv2.COLOR_RGB2BGR)
        else:
            source = self.user.GetDC(self.hwnd)
            memory = self.gdi.CreateCompatibleDC(source)
            bitmap = self.gdi.CreateCompatibleBitmap(source, width, height)
            old = self.gdi.SelectObject(memory, bitmap)
            try:
                if not source or not memory or not bitmap or not old:
                    raise RuntimeError("Could not allocate capture bitmap")
                if not self.user.PrintWindow(self.hwnd, memory, 3):
                    raise RuntimeError("PrintWindow failed; use --method screen with verified focus")
                self.gdi.SelectObject(memory, old)
                info = BitmapInfoHeader(size=ctypes.sizeof(BitmapInfoHeader), width=width,
                                        height=-height, planes=1, bit_count=32, compression=0)
                pixels = (ctypes.c_ubyte * (width * height * 4))()
                if self.gdi.GetDIBits(memory, bitmap, 0, height, pixels, ctypes.byref(info), 0) != height:
                    raise RuntimeError("GetDIBits failed")
                frame = np.ctypeslib.as_array(pixels).reshape(height, width, 4)[:, :, :3].copy()
            finally:
                self.gdi.SelectObject(memory, old)
                self.gdi.DeleteObject(bitmap)
                self.gdi.DeleteDC(memory)
                self.user.ReleaseDC(self.hwnd, source)
        return frame, foreground


class CaptureWorker:
    """Keep a hung PrintWindow call from blocking recorder finalization."""

    def __init__(self, target):
        self.requests, self.results = queue.Queue(maxsize=1), queue.Queue(maxsize=1)

        def work():
            while self.requests.get():
                try:
                    result = (target.grab(), None)
                except Exception as exc:
                    result = (None, str(exc))
                self.results.put(result)

        threading.Thread(target=work, daemon=True).start()

    def grab(self):
        self.requests.put(True)
        try:
            result, error = self.results.get(timeout=3)
        except queue.Empty:
            raise RuntimeError("Capture timed out after 3 seconds") from None
        if error:
            raise RuntimeError(error)
        return result


def record(args) -> int:
    output = evidence_path(args.output)
    if output.suffix.lower() != ".mp4":
        raise ValueError("Use an .mp4 output file")
    metadata = output.with_suffix(".json")
    timing = output.with_suffix(".frames.jsonl")
    if any(path.exists() for path in (output, metadata, timing)):
        raise ValueError("Refusing to overwrite existing evidence")
    target = WindowCapture(args.pid, args.hwnd, args.method)
    info = {"pid": args.pid, "hwnd": target.hwnd, "title": target.title,
            "method": args.method, "source_size": target.dimensions, "fps": args.fps,
            "requested_seconds": args.seconds, "audio": False,
            "output": str(output), "timing": str(timing), "started_at_utc": now_utc()}
    if args.dry_run:
        print(json.dumps(info, ensure_ascii=True, indent=2))
        return 0
    output.parent.mkdir(parents=True, exist_ok=True)
    width, height = frame_size(*target.dimensions, args.max_width)
    writer = cv2.VideoWriter(str(output), cv2.VideoWriter_fourcc(*"mp4v"), args.fps, (width, height + 24))
    if not writer.isOpened():
        writer.release()
        raise RuntimeError("mp4v encoder unavailable in this Python/OpenCV runtime")
    capture = CaptureWorker(target)
    frames, duplicates, changed, dark_frames = 0, 0, 0, 0
    last_frame = last_hash = None
    error = None
    start = time.perf_counter()
    info.update(started_at_utc=now_utc(), start_monotonic_s=start)
    count = math.ceil(args.seconds * args.fps)
    print(json.dumps({"event": "RECORD_START", **info}), flush=True)
    try:
        with timing.open("x", encoding="utf-8") as log:
            while frames < count:
                due = frames / args.fps
                remaining = due - (time.perf_counter() - start)
                if remaining > 0:
                    time.sleep(remaining)
                elapsed = time.perf_counter() - start
                # Preserve wall-clock gaps, but label encoder filler as NOT observed gameplay.
                duplicate = last_frame is not None and elapsed - due >= 1 / args.fps
                if duplicate:
                    target.check()
                    frame = last_frame.copy()
                    foreground = target.user.GetForegroundWindow() == target.hwnd
                    captured_at = None
                    capture_duration_ms = None
                    duplicates += 1
                else:
                    capture_start = time.perf_counter()
                    raw, foreground = capture.grab()
                    captured_at = time.perf_counter() - start
                    capture_duration_ms = (time.perf_counter() - capture_start) * 1000
                    if raw.max() < 5:
                        dark_frames += 1
                        if dark_frames >= 3:
                            raise RuntimeError("Three black captures; verify backend before continuing")
                    else:
                        dark_frames = 0
                    frame = cv2.resize(raw, (width, height), interpolation=cv2.INTER_AREA)
                    digest = hashlib.sha256(cv2.resize(frame, (64, 36)).tobytes()).hexdigest()
                    changed += int(last_hash is not None and digest != last_hash)
                    last_hash, last_frame = digest, frame.copy()
                displayed = cv2.copyMakeBorder(frame, 0, 24, 0, 0, cv2.BORDER_CONSTANT, value=(0, 0, 0))
                label = f"video={due:.3f}s pid={args.pid} " + ("DUPLICATE / UNOBSERVED" if duplicate else f"capture={captured_at:.3f}s")
                cv2.putText(displayed, label, (8, height + 17), cv2.FONT_HERSHEY_SIMPLEX, .42, (255, 255, 255), 1)
                writer.write(displayed)
                row = {"frame": frames, "video_s": due, "elapsed_s": elapsed,
                       "captured_s": captured_at, "duplicate": duplicate,
                       "capture_duration_ms": capture_duration_ms,
                       "foreground": bool(foreground), "pixel_hash": last_hash}
                log.write(json.dumps(row) + "\n")
                log.flush()
                frames += 1
    except KeyboardInterrupt:
        error = "interrupted"
    except Exception as exc:
        error = str(exc)
    finally:
        writer.release()
        wall_seconds = time.perf_counter() - start
        info.update(ended_at_utc=now_utc(), wall_seconds=wall_seconds, frames=frames,
                    video_seconds=frames / args.fps, duplicate_frames=duplicates,
                    changing_observed_frames=changed, error=error,
                    status="complete" if error is None and frames == count else "partial",
                    game_input_verified=False, game_performance_verified=False)
        metadata.write_text(json.dumps(info, indent=2, ensure_ascii=True), encoding="utf-8")
    decoder = cv2.VideoCapture(str(output))
    readable, _ = decoder.read()
    decoder.release()
    if not readable:
        info["status"], info["error"] = "partial", info["error"] or "Video could not be decoded"
        metadata.write_text(json.dumps(info, indent=2), encoding="utf-8")
    print(json.dumps(info, indent=2, ensure_ascii=True))
    return 0 if info["status"] == "complete" else 2


def review(args) -> int:
    video, out = Path(args.video).resolve(), evidence_path(args.out)
    if not video.is_file():
        raise ValueError("Video not found")
    if out.exists():
        raise ValueError("Use a new review directory; refusing to overwrite evidence")
    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        raise ValueError("Video could not be decoded")
    try:
        fps = capture.get(cv2.CAP_PROP_FPS)
        count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
        if fps <= 0 or count <= 0:
            raise ValueError("Invalid video metadata")
        end = min(args.end if args.end is not None else count / fps, count / fps)
        if not 0 <= args.start < end:
            raise ValueError("Review start/end outside video")
        requested = math.ceil((end - args.start) / args.step)
        if requested > 240:
            raise ValueError("Review at most 240 frames per call; split into consecutive ranges")
        out.mkdir(parents=True)
        entries, tiles, sheet_number = [], [], 1

        def save_sheet():
            nonlocal sheet_number
            if not tiles:
                return
            sheet = Image.new("RGB", (384 * 3, 244 * math.ceil(len(tiles) / 3)), "#202020")
            for i, tile in enumerate(tiles):
                sheet.paste(tile, (i % 3 * 384, i // 3 * 244))
            sheet.save(out / f"sheet-{sheet_number:03d}.jpg", quality=90)
            sheet_number += 1
            tiles.clear()

        seen = set()
        for i in range(requested):
            index = round((args.start + i * args.step) * fps)
            if index >= count or index in seen:
                continue
            seen.add(index)
            capture.set(cv2.CAP_PROP_POS_FRAMES, index)
            ok, frame = capture.read()
            if not ok:
                raise RuntimeError(f"Decode failed at frame {index}")
            image = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            filename = f"frame-{index:07d}.jpg"
            image.save(out / filename, quality=94)
            image.thumbnail((384, 216))
            tile = Image.new("RGB", (384, 244), "#202020")
            tile.paste(image, ((384 - image.width) // 2, 0))
            ImageDraw.Draw(tile).text((8, 224), f"t={index / fps:.3f}s frame={index}", fill="white")
            tiles.append(tile)
            entries.append({"frame": index, "video_s": index / fps, "file": filename,
                            "sheet": f"sheet-{sheet_number:03d}.jpg"})
            if len(tiles) == 12:
                save_sheet()
        save_sheet()
        (out / "index.json").write_text(json.dumps({"video": str(video), "fps": fps,
            "start": args.start, "end": end, "step": args.step, "entries": entries}, indent=2), encoding="utf-8")
        print(json.dumps({"status": "extracted_not_reviewed", "frames": len(entries),
                          "sheets": sheet_number - 1, "out": str(out)}))
        return 0
    finally:
        capture.release()


def bounded_float(low, high):
    def parse(value):
        number = float(value)
        if not math.isfinite(number) or not low <= number <= high:
            raise argparse.ArgumentTypeError(f"Expected {low}..{high}")
        return number
    return parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    rec = commands.add_parser("record")
    rec.add_argument("--pid", type=int, required=True)
    rec.add_argument("--hwnd", type=lambda value: int(value, 0))
    rec.add_argument("--output", required=True)
    rec.add_argument("--method", choices=("printwindow", "screen"), default="printwindow")
    rec.add_argument("--fps", type=bounded_float(1, 30), default=5)
    rec.add_argument("--seconds", type=bounded_float(.2, 1800), default=120)
    rec.add_argument("--max-width", type=int, choices=(640, 960, 1280, 1920), default=1280)
    rec.add_argument("--dry-run", action="store_true")
    rec.set_defaults(func=record)
    rev = commands.add_parser("review")
    rev.add_argument("--video", required=True)
    rev.add_argument("--out", required=True)
    rev.add_argument("--start", type=bounded_float(0, 36000), default=0)
    rev.add_argument("--end", type=bounded_float(.01, 36000))
    rev.add_argument("--step", type=bounded_float(.01, 60), default=.5)
    rev.set_defaults(func=review)
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:
        print(json.dumps({"status": "failed", "error": str(exc)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
