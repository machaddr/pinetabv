#!/usr/bin/env python3
"""Configure either PineTab-V sensor through the hardware ISP and capture NV12."""

import argparse
from dataclasses import dataclass
from datetime import datetime
import glob
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


@dataclass(frozen=True)
class Link:
    source: str
    source_pad: int
    sink: str
    sink_pad: int
    enabled: bool
    immutable: bool

    def descriptor(self, enabled):
        return (f'"{self.source}":{self.source_pad} -> '
                f'"{self.sink}":{self.sink_pad}[{int(enabled)}]')


def run(command, *, timeout=30, quiet=False):
    if not quiet:
        print('+ ' + shlex.join(command), flush=True)
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{shlex.join(command)} failed:\n'
                           f'{result.stdout}{result.stderr}')
    return result.stdout


def topology(text):
    """Read outgoing links from media-ctl, preserving actual pad indices."""
    entities = set()
    links = []
    entity = None
    pad = None
    for line in text.splitlines():
        match = re.match(r'\s*- entity \d+: (.+) \(\d+ pads?, \d+ links?\)', line)
        if match:
            entity = match[1]
            entities.add(entity)
            pad = None
            continue
        match = re.match(r'\s*pad(\d+):', line)
        if match:
            pad = int(match[1])
            continue
        match = re.match(r'\s*-> "([^"]+)":(\d+) \[([^]]*)\]', line)
        if match and entity is not None and pad is not None:
            flags = match[3].split(',')
            links.append(Link(entity, pad, match[1], int(match[2]),
                              'ENABLED' in flags, 'IMMUTABLE' in flags))
    return entities, links


def unique(values, description):
    values = list(values)
    if len(values) != 1:
        raise RuntimeError(f'Expected one {description}; found {len(values)}.')
    return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Run on the tablet with no other camera application open. Requires '
        'media-ctl and v4l2-ctl from v4l-utils; stock libcamera is not used. '
        'Capture output is raw NV12, suitable for ffplay -f rawvideo '
        '-pixel_format nv12 -video_size WIDTHxHEIGHT FILE.'))
    parser.add_argument('--camera', required=True, choices=('front', 'rear'))
    parser.add_argument('--media', help='Media device (auto-detected by driver)')
    parser.add_argument('--width', type=int, help='Requested width (front 1280; rear 640)')
    parser.add_argument('--height', type=int, help='Requested height (front 720; rear 480)')
    parser.add_argument('--frames', type=int, default=120)
    parser.add_argument('--timeout', type=int, default=60,
                        help='Capture deadline in seconds (default: 60)')
    parser.add_argument('--output', type=Path, help='New NV12 capture file')
    parser.add_argument('--configure-only', action='store_true',
                        help='Select and configure the camera without capturing')
    args = parser.parse_args()
    for command in ('media-ctl', 'v4l2-ctl'):
        if not shutil.which(command):
            parser.error(f'Required command not found: {command}')
    if args.frames <= 0 or args.timeout <= 0:
        parser.error('--frames and --timeout must be positive')
    if not args.configure_only and args.output is None:
        parser.error('--output is required unless --configure-only is used')
    if args.output is not None and args.output.exists():
        parser.error(f'Output already exists: {args.output}')
    width = args.width or (1280 if args.camera == 'front' else 640)
    height = args.height or (720 if args.camera == 'front' else 480)
    if not (64 <= width <= 1920 and 64 <= height <= 1080):
        parser.error('Requested size must fit the CAMSS 64x64 to 1920x1080 range')

    devices = [args.media] if args.media else sorted(glob.glob('/dev/media*'))
    matches = []
    for device in devices:
        try:
            text = run(['media-ctl', '-d', device, '-p'], quiet=True)
        except RuntimeError:
            if args.media:
                raise
            continue
        if re.search(r'^driver\s+starfive-camss\s*$', text, re.MULTILINE):
            matches.append((device, text))
    device, text = unique(matches, 'starfive-camss media device')
    entities, links = topology(text)
    prefix = 'gc02m2 ' if args.camera == 'front' else 'ov5640 '
    sensor = unique((name for name in entities if name.startswith(prefix)),
                    f'{args.camera} sensor')
    sensor_link = unique((link for link in links if link.source == sensor),
                         'sensor output link')
    mux = sensor_link.sink
    mux_link = unique((link for link in links if link.source == mux),
                      'camera mux output link')
    csi = mux_link.sink
    isp_link = unique((link for link in links if link.source == csi
                       and link.sink == 'stf_isp'), 'CSI to ISP link')
    capture_link = unique((link for link in links if link.source == 'stf_isp'
                           and link.sink == 'capture_yuv'), 'NV12 capture link')
    node = run(['media-ctl', '-d', device, '-e', capture_link.sink], quiet=True).strip()
    if not re.fullmatch(r'/dev/video\d+', node):
        raise RuntimeError(f'Unexpected capture device path: {node!r}')

    def media(*arguments):
        return run(['media-ctl', '-d', device, *arguments])

    # Disable the current sensor before selecting the other physical mux input.
    # Disable the competing raw capture route, without resetting unrelated links.
    for link in links:
        if ((link.sink == mux or (link.source == csi and link.sink == 'capture_raw'))
                and link.enabled and not link.immutable):
            media('-l', link.descriptor(False))
    for link in (sensor_link, mux_link, isp_link, capture_link):
        if not link.immutable:
            media('-l', link.descriptor(True))
        elif not link.enabled:
            raise RuntimeError('Required immutable media link is disabled')

    code = 'SRGGB10_1X10' if args.camera == 'front' else 'SRGGB8_1X8'
    media('-V', f'"{sensor}":{sensor_link.source_pad} '
          f'[fmt:{code}/{width}x{height} field:none]')
    actual = media('--get-v4l2', f'"{sensor}":{sensor_link.source_pad}')
    fmt = re.search(r'fmt:([A-Z0-9_]+)/([0-9]+)x([0-9]+)', actual)
    if not fmt or fmt[1] != code:
        raise RuntimeError(f'Sensor did not negotiate the requested Bayer format:\n{actual}')
    width, height = int(fmt[2]), int(fmt[3])
    if width > 1920 or height > 1080:
        raise RuntimeError(f'Sensor selected {width}x{height}, beyond the ISP limit')
    for entity, pad in ((mux, sensor_link.sink_pad), (csi, mux_link.sink_pad),
                        ('stf_isp', isp_link.sink_pad)):
        media('-V', f'"{entity}":{pad} [fmt:{code}/{width}x{height} field:none]')

    command = ['v4l2-ctl', '-d', node]
    run(command + [f'--set-fmt-video=width={width},height={height},pixelformat=NV12'])
    capture_format = run(command + ['--get-fmt-video'])
    print(capture_format, end='')
    negotiated = re.search(r'Width/Height\s*:\s*(\d+)/(\d+)', capture_format)
    stride = re.search(r'Bytes per Line\s*:\s*(\d+)', capture_format)
    size = re.search(r'Size Image\s*:\s*(\d+)', capture_format)
    if (not negotiated or (int(negotiated[1]), int(negotiated[2])) != (width, height)
            or not stride or int(stride[1]) != width or not size):
        raise RuntimeError('Capture format differs from the sensor or uses padded '
                           'rows. Choose a sensor size with width divisible by 8.')
    print(f'{args.camera}: {sensor} -> {node}, NV12 {width}x{height}', flush=True)
    if args.configure_only:
        return
    started = datetime.now().isoformat(timespec='seconds')
    result = run(command + ['--stream-mmap=4', '--stream-poll',
                            f'--stream-count={args.frames}',
                            f'--stream-to={args.output}'], timeout=args.timeout)
    print(result, end='')
    expected = int(size[1]) * args.frames
    captured = args.output.stat().st_size
    if captured != expected:
        raise RuntimeError(f'Incomplete capture: expected {expected} bytes for '
                           f'{args.frames} frames; received {captured}.')
    print(f'Captured {args.frames} frames ({captured} bytes), started {started}.')
    print(f'Preview: ffplay -f rawvideo -pixel_format nv12 '
          f'-video_size {width}x{height} {shlex.quote(str(args.output))}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)
