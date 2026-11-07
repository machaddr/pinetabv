#!/usr/bin/env python3
"""Exercise camera selection and capture validation without tablet hardware."""

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name('capture-pinetabv-camera.py')
SPEC = importlib.util.spec_from_file_location('pinetabv_camera', MODULE_PATH)
camera = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = camera
SPEC.loader.exec_module(camera)

TOPOLOGY = '''Media controller API version 7.3.0
Media device information
------------------------
driver          starfive-camss
model           Starfive Camera Subsystem
Device topology
- entity 1: gc02m2 6-0037 (1 pad, 1 link)
    pad0: Source
        -> "video-mux":0 [ENABLED]
- entity 3: ov5640 6-003c (1 pad, 1 link)
    pad0: Source
        -> "video-mux":1 []
- entity 5: video-mux (3 pads, 3 links)
    pad0: Sink
        <- "gc02m2 6-0037":0 [ENABLED]
    pad1: Sink
        <- "ov5640 6-003c":0 []
    pad2: Source
        -> "cdns-csi2rx.19800000.csi-bridge":0 [ENABLED,IMMUTABLE]
- entity 9: cdns-csi2rx.19800000.csi-bridge (5 pads, 3 links)
    pad0: Sink
        <- "video-mux":2 [ENABLED,IMMUTABLE]
    pad3: Source
        -> "stf_isp":0 [ENABLED]
        -> "capture_raw":0 [ENABLED]
- entity 15: stf_isp (2 pads, 2 links)
    pad0: Sink
        <- "cdns-csi2rx.19800000.csi-bridge":3 [ENABLED]
    pad1: Source
        -> "capture_yuv":0 [ENABLED]
- entity 18: capture_yuv (1 pad, 1 link)
    pad0: Sink
        <- "stf_isp":1 [ENABLED]
- entity 20: capture_raw (1 pad, 1 link)
    pad0: Sink
        <- "cdns-csi2rx.19800000.csi-bridge":3 [ENABLED]
'''


class CameraCaptureTest(unittest.TestCase):
    def exercise(self, selected, *, incomplete=False, configure_only=False):
        calls = []
        width, height = (1280, 720) if selected == 'front' else (640, 480)
        code = 'SRGGB10_1X10' if selected == 'front' else 'SRGGB8_1X8'
        size = width * height * 3 // 2
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'capture.nv12'

            def fake_run(command, **kwargs):
                calls.append(command)
                if command[-1] == '-p':
                    return TOPOLOGY
                if '-e' in command:
                    return '/dev/video17\n'
                if '--get-v4l2' in command:
                    return f'[fmt:{code}/{width}x{height} field:none]\n'
                if '--get-fmt-video' in command:
                    return (f'Width/Height : {width}/{height}\n'
                            f'Bytes per Line : {width}\nSize Image : {size}\n')
                if '--stream-mmap=4' in command:
                    output.write_bytes(b'\x00' * (size * (1 if incomplete else 2)))
                return ''

            argv = [str(MODULE_PATH), '--camera', selected, '--media', '/dev/media4']
            if configure_only:
                argv.append('--configure-only')
            else:
                argv += ['--output', str(output), '--frames', '2']
            with patch.object(camera, 'run', side_effect=fake_run), \
                    patch.object(camera.shutil, 'which', return_value='/usr/bin/mock'), \
                    patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
                camera.main()
        return calls

    def test_rear_disables_front_before_switching(self):
        calls = self.exercise('rear')
        changes = [args[-1] for args in calls if '-l' in args]
        self.assertLess(changes.index('"gc02m2 6-0037":0 -> "video-mux":0[0]'),
                        changes.index('"ov5640 6-003c":0 -> "video-mux":1[1]'))
        self.assertIn('"cdns-csi2rx.19800000.csi-bridge":3 -> "capture_raw":0[0]', changes)
        self.assertTrue(any('-d' in args and '/dev/video17' in args and
                            '--stream-mmap=4' in args for args in calls))

    def test_front_capture_and_nonstandard_source_pad(self):
        calls = self.exercise('front')
        self.assertTrue(any('"stf_isp":0 [fmt:SRGGB10_1X10/1280x720 field:none]'
                            in args for args in calls))
        self.assertFalse(any('-l' in args and 'IMMUTABLE' in args[-1] for args in calls))

    def test_configure_only_does_not_capture(self):
        calls = self.exercise('rear', configure_only=True)
        self.assertFalse(any('--stream-mmap=4' in args for args in calls))

    def test_incomplete_capture_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'Incomplete capture'):
            self.exercise('front', incomplete=True)

    def test_ambiguous_topology_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'found 2'):
            camera.unique(['sensor0', 'sensor1'], 'sensor')


if __name__ == '__main__':
    unittest.main()
