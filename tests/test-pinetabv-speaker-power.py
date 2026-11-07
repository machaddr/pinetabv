#!/usr/bin/env python3
"""Check real DAPM ordering, amplifier GPIO events and board shutdown policy."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def extract_block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def extract_macro(source, name):
    lines = source[source.index('#define ' + name + '('):].splitlines(True)
    result = []
    for line in lines:
        result.append(line)
        if not line.rstrip().endswith('\\'):
            return ''.join(result)
    raise AssertionError('Unterminated macro ' + name)


def widget_calls(source, macro):
    return re.findall(r'\b' + macro + r'\([^;]*?\),', source, re.S)


HARNESS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "es8316.h"
#define ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof((a)[0])))
#define BUILD_BUG_ON(test) _Static_assert(!(test), "build assertion")
#define WARN_ONCE(test, ...) assert(!(test))
#define WARN(test, ...) ((void)(test))
#define SND_SOC_NOPM -1
#define SND_SOC_DAPM_POST_PMU 0x2
#define SND_SOC_DAPM_PRE_PMD 0x4
struct snd_kcontrol { int unused; };
struct gpio_desc { int value, writes; };
struct simple_amp { struct gpio_desc *gpiod_enable; };
struct snd_soc_component_driver { int use_pmdown_time; };
struct snd_soc_component {
    struct simple_amp *priv;
    struct snd_soc_component_driver *driver;
};
struct snd_soc_dapm_context { struct snd_soc_component *component; };
struct snd_soc_dapm_widget {
    int id, reg, mask, shift, on_val, off_val, subseq, event_flags, num_kcontrols;
    const char *name;
    void *kcontrol_news;
    struct snd_soc_dapm_context *dapm;
    int (*event)(struct snd_soc_dapm_widget *, struct snd_kcontrol *, int);
};
static struct snd_soc_component *snd_soc_dapm_to_component(struct snd_soc_dapm_context *d)
{
    return d->component;
}
static struct simple_amp *snd_soc_component_get_drvdata(struct snd_soc_component *c)
{
    return c->priv;
}
static void gpiod_set_value_cansleep(struct gpio_desc *gpio, int value)
{
    gpio->value = value;
    gpio->writes++;
}
#include "dapm-under-test.c"

struct device { const char *of_node; };
struct snd_soc_dai_link { unsigned int ignore_pmdown_time; };
struct snd_soc_pcm_runtime {
    unsigned int pmdown_time;
    struct snd_soc_dai_link *dai_link;
    struct snd_soc_component *components[1];
};
static int of_device_is_compatible(const char *node, const char *compatible)
{
    return !strcmp(node, compatible);
}
#define for_each_rtd_components(rtd, i, component) \
    for ((i) = 0; (i) < 1 && ((component) = (rtd)->components[i]); (i)++)
#include "shutdown-under-test.c"

int main(void)
{
    struct gpio_desc gpio = { .value = 0 };
    struct simple_amp priv = { .gpiod_enable = &gpio };
    struct snd_soc_component component = { .priv = &priv };
    struct snd_soc_dapm_context context = { .component = &component };
    amplifier.dapm = &context;
    assert(amplifier.event_flags == (SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_PRE_PMD));

    for (unsigned int i = 0; i < sizeof(codec_outputs) / sizeof(codec_outputs[0]); i++) {
        struct snd_soc_dapm_widget *codec = &codec_outputs[i];
        assert(dapm_seq_compare(codec, &amplifier, true) < 0);
        assert(dapm_seq_compare(&amplifier, codec, false) < 0);
        /* Show the ordering defect with the old descriptor, using the real comparator. */
        struct snd_soc_dapm_widget old_amplifier = amplifier;
        old_amplifier.subseq = 0;
        assert(dapm_seq_compare(&old_amplifier, codec, true) < 0);
    }
    puts("PASS: codec charge pump/output drivers precede speaker enable; speaker disable precedes codec shutdown");

    assert(amplifier.event(&amplifier, NULL, SND_SOC_DAPM_POST_PMU) == 0);
    assert(gpio.value == 1 && gpio.writes == 1);
    assert(amplifier.event(&amplifier, NULL, SND_SOC_DAPM_PRE_PMD) == 0);
    assert(gpio.value == 0 && gpio.writes == 2);
    assert(amplifier.event(&amplifier, NULL, 0) == -EINVAL);
    assert(gpio.value == 0 && gpio.writes == 2);
    puts("PASS: actual amplifier events drive GPIO high/low and reject unsupported events");

    struct snd_soc_component_driver driver = { .use_pmdown_time = 1 };
    component.driver = &driver;
    struct snd_soc_dai_link link = { 0 };
    struct snd_soc_pcm_runtime runtime = {
        .pmdown_time = 5000, .dai_link = &link, .components = { &component }
    };
    struct device board = { .of_node = "pine64,pinetab-v-soundcard" };
    struct device other = { .of_node = "simple-audio-card" };
    apply_board_policy(&other, &link);
    assert(!snd_soc_runtime_ignore_pmdown_time(&runtime));
    apply_board_policy(&board, &link);
    assert(snd_soc_runtime_ignore_pmdown_time(&runtime));
    puts("PASS: PineTab-V closes without the five-second analog tail; other boards keep the codec delay");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    source = args.kernel_source
    header = (source / 'include/sound/soc-dapm.h').read_text()
    dapm = (source / 'sound/soc/soc-dapm.c').read_text()
    amplifier = (source / 'sound/soc/codecs/simple-amplifier.c').read_text()
    codec = (source / 'sound/soc/codecs/es8316.c').read_text()
    card = (source / 'sound/soc/generic/simple-card.c').read_text()
    pcm = (source / 'sound/soc/soc-pcm.c').read_text()
    amp_widgets = extract_block(amplifier, 'static const struct snd_soc_dapm_widget simple_amp_dapm_widgets[]')
    amp_call = widget_calls(amp_widgets, 'SND_SOC_DAPM_OUT_DRV_S')
    assert len(amp_call) == 1, 'External amplifier requires explicit output-driver subsequence'
    outputs = widget_calls(codec, 'SND_SOC_DAPM_OUT_DRV')
    assert len(outputs) == 4, 'Review ES8316 output-stage changes before updating the test'
    board_policy = re.search(
        r'if \(of_device_is_compatible\(dev->of_node, "pine64,pinetab-v-soundcard"\)\)\s*'
        r'dai_link->ignore_pmdown_time = 1;', card)
    assert board_policy, 'Power-down override must be scoped to the PineTab-V compatible'
    generated = '\n'.join([
        extract_block(header, 'enum snd_soc_dapm_type') + ';',
        extract_macro(header, 'SND_SOC_DAPM_INIT_REG_VAL'),
        extract_macro(header, 'SND_SOC_DAPM_OUT_DRV'),
        extract_macro(header, 'SND_SOC_DAPM_OUT_DRV_S'),
        extract_block(dapm, 'static int dapm_up_seq[]') + ';',
        extract_block(dapm, 'static int dapm_down_seq[]') + ';',
        extract_block(dapm, 'static int dapm_seq_compare'),
        extract_block(amplifier, 'static int simple_amp_power_event'),
        'static struct snd_soc_dapm_widget amplifier = ' + amp_call[0][:-1] + ';',
        'static struct snd_soc_dapm_widget codec_outputs[] = {\n' + '\n'.join(outputs) + '\n};',
    ])
    shutdown = (
        'static void apply_board_policy(struct device *dev, struct snd_soc_dai_link *dai_link) {\n' +
        board_policy.group(0) + '\n}\n' +
        extract_block(pcm, 'bool snd_soc_runtime_ignore_pmdown_time'))
    with tempfile.TemporaryDirectory(prefix='pinetabv-speaker-power-') as directory:
        root = Path(directory)
        (root / 'dapm-under-test.c').write_text(generated)
        (root / 'shutdown-under-test.c').write_text(shutdown)
        (root / 'es8316.h').write_text((source / 'sound/soc/codecs/es8316.h').read_text())
        (root / 'harness.c').write_text(HARNESS)
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-parameter', '-fsanitize=address,undefined',
                        str(root / 'harness.c'), '-o', str(root / 'regression-test')], check=True)
        subprocess.run([str(root / 'regression-test')], check=True)
    print('Speaker sequencing regression passed; transient amplitude still needs physical validation')


if __name__ == '__main__':
    main()
