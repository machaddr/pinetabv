#!/usr/bin/env python3
"""Compile and exercise the actual patched CAMSS format-negotiation functions."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def function(source, name):
    marker = source.index(name + '(')
    start = source.rfind('\n\n', 0, marker) + 2
    opening = source.index('{', marker)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True,
                        help='Linux source tree with the current project patches applied')
    args = parser.parse_args()
    source = (args.kernel_source / 'drivers/staging/media/starfive/camss/stf-video.c').read_text()
    functions = '\n\n'.join(function(source, name) for name in (
        'video_g_fi_by_pfmt', '__video_try_fmt', 'stf_video_try_yuv', 'video_s_fmt'))
    harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <linux/videodev2.h>
#include <linux/v4l2-subdev.h>
typedef uint32_t u32;
#define clamp_t(type, value, low, high) ((type)(value) < (low) ? (low) : ((type)(value) > (high) ? (high) : (type)(value)))
#define ALIGN(value, alignment) (((value) + (alignment) - 1) & ~((alignment) - 1))
#define STFCAMSS_FRAME_MIN_WIDTH 64
#define STFCAMSS_FRAME_MIN_HEIGHT 64
#define STFCAMSS_FRAME_MAX_WIDTH 1920
#define STFCAMSS_FRAME_MAX_HEIGHT 1080
#define STF_ISP_PAD_SRC 1
struct stfcamss_format_info {
    u32 code, pixelformat;
    unsigned int planes, vsub[3], bpp;
};
struct entity { bool streaming; };
struct subdev { struct entity entity; };
struct stfcamss {
    struct { int graph_mutex; } media_dev;
    struct { struct subdev subdev; } isp_dev;
};
struct stfcamss_video {
    struct stfcamss *stfcamss;
    int vb2_q;
    const struct stfcamss_format_info *formats;
    unsigned int nformats, bpl_alignment;
    struct v4l2_format active_fmt;
};
struct file { struct stfcamss_video *video; };
static struct v4l2_mbus_framefmt sensor_bounds = { .width = 1280, .height = 720 };
static struct v4l2_subdev_selection selected_crop;
static unsigned int crop_changes;
static bool stf_video_is_yuv(struct stfcamss_video *video) { (void)video; return true; }
static int stf_video_isp_bounds(struct stfcamss_video *video, struct v4l2_mbus_framefmt *fmt)
{ (void)video; *fmt = sensor_bounds; return 0; }
static int mock_crop(struct v4l2_subdev_selection *crop)
{ selected_crop = *crop; crop_changes++; return 0; }
#define video_drvdata(file) ((file)->video)
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
#define vb2_is_busy(queue) (*(queue) != 0)
#define media_entity_pipeline(entity) ((entity)->streaming)
#define v4l2_subdev_call_state_active(sd, group, op, crop) mock_crop(crop)
'''
    checks = r'''
int main(void)
{
    const struct stfcamss_format_info nv12 = {
        .pixelformat = V4L2_PIX_FMT_NV12, .planes = 2,
        .vsub = { 1, 2 }, .bpp = 8,
    };
    struct stfcamss camss = { 0 };
    struct stfcamss_video video = {
        .stfcamss = &camss, .formats = &nv12, .nformats = 1, .bpl_alignment = 8,
    };
    struct file file = { .video = &video };
    struct v4l2_format fmt = { .fmt.pix = { .width = 1920, .height = 1080,
        .pixelformat = V4L2_PIX_FMT_YUYV } };
    /* A 1080p request must negotiate the fixed front sensor's actual limit. */
    assert(stf_video_try_yuv(&video, &fmt) == 0);
    assert(fmt.fmt.pix.width == 1280 && fmt.fmt.pix.height == 720);
    assert(fmt.fmt.pix.pixelformat == V4L2_PIX_FMT_NV12);
    assert(fmt.fmt.pix.bytesperline == 1280);
    assert(fmt.fmt.pix.sizeimage == 1280 * 720 * 3 / 2);
    assert(crop_changes == 0); /* TRY_FMT must not change the active pipeline. */
    /* The GNOME 640x480 request must update BOTH the ISP and capture buffer. */
    fmt.fmt.pix.width = 640; fmt.fmt.pix.height = 480;
    assert(video_s_fmt(&file, NULL, &fmt) == 0);
    assert(crop_changes == 1);
    assert(selected_crop.r.width == 640 && selected_crop.r.height == 480);
    assert(selected_crop.r.left == 320 && selected_crop.r.top == 120);
    assert(video.active_fmt.fmt.pix.width == selected_crop.r.width);
    assert(video.active_fmt.fmt.pix.height == selected_crop.r.height);
    assert(video.active_fmt.fmt.pix.sizeimage == 640 * 480 * 3 / 2);
    /* Odd requests must preserve Bayer phase and NV12 row/chroma alignment. */
    fmt.fmt.pix.width = 641; fmt.fmt.pix.height = 479;
    assert(video_s_fmt(&file, NULL, &fmt) == 0);
    assert(fmt.fmt.pix.width == 640 && fmt.fmt.pix.height == 478);
    assert(selected_crop.r.left % 2 == 0 && selected_crop.r.top % 2 == 0);
    /* Neither allocated buffers nor an active pipeline may be reformatted. */
    video.vb2_q = 1;
    assert(video_s_fmt(&file, NULL, &fmt) == -EBUSY);
    video.vb2_q = 0; camss.isp_dev.subdev.entity.streaming = true;
    assert(video_s_fmt(&file, NULL, &fmt) == -EBUSY);
    assert(crop_changes == 2);
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='pinetabv-camera-format-') as directory:
        source_file = Path(directory) / 'format-test.c'
        binary = Path(directory) / 'format-test'
        source_file.write_text(harness + functions + checks)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra',
                        '-Wno-unused-parameter', str(source_file), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('CAMSS format negotiation: native, cropped, aligned, TRY and busy checks passed')


if __name__ == '__main__':
    main()
