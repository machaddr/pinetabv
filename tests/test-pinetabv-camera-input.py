#!/usr/bin/env python3
"""Exercise CAMSS S_INPUT reselection, switching, and failure rollback."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    source = (args.kernel_source / 'drivers/staging/media/starfive/camss/stf-video.c').read_text()
    start = source.index('static int video_s_input(')
    end = source.index('\nint stf_video_init_format(', start)
    harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <linux/videodev2.h>
#include <linux/v4l2-subdev.h>
#include <linux/media.h>
#include <linux/media-bus-format.h>
#define STF_CAPTURE_NUM 2
#define STF_ISP_PAD_SRC 1
struct media_link;
struct media_entity { struct media_link *links; };
struct media_pad { struct media_entity *entity; unsigned int index; };
struct media_link { struct media_pad *source, *sink; unsigned int flags; struct media_link *next; };
struct v4l2_subdev { struct media_entity entity; struct v4l2_mbus_framefmt format; int kind; };
struct stfcamss;
struct stfcamss_video {
    struct stfcamss *stfcamss;
    int vb2_q;
    struct v4l2_format active_fmt;
    struct v4l2_subdev *source_subdev;
    unsigned int source_pad;
};
struct stfcamss {
    struct { int graph_mutex; } media_dev;
    struct { struct v4l2_subdev subdev; } isp_dev;
    struct { struct stfcamss_video video; } captures[2];
    void *dev;
};
struct file { struct stfcamss_video *video; };
static struct stfcamss camss;
static struct v4l2_subdev sensors[2], mux, csi;
static struct media_pad sources[2], sinks[2];
static struct media_link links[2];
static struct v4l2_subdev_selection crop;
static int fail_stage, init_calls;
#define video_drvdata(file) ((file)->video)
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
#define vb2_is_busy(queue) (*(queue) != 0)
#define media_entity_pipeline(entity) 0
#define media_entity_to_v4l2_subdev(entity) ((struct v4l2_subdev *)(entity))
#define for_each_media_entity_data_link(entity, link) for ((link)=(entity)->links; (link); (link)=(link)->next)
#define dev_err(...) ((void)0)
static bool stf_video_is_yuv(struct stfcamss_video *v) { return v == &camss.captures[1].video; }
static struct v4l2_subdev *stf_video_find_subdev(struct stfcamss_video *v, unsigned int function)
{ (void)v; (void)function; return &mux; }
static struct media_link *stf_video_input_link(struct v4l2_subdev *sd, unsigned int input)
{ (void)sd; return input < 2 ? &links[input] : NULL; }
static int stf_video_sensor_format(struct v4l2_subdev *sd, struct v4l2_subdev_format *f)
{ f->which=V4L2_SUBDEV_FORMAT_ACTIVE; f->pad=0; f->format=sd->format; return 0; }
static int __media_entity_setup_link(struct media_link *link, unsigned int flags)
{
    if (fail_stage == 3 && link == &links[0] && !(flags & MEDIA_LNK_FL_ENABLED)) {
        fail_stage=0; return -EIO;
    }
    link->flags=flags; return 0;
}
static int mock_subdev(struct v4l2_subdev *sd, const char *op, void *arg)
{
    if (!strcmp(op,"get_selection")) { *(struct v4l2_subdev_selection *)arg=crop; return 0; }
    if (!strcmp(op,"set_selection")) { crop=*(struct v4l2_subdev_selection *)arg; return 0; }
    if (!strcmp(op,"enum_mbus_code")) {
        struct v4l2_subdev_mbus_code_enum *code=arg;
        if (code->index) return -EINVAL;
        code->code=sd == &sensors[0] ? MEDIA_BUS_FMT_SRGGB10_1X10 : MEDIA_BUS_FMT_SRGGB8_1X8;
        return 0;
    }
    if (!strcmp(op,"set_fmt")) { sd->format=((struct v4l2_subdev_format *)arg)->format; return 0; }
    if (!strcmp(op,"get_fmt")) {
        struct v4l2_subdev_format *f=arg;
        f->format=csi.format;
        if (sd->kind == 2) { f->format.width=crop.r.width; f->format.height=crop.r.height; }
        return 0;
    }
    return -EINVAL;
}
#define v4l2_subdev_call_state_active(sd, group, op, arg) mock_subdev(sd, #op, arg)
static int stfcamss_init_pipeline_formats(struct v4l2_subdev *sd)
{
    (void)sd;
    struct v4l2_subdev *sensor=(links[0].flags & MEDIA_LNK_FL_ENABLED) ? &sensors[0] : &sensors[1];
    csi.format=sensor->format;
    crop.r.width=csi.format.width; crop.r.height=csi.format.height; crop.r.left=crop.r.top=0;
    if (fail_stage == 1) { fail_stage=0; return -EIO; }
    return 0;
}
static int stf_video_init_format(struct stfcamss_video *video, const struct v4l2_mbus_framefmt *f)
{
    init_calls++;
    if (fail_stage == 2 && init_calls == 2) { fail_stage=0; return -EIO; }
    video->active_fmt.fmt.pix.width=f->width;
    video->active_fmt.fmt.pix.height=f->height;
    video->active_fmt.fmt.pix.pixelformat=f->code;
    return 0;
}
'''
    checks = r'''
static void reset(void)
{
    memset(&camss,0,sizeof(camss)); memset(sensors,0,sizeof(sensors)); memset(&crop,0,sizeof(crop));
    sensors[0].format=(struct v4l2_mbus_framefmt){ .width=1280,.height=720,.code=MEDIA_BUS_FMT_SRGGB10_1X10 };
    sensors[1].format=(struct v4l2_mbus_framefmt){ .width=640,.height=480,.code=MEDIA_BUS_FMT_SRGGB8_1X8 };
    mux.entity.links=&links[0];
    for (unsigned int i=0;i<2;i++) {
        sources[i]=(struct media_pad){ .entity=&sensors[i].entity,.index=0 };
        sinks[i]=(struct media_pad){ .entity=&mux.entity,.index=i };
        links[i]=(struct media_link){ .source=&sources[i],.sink=&sinks[i],
            .flags=i ? 0 : MEDIA_LNK_FL_ENABLED,.next=i ? NULL : &links[1] };
        camss.captures[i].video.stfcamss=&camss;
        camss.captures[i].video.source_subdev=i ? &camss.isp_dev.subdev : &csi;
        camss.captures[i].video.active_fmt.fmt.pix=(struct v4l2_pix_format){
            .width=i ? 640 : 1280,.height=i ? 480 : 720,.pixelformat=MEDIA_BUS_FMT_SRGGB10_1X10 };
    }
    camss.isp_dev.subdev.kind=2;
    csi.format=sensors[0].format;
    crop.which=V4L2_SUBDEV_FORMAT_ACTIVE; crop.pad=STF_ISP_PAD_SRC; crop.target=V4L2_SEL_TGT_CROP;
    crop.r=(struct v4l2_rect){ .left=320,.top=120,.width=640,.height=480 };
    init_calls=0; fail_stage=0;
}
int main(void)
{
    struct file file={ .video=&camss.captures[1].video };
    for (int busy=0;busy<2;busy++) {
        reset();
        struct v4l2_subdev_selection saved_crop=crop;
        struct v4l2_mbus_framefmt saved_sensor=sensors[0].format;
        struct v4l2_format saved[2]={ camss.captures[0].video.active_fmt,camss.captures[1].video.active_fmt };
        camss.captures[0].video.vb2_q=busy;
        camss.captures[1].video.vb2_q=busy;
        assert(video_s_input(&file,NULL,0)==0);
        assert(init_calls==0);
        assert(!memcmp(&crop,&saved_crop,sizeof(crop)));
        assert(!memcmp(&sensors[0].format,&saved_sensor,sizeof(saved_sensor)));
        for (unsigned int i=0;i<2;i++) assert(!memcmp(&camss.captures[i].video.active_fmt,&saved[i],sizeof(saved[i])));
    }
    for (unsigned int selected=1;selected<2;selected++) {
        for (int stage=1;stage<=3;stage++) {
            reset();
            struct v4l2_subdev_selection saved_crop=crop;
            struct v4l2_mbus_framefmt saved_sensor=sensors[selected].format;
            struct v4l2_format saved[2]={ camss.captures[0].video.active_fmt,camss.captures[1].video.active_fmt };
            fail_stage=stage;
            assert(video_s_input(&file,NULL,selected)==-EIO);
            assert((links[0].flags & MEDIA_LNK_FL_ENABLED) && !(links[1].flags & MEDIA_LNK_FL_ENABLED));
            assert(!memcmp(&crop,&saved_crop,sizeof(crop)));
            assert(!memcmp(&sensors[selected].format,&saved_sensor,sizeof(saved_sensor)));
            for (unsigned int i=0;i<2;i++) assert(!memcmp(&camss.captures[i].video.active_fmt,&saved[i],sizeof(saved[i])));
        }
    }
    reset();
    assert(video_s_input(&file,NULL,1)==0);
    assert(!(links[0].flags & MEDIA_LNK_FL_ENABLED) && (links[1].flags & MEDIA_LNK_FL_ENABLED));
    assert(sensors[1].format.width==1280 && camss.captures[1].video.active_fmt.fmt.pix.width==1280);
    reset(); camss.captures[0].video.vb2_q=1;
    assert(video_s_input(&file,NULL,1)==-EBUSY);
    assert(links[0].flags & MEDIA_LNK_FL_ENABLED);
    reset(); camss.captures[1].video.vb2_q=1;
    assert(video_s_input(&file,NULL,1)==-EBUSY);
    assert(links[0].flags & MEDIA_LNK_FL_ENABLED);
    reset();
    assert(video_s_input(&file,NULL,2)==-EINVAL);
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='pinetabv-camera-input-') as directory:
        source_file = Path(directory) / 'input-test.c'
        binary = Path(directory) / 'input-test'
        source_file.write_text(harness + source[start:end] + checks)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-parameter',
                        str(source_file), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('CAMSS input selection: idle/busy reselection preserves formats; switching, busy rejection and three rollback checks passed')


if __name__ == '__main__':
    main()
