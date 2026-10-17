"""Offline recorder checks. The optional smoke test records only a test window."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest
from datetime import datetime

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "dev" / "record_playtest.py"
spec = importlib.util.spec_from_file_location("record_playtest", SCRIPT)
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class RecorderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = ROOT / "agent" / "runs" / ("recorder-unit-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
        cls.out.mkdir(parents=True)

    def test_evidence_boundary(self):
        self.assertEqual(recorder.evidence_path(str(self.out / "file.mp4")), self.out / "file.mp4")
        for path in (ROOT / "build" / "file.mp4", ROOT / "agent" / "runs" / ".." / "bad.mp4"):
            with self.assertRaises(ValueError):
                recorder.evidence_path(str(path))

    def test_frame_size_and_bounds(self):
        self.assertEqual(recorder.frame_size(1920, 1080, 1280), (1280, 720))
        self.assertEqual(recorder.frame_size(301, 201, 1280), (300, 200))
        for value in ("nan", "inf", "0", "31"):
            with self.assertRaises(argparse.ArgumentTypeError):
                recorder.bounded_float(1, 30)(value)

    def test_temporal_review_and_no_overwrite(self):
        video = self.out / "known-motion.mp4"
        writer = cv2.VideoWriter(str(video), cv2.VideoWriter_fourcc(*"mp4v"), 10, (320, 180))
        self.assertTrue(writer.isOpened())
        for index in range(30):
            frame = np.zeros((180, 320, 3), dtype=np.uint8)
            cv2.rectangle(frame, (index * 8, 40), (index * 8 + 25, 100), (20, 240, 80), -1)
            writer.write(frame)
        writer.release()
        args = argparse.Namespace(video=str(video), out=str(self.out / "review"), start=0, end=3, step=.2)
        self.assertEqual(recorder.review(args), 0)
        data = json.loads((self.out / "review" / "index.json").read_text())
        self.assertEqual(len(data["entries"]), 15)
        self.assertEqual(data["entries"][-1]["frame"], 28)
        self.assertTrue((self.out / "review" / "sheet-002.jpg").exists())
        first = cv2.imread(str(self.out / "review" / data["entries"][0]["file"]))
        last = cv2.imread(str(self.out / "review" / data["entries"][-1]["file"]))
        self.assertGreater(float(np.mean(cv2.absdiff(first, last))), 1)
        with self.assertRaises(ValueError):
            recorder.review(args)
        args.out, args.start = str(self.out / "bad-review"), 5
        with self.assertRaises(ValueError):
            recorder.review(args)


def window_fixture():
    import tkinter as tk

    root = tk.Tk()
    root.title("AIRTS recorder synthetic fixture (not game)")
    root.geometry("420x240")
    root.update_idletasks()
    root.withdraw()
    root.geometry("420x240+-2500+-2500")
    canvas = tk.Canvas(root, background="#204030", highlightthickness=0)
    canvas.pack(fill="both", expand=True)
    root.update_idletasks()
    root.deiconify()
    root.update()
    dot = canvas.create_rectangle(10, 80, 40, 110, fill="#ee3388")
    canvas.create_text(210, 30, text="SYNTHETIC TEST WINDOW", fill="white")
    frame = 0

    def animate():
        nonlocal frame
        frame += 1
        x = 10 + (frame * 5) % 360
        canvas.coords(dot, x, 80, x + 30, 110)
        root.after(50, animate)

    animate()
    root.after(20000, root.destroy)
    root.mainloop()


def window_smoke():
    out = ROOT / "agent" / "runs" / ("recorder-smoke-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    out.mkdir(parents=True)
    print("SMOKE_OUTPUT=" + str(out), flush=True)
    with (out / "stdout.log").open("w") as stdout, (out / "stderr.log").open("w") as stderr:
        fixture = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--window-fixture"],
                                   stdout=stdout, stderr=stderr, creationflags=0x08000000)
        try:
            time.sleep(1)
            command = [sys.executable, str(SCRIPT), "record", "--pid", str(fixture.pid),
                       "--output", str(out / "synthetic-window.mp4"), "--fps", "5", "--seconds", "4"]
            result = subprocess.run(command, stdout=stdout, stderr=stderr,
                                    timeout=15, creationflags=0x08000000)
            if result.returncode != 0:
                raise RuntimeError((out / "stdout.log").read_text() + (out / "stderr.log").read_text())
        finally:
            if fixture.poll() is None:
                fixture.terminate()
            fixture.wait(timeout=5)
    metadata = json.loads((out / "synthetic-window.json").read_text())
    assert metadata["frames"] == 20, metadata
    assert metadata["changing_observed_frames"] > 2, metadata
    recorder.review(argparse.Namespace(video=str(out / "synthetic-window.mp4"),
                    out=str(out / "review"), start=0, end=4, step=.2))
    print("WINDOW_CAPTURE_SMOKE_OK (synthetic, not gameplay)")


if __name__ == "__main__":
    if "--window-smoke" in sys.argv:
        window_smoke()
    elif "--window-fixture" in sys.argv:
        window_fixture()
    else:
        unittest.main()
