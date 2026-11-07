#!/usr/bin/env python3
"""Check actual CAMSS size enumeration against PipeWire SPA negotiation."""

import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile


def function(source, name):
    start = source.rfind('\nstatic ', 0, source.index(name + '(')) + 1
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <linux/videodev2.h>
#include <linux/v4l2-subdev.h>
#include <linux/media.h>
#include <linux/media-bus-format.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/filter.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define STFCAMSS_FRAME_MIN_WIDTH 64
#define STFCAMSS_FRAME_MIN_HEIGHT 64
#define STFCAMSS_FRAME_MAX_WIDTH 1920
#define STFCAMSS_FRAME_MAX_HEIGHT 1080
struct stfcamss_format_info { unsigned int pixelformat; };
struct v4l2_subdev { int unused; };
struct stfcamss_video {
    struct { struct { int graph_mutex; } media_dev; } *stfcamss;
    const struct stfcamss_format_info *formats;
    unsigned int nformats;
    bool yuv;
};
struct file { struct stfcamss_video *video; };
static struct v4l2_mbus_framefmt bounds;
static struct v4l2_subdev sensor;
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
#define video_drvdata(file) ((file)->video)
static bool stf_video_is_yuv(struct stfcamss_video *v) { return v->yuv; }
static int stf_video_isp_bounds(struct stfcamss_video *v, struct v4l2_mbus_framefmt *f)
{ (void)v; *f=bounds; return 0; }
static struct v4l2_subdev *stf_video_find_subdev(struct stfcamss_video *v,unsigned int function)
{ (void)v; (void)function; return &sensor; }
static int stf_video_sensor_format(struct v4l2_subdev *sd,struct v4l2_subdev_format *f)
{ (void)sd; f->format=bounds; f->format.code=MEDIA_BUS_FMT_SRGGB10_1X10; f->pad=0; return 0; }
static int enum_sensor_interval(struct v4l2_subdev *sd, struct v4l2_subdev_frame_interval_enum *f)
{
    (void)sd;
    assert(f->width==bounds.width && f->height==bounds.height);
    if (f->index) return -EINVAL;
    f->interval=(struct v4l2_fract){1,30}; return 0;
}
#define v4l2_subdev_call_state_active(sd,group,op,arg) enum_sensor_interval(sd,arg)
'''

CHECKS = r'''
static int spa_matches(struct v4l2_frmsize_discrete size,bool legacy_step) {
    uint8_t advertised_data[1024],request_data[1024],result_data[2048];
    struct spa_pod_builder a=SPA_POD_BUILDER_INIT(advertised_data,sizeof(advertised_data));
    struct spa_pod_builder b=SPA_POD_BUILDER_INIT(request_data,sizeof(request_data));
    struct spa_pod_builder r=SPA_POD_BUILDER_INIT(result_data,sizeof(result_data));
    struct spa_rectangle min=SPA_RECTANGLE(64,64),max=SPA_RECTANGLE(bounds.width,bounds.height);
    struct spa_rectangle wanted=SPA_RECTANGLE(size.width,size.height);
    struct spa_pod *adv;
    if (legacy_step) {
        /* PipeWire1.4.2 v4l2-utils.c encodes maximum dimensions as the step:
         * https://github.com/PipeWire/pipewire/blob/1.4.2/spa/plugins/v4l2/v4l2-utils.c
         */
        adv=spa_pod_builder_add_object(&a,SPA_TYPE_OBJECT_Format,SPA_PARAM_EnumFormat,
            SPA_FORMAT_VIDEO_size,SPA_POD_CHOICE_STEP_Rectangle(&min,&min,&max,&max));
    } else {
        adv=spa_pod_builder_add_object(&a,SPA_TYPE_OBJECT_Format,SPA_PARAM_EnumFormat,
            SPA_FORMAT_VIDEO_size,SPA_POD_Rectangle(&wanted));
    }
    struct spa_pod *req=spa_pod_builder_add_object(&b,SPA_TYPE_OBJECT_Format,SPA_PARAM_EnumFormat,
        SPA_FORMAT_VIDEO_size,SPA_POD_Rectangle(&wanted));
    return spa_pod_filter(&r,NULL,adv,req);
}
int main(void) {
    const struct stfcamss_format_info formats[]={{V4L2_PIX_FMT_NV12}};
    struct stfcamss_video v={.formats=formats,.nformats=1,.yuv=true};
    typeof(*v.stfcamss) camss={0};
    v.stfcamss=&camss;
    struct file file={&v};
    const struct v4l2_frmsize_discrete natives[]={{1280,720},{640,480},{1920,1080},{800,600},{1281,721}};
    for (unsigned int n=0;n<ARRAY_SIZE(natives);n++) {
        bounds.width=natives[n].width; bounds.height=natives[n].height;
        struct v4l2_frmsize_discrete seen[16];
        unsigned int index=0;
        bool found_vga=false;
        for (;;index++) {
            struct v4l2_frmsizeenum size={.index=index,.pixel_format=V4L2_PIX_FMT_NV12};
            int ret=video_enum_framesizes(&file,NULL,&size);
            if (ret) { assert(ret==-EINVAL); break; }
            assert(index<ARRAY_SIZE(seen));
            assert(size.type==V4L2_FRMSIZE_TYPE_DISCRETE);
            assert(size.discrete.width>=64 && size.discrete.height>=64);
            assert(size.discrete.width<=bounds.width && size.discrete.height<=bounds.height);
            assert(size.discrete.width%8==0 && size.discrete.height%2==0);
            if (!index) assert(size.discrete.width==(bounds.width&~7u) && size.discrete.height==(bounds.height&~1u));
            for (unsigned int i=0;i<index;i++) assert(memcmp(&seen[i],&size.discrete,sizeof(size.discrete)));
            seen[index]=size.discrete;
            assert(spa_matches(size.discrete,false)==0);
            struct v4l2_frmivalenum interval={.pixel_format=V4L2_PIX_FMT_NV12,.width=size.discrete.width,.height=size.discrete.height};
            assert(video_enum_frameintervals(&file,NULL,&interval)==0);
            assert(interval.type==V4L2_FRMIVAL_TYPE_DISCRETE && interval.discrete.denominator==30);
            interval.index=1;
            assert(video_enum_frameintervals(&file,NULL,&interval)==-EINVAL);
            if (size.discrete.width==640 && size.discrete.height==480) found_vga=true;
        }
        assert(index>0 && found_vga);
    }
    bounds.width=1280; bounds.height=720;
    assert(spa_matches((struct v4l2_frmsize_discrete){640,480},true)<0);
    assert(spa_matches((struct v4l2_frmsize_discrete){640,480},false)==0);
    struct v4l2_frmsizeenum size={.pixel_format=V4L2_PIX_FMT_YUYV};
    assert(video_enum_framesizes(&file,NULL,&size)==-EINVAL);
    size.pixel_format=V4L2_PIX_FMT_NV12; v.yuv=false;
    assert(video_enum_framesizes(&file,NULL,&size)==0);
    assert(size.type==V4L2_FRMSIZE_TYPE_CONTINUOUS);
    size.index=1;
    assert(video_enum_framesizes(&file,NULL,&size)==-EINVAL);
    bounds.width=32; bounds.height=32; v.yuv=true; size.index=0;
    assert(video_enum_framesizes(&file,NULL,&size)==-EINVAL);
    puts("PASS: native/common crops, deduplication, alignment, frame intervals and SPA matching; legacy stepwise640x480 rejects");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    source = (args.kernel_source / 'drivers/staging/media/starfive/camss/stf-video.c').read_text()
    names = ['video_enum_framesizes', 'video_enum_frameintervals']
    if 'static int stf_video_enum_yuv_size(' in source:
        names.insert(0, 'stf_video_enum_yuv_size')
    functions = '\n\n'.join(function(source, name) for name in names)
    with tempfile.TemporaryDirectory(prefix='pinetabv-camera-enumeration-') as directory:
        source_file = Path(directory) / 'enumeration.c'
        binary = Path(directory) / 'enumeration'
        source_file.write_text(HARNESS + functions + CHECKS)
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'libspa-0.2'], text=True))
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-parameter',
                        *flags, str(source_file), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
