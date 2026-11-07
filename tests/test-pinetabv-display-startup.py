#!/usr/bin/env python3
"""Fault-inject the actual panel wake-up and JH7110 byte-clock reset sequence."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def function(source, name):
    match = re.search(r'^static (?:int|void) ' + name + r'\(', source, re.M)
    if not match:
        raise ValueError(f'missing function: {name}')
    opening = source.index('{', match.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


PANEL_HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
struct device { int unused; };
struct mipi_dsi_device { struct device dev; };
struct drm_panel { bool prepared; };
struct gpio_desc { int value; };
struct regulator { int users; };
struct boe_th101mb31ig002;
struct panel_desc {
    unsigned vcioo_to_lp11_delay_ms, lp11_to_reset_delay_ms;
    unsigned enable_to_reset_delay_ms, initial_power_off_delay_ms, init_retries;
    bool lp11_before_reset, lp11_after_enable;
    int (*init)(struct boe_th101mb31ig002 *ctx);
};
struct boe_th101mb31ig002 {
    struct drm_panel panel;
    struct mipi_dsi_device *dsi;
    struct gpio_desc *enable, *reset;
    struct regulator *power;
    const struct panel_desc *desc;
    bool powered;
};
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
#define dev_err(dev, ...) ((void)(dev))
#define dev_warn(dev, ...) ((void)(dev))
static unsigned nop_calls, init_calls, reset_calls, off_intervals;
static unsigned fail_nops, fail_inits;
static bool fail_regulator;
static struct gpio_desc power_enable, panel_reset;
static void gpiod_set_value_cansleep(struct gpio_desc *gpio, int value) { gpio->value = value; }
static void msleep(unsigned ms) {
    if (ms == 120) {
        assert(!power_enable.value && panel_reset.value);
        off_intervals++;
    }
}
static int regulator_enable(struct regulator *power) {
    if (fail_regulator) return -ENODEV;
    assert(!power->users); power->users++;
    return 0;
}
static int regulator_disable(struct regulator *power) {
    assert(power->users == 1); power->users--;
    return 0;
}
static int mipi_dsi_dcs_nop(struct mipi_dsi_device *dsi) {
    (void)dsi; nop_calls++;
    if (nop_calls <= fail_nops) return -ETIMEDOUT;
    return 0;
}
static void boe_th101mb31ig002_reset(struct boe_th101mb31ig002 *ctx) {
    assert(ctx->powered && ctx->enable->value);
    reset_calls++; ctx->reset->value = 0;
}
static int initialize(struct boe_th101mb31ig002 *ctx) {
    assert(ctx->powered && ctx->enable->value && !ctx->reset->value);
    init_calls++;
    return init_calls <= fail_inits ? -EIO : 0;
}
#include "panel-under-test.c"
static void reset_counters(struct boe_th101mb31ig002 *ctx) {
    nop_calls = init_calls = reset_calls = off_intervals = 0;
    fail_nops = fail_inits = 0; fail_regulator = false;
    ctx->power->users = 0; ctx->powered = false; ctx->panel.prepared = false;
    power_enable.value = 1; panel_reset.value = 0;
}
int main(void) {
    struct mipi_dsi_device dsi = { 0 };
    struct regulator power = { 0 };
    struct panel_desc desc = { .enable_to_reset_delay_ms = 250,
        .initial_power_off_delay_ms = 120, .init_retries = 2,
        .lp11_after_enable = true, .lp11_to_reset_delay_ms = 5, .init = initialize };
    struct boe_th101mb31ig002 ctx = { .dsi = &dsi, .power = &power,
        .enable = &power_enable, .reset = &panel_reset, .desc = &desc };

    reset_counters(&ctx); fail_nops = 1;
    assert(boe_th101mb31ig002_prepare(&ctx.panel) == 0);
    assert(nop_calls == 2 && init_calls == 1 && reset_calls == 1);
    assert(off_intervals == 2 && ctx.powered && power.users == 1);
    puts("PASS: a failed first LP-11 command power-cycles and retries panel startup");

    reset_counters(&ctx); fail_nops = 10;
    assert(boe_th101mb31ig002_prepare(&ctx.panel) == -ETIMEDOUT);
    assert(nop_calls == 3 && !init_calls && !reset_calls);
    assert(!ctx.powered && !power.users && !power_enable.value && panel_reset.value);
    assert(boe_th101mb31ig002_enable_backlight(&ctx.panel) == -EIO);
    puts("PASS: persistent transport failure stops after three attempts and keeps backlight off");

    reset_counters(&ctx); fail_inits = 2;
    assert(boe_th101mb31ig002_prepare(&ctx.panel) == 0);
    assert(nop_calls == 3 && init_calls == 3 && reset_calls == 3);
    assert(off_intervals == 3 && power.users == 1);
    ctx.panel.prepared = true;
    assert(boe_th101mb31ig002_enable_backlight(&ctx.panel) == 0);
    puts("PASS: complete initialization retries preserve balanced power and allow backlight on success");

    reset_counters(&ctx); fail_inits = 10;
    assert(boe_th101mb31ig002_prepare(&ctx.panel) == -EIO);
    assert(init_calls == 3 && !power.users && !ctx.powered);
    puts("PASS: persistent initialization failure powers the panel down");

    reset_counters(&ctx); fail_regulator = true;
    assert(boe_th101mb31ig002_prepare(&ctx.panel) == -ENODEV);
    assert(!nop_calls && !init_calls && !power.users && !power_enable.value);
    puts("PASS: regulator failure does not send panel commands");
    return 0;
}
'''


RESET_HARNESS = r'''
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdbool.h>
struct reset_control { int id; bool asserted; };
struct reset_control_bulk_data { struct reset_control *rstc; };
struct cdns_dsi { int num_rsts, num_clks; struct reset_control_bulk_data *resets; void *clocks, *vout_syscon; };
#define JH7110_VOUT_SYSCON_LCD_MAP 8
#define JH7110_VOUT_SYSCON_LCD_TO_DSI 8
static struct reset_control byte_reset;
static int reset_error, clock_error, regmap_error, bulk_error;
static unsigned asserts, clocks, routes, releases, disables;
static int reset_control_assert(struct reset_control *reset) {
    assert(reset == &byte_reset); asserts++;
    if (reset_error) return reset_error;
    reset->asserted = true; return 0;
}
static int clk_bulk_prepare_enable(int n, void *unused) {
    (void)unused; assert(n == 2 && byte_reset.asserted); clocks++;
    return clock_error;
}
static void clk_bulk_disable_unprepare(int n, void *unused) { (void)unused; assert(n == 2); disables++; }
static int regmap_update_bits(void *map, int reg, int mask, int value) {
    (void)map; assert(reg == 8 && mask == 8 && value == 8); routes++; return regmap_error;
}
static int reset_control_bulk_deassert(int n, struct reset_control_bulk_data *resets) {
    assert(n == 4 && byte_reset.asserted && resets[4].rstc == &byte_reset);
    releases++; return bulk_error;
}
#include "reset-under-test.c"
static void reset_counters(void) {
    reset_error = clock_error = regmap_error = bulk_error = 0;
    asserts = clocks = routes = releases = disables = 0;
    byte_reset.asserted = false;
}
int main(void) {
    struct reset_control_bulk_data resets[5] = { [4] = { &byte_reset } };
    struct cdns_dsi dsi = { .num_rsts = 5, .num_clks = 2, .resets = resets };
    reset_counters();
    assert(cdns_dsi_jh7110_resume(&dsi) == 0);
    assert(asserts == 1 && clocks == 1 && routes == 1 && releases == 1 && !disables);
    puts("PASS: byte-clock reset is asserted even when firmware left it released");
    reset_counters(); reset_error = -EIO;
    assert(cdns_dsi_jh7110_resume(&dsi) == -EIO);
    assert(!clocks && !routes && !releases && !disables);
    reset_counters(); clock_error = -EIO;
    assert(cdns_dsi_jh7110_resume(&dsi) == -EIO);
    assert(!routes && !releases && !disables && byte_reset.asserted);
    reset_counters(); regmap_error = -EIO;
    assert(cdns_dsi_jh7110_resume(&dsi) == -EIO);
    assert(!releases && disables == 1 && byte_reset.asserted);
    reset_counters(); bulk_error = -EIO;
    assert(cdns_dsi_jh7110_resume(&dsi) == -EIO);
    assert(releases == 1 && disables == 1 && byte_reset.asserted);
    puts("PASS: all reset, clock, and routing errors unwind without releasing the byte-clock domain");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    panel = (args.kernel_source / 'drivers/gpu/drm/panel/panel-boe-th101mb31ig002-28a.c').read_text()
    reset = (args.kernel_source / 'drivers/gpu/drm/bridge/cadence/cdns-dsi-jh7110.c').read_text()
    with tempfile.TemporaryDirectory(prefix='pinetabv-display-startup-') as directory:
        root = Path(directory)
        (root / 'panel-under-test.c').write_text('\n\n'.join(function(panel, name) for name in (
            'boe_th101mb31ig002_enable_panel_power', 'boe_th101mb31ig002_power_down',
            'boe_th101mb31ig002_prepare', 'boe_th101mb31ig002_enable_backlight')))
        (root / 'reset-under-test.c').write_text(function(reset, 'cdns_dsi_jh7110_resume'))
        for name, source in (('panel', PANEL_HARNESS), ('reset', RESET_HARNESS)):
            harness = root / f'{name}-test.c'
            binary = root / f'{name}-test'
            harness.write_text(source)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', str(harness), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
    print('Display startup: source-level fault injection passed; physical cold boots still need testing')


if __name__ == '__main__':
    main()
