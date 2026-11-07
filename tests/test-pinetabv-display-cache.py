#!/usr/bin/env python3
"""Compile the actual scanout sync helper with mocked DRM/DMA and check cache coverage."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def extract_function(source, name):
    start = source.index(name + '(')
    start = source.rfind('\n', 0, start) + 1
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


HARNESS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t dma_addr_t;
enum { DMA_TO_DEVICE = 1, DMA_BIDIRECTIONAL = 2 };
struct device { int unused; };
struct sg_table { size_t size; };
struct gem_base { size_t size; bool imported; };
struct drm_gem_dma_object { struct gem_base base; dma_addr_t dma_addr; struct sg_table *sgt; bool map_noncoherent; };
struct drm_framebuffer { struct drm_gem_dma_object *gem; size_t offsets[1], pitches[1]; };
struct drm_rect { int x1, y1, x2, y2; };
struct drm_plane_state { struct drm_framebuffer *fb; struct drm_rect clips[4]; int clip_count; };
struct vs_drm_dev { bool map_noncoherent; };
struct drm_device { struct vs_drm_dev vdrm; struct device dev; };
struct drm_atomic_helper_damage_iter { struct drm_plane_state *state; int index; };
static unsigned char cpu[256], device_memory[256];
static unsigned int single_calls, range_calls, sg_calls, warnings;
static size_t last_offset, last_length;
static int last_direction;
static struct vs_drm_dev *to_vs_drm_dev(struct drm_device *drm) { return &drm->vdrm; }
static struct device *drm_dev_dma_dev(struct drm_device *drm) { return &drm->dev; }
static struct drm_gem_dma_object *drm_fb_dma_get_gem_obj(struct drm_framebuffer *fb, int i) { assert(!i); return fb->gem; }
static bool drm_gem_is_imported(struct gem_base *gem) { return gem->imported; }
static bool warn(bool condition) { warnings += condition; return condition; }
#define drm_WARN_ON_ONCE(drm, condition) warn(condition)
#define min(a, b) ((a) < (b) ? (a) : (b))
static void copy_to_device(size_t offset, size_t size, int direction) {
    assert(offset <= sizeof(cpu) && size <= sizeof(cpu) - offset);
    memcpy(device_memory + offset, cpu + offset, size);
    last_offset = offset; last_length = size; last_direction = direction;
}
static void dma_sync_single_for_device(struct device *dev, dma_addr_t addr, size_t size, int direction) {
    (void)dev; assert(addr == 0x10000000); single_calls++; copy_to_device(0, size, direction);
}
static void dma_sync_single_range_for_device(struct device *dev, dma_addr_t addr, size_t offset, size_t size, int direction) {
    (void)dev; assert(addr == 0x10000000); range_calls++; copy_to_device(offset, size, direction);
}
static void dma_sync_sgtable_for_device(struct device *dev, struct sg_table *sgt, int direction) {
    (void)dev; sg_calls++; copy_to_device(0, sgt->size, direction);
}
static void drm_atomic_helper_damage_iter_init(struct drm_atomic_helper_damage_iter *iter, struct drm_plane_state *old_state, struct drm_plane_state *state) {
    (void)old_state; iter->state = state; iter->index = 0;
}
static bool next_clip(struct drm_atomic_helper_damage_iter *iter, struct drm_rect *clip) {
    if (iter->index >= iter->state->clip_count) return false;
    *clip = iter->state->clips[iter->index++]; return true;
}
#define drm_atomic_for_each_plane_damage(iter, clip) while (next_clip(iter, clip))
#include "cache-helper.c"
static void reset(void) {
    memset(cpu, 0x5a, sizeof(cpu)); memset(device_memory, 0, sizeof(device_memory));
    single_calls = range_calls = sg_calls = warnings = 0;
    last_offset = last_length = 0; last_direction = 0;
}
int main(void) {
    struct drm_device drm = { .vdrm = { .map_noncoherent = true } };
    struct sg_table sgt = { .size = sizeof(cpu) };
    struct drm_gem_dma_object gem = { .base = { .size = sizeof(cpu) }, .dma_addr = 0x10000000, .sgt = &sgt, .map_noncoherent = true };
    struct drm_framebuffer fb = { .gem = &gem, .offsets = { 0 }, .pitches = { 16 } }, previous_fb = fb;
    struct drm_plane_state state = { .fb = &fb, .clips = { { .y1 = 2, .y2 = 3 } }, .clip_count = 1 };
    struct drm_plane_state old = state;

    reset(); old.fb = &previous_fb;
    vs_fb_sync_for_device(&drm, &old, &state);
    assert(single_calls == 1 && !range_calls && !sg_calls);
    assert(!memcmp(cpu, device_memory, sizeof(cpu)));
    assert(last_direction == DMA_TO_DEVICE);
    puts("PASS: switching framebuffer flushes all cached contents, beyond scene damage");

    reset(); old = state; gem.base.imported = true; gem.map_noncoherent = false;
    vs_fb_sync_for_device(&drm, &old, &state);
    assert(sg_calls == 1 && !single_calls && !range_calls);
    assert(last_direction == DMA_BIDIRECTIONAL && !memcmp(cpu, device_memory, sizeof(cpu)));
    puts("PASS: imported buffer is synchronized despite map_noncoherent=false");

    reset(); gem.base.imported = false; gem.map_noncoherent = true;
    fb.offsets[0] = 8; state.clips[0].y1 = 3; state.clips[0].y2 = 5;
    vs_fb_sync_for_device(&drm, &old, &state);
    assert(range_calls == 1 && last_offset == 56 && last_length == 32);
    assert(device_memory[55] == 0 && device_memory[56] == 0x5a && device_memory[87] == 0x5a && device_memory[88] == 0);
    puts("PASS: cropped source damage uses framebuffer origin exactly once");

    reset(); fb.offsets[0] = 0; gem.base.size = 250;
    state.clips[0].y1 = 15; state.clips[0].y2 = 16;
    vs_fb_sync_for_device(&drm, &old, &state);
    assert(range_calls == 1 && last_offset == 240 && last_length == 10 && !warnings);
    puts("PASS: final partial stride does not synchronize beyond GEM allocation");

    reset(); drm.vdrm.map_noncoherent = false;
    vs_fb_sync_for_device(&drm, &old, &state);
    assert(!single_calls && !range_calls && !sg_calls);
    puts("PASS: coherent platforms retain their original path");

    reset(); drm.vdrm.map_noncoherent = true; gem.map_noncoherent = false;
    vs_fb_sync_for_device(&drm, &old, &state);
    assert(!single_calls && !range_calls && !sg_calls);
    puts("PASS: consistent native allocations need no explicit synchronization");

    reset(); gem.map_noncoherent = true;
    vs_fb_sync_for_device(&drm, NULL, &state);
    assert(single_calls == 1 && last_length == 250);
    puts("PASS: first presentation flushes the complete allocation");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    source = (args.kernel_source / 'drivers/gpu/drm/verisilicon/vs_plane.c').read_text()
    with tempfile.TemporaryDirectory(prefix='pinetabv-display-cache-') as directory:
        root = Path(directory)
        (root / 'cache-helper.c').write_text(extract_function(source, 'vs_fb_sync_for_device'))
        harness = root / 'harness.c'
        binary = root / 'regression-test'
        harness.write_text(HARNESS)
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', str(harness), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('Display cache synchronization: seven source-level checks passed; hardware is not exercised')


if __name__ == '__main__':
    main()
