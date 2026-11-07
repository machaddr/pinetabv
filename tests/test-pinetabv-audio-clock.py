#!/usr/bin/env python3
"""Exercise the real ES8316 hw_params function across stream transitions."""

import argparse
from pathlib import Path
import re
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
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "es8316.h"
typedef uint8_t u8;
typedef uint16_t u16;
#define ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof((a)[0])))
#define SNDRV_PCM_STREAM_PLAYBACK 0
#define SNDRV_PCM_STREAM_CAPTURE 1
enum { SNDRV_PCM_FORMAT_S16_LE, SNDRV_PCM_FORMAT_S20_3LE,
       SNDRV_PCM_FORMAT_S24_LE, SNDRV_PCM_FORMAT_S24_3LE,
       SNDRV_PCM_FORMAT_S32_LE, UNSUPPORTED_FORMAT };
struct es8316_priv { unsigned int sysclk; };
struct snd_soc_component { struct es8316_priv *priv; unsigned int regs[256]; };
struct snd_soc_dai { struct snd_soc_component *component; };
struct snd_pcm_substream { int stream; };
struct snd_pcm_hw_params { unsigned int rate; int format; };
static const unsigned int supported_mclk_lrck_ratios[] = {
    256, 384, 400, 500, 512, 768, 1024
};
#define params_rate(p) ((p)->rate)
#define params_format(p) ((p)->format)
static int params_physical_width(const struct snd_pcm_hw_params *p)
{
    switch (p->format) {
    case SNDRV_PCM_FORMAT_S16_LE: return 16;
    case SNDRV_PCM_FORMAT_S20_3LE:
    case SNDRV_PCM_FORMAT_S24_3LE: return 24;
    case SNDRV_PCM_FORMAT_S24_LE:
    case SNDRV_PCM_FORMAT_S32_LE: return 32;
    default: return -EINVAL;
    }
}
static struct es8316_priv *snd_soc_component_get_drvdata(struct snd_soc_component *c)
{
    return c->priv;
}
static int snd_soc_component_update_bits(struct snd_soc_component *c,
                                         unsigned int reg, unsigned int mask,
                                         unsigned int value)
{
    c->regs[reg] = (c->regs[reg] & ~mask) | (value & mask);
    return 0;
}
#include "hw-params-under-test.c"

static void check_rate_transition(void)
{
    struct es8316_priv priv = { .sysclk = 12288000 };
    struct snd_soc_component c = { .priv = &priv };
    struct snd_soc_dai dai = { .component = &c };
    struct snd_pcm_substream stream = { .stream = SNDRV_PCM_STREAM_PLAYBACK };
    struct snd_pcm_hw_params p = { .rate = 24000, .format = SNDRV_PCM_FORMAT_S32_LE };
    c.regs[ES8316_CLKMGR_CLKSW] = 0x1f;
    assert(es8316_pcm_hw_params(&stream, &p, &dai) == 0);
    assert(c.regs[ES8316_CLKMGR_CLKSW] == (0x1f | ES8316_CLKMGR_CLKSW_MCLK_DIV));
    p.rate = 48000;
    assert(es8316_pcm_hw_params(&stream, &p, &dai) == 0);
    assert(c.regs[ES8316_CLKMGR_CLKSW] == 0x1f);
    assert((c.regs[ES8316_CLKMGR_DACDIV1] & 0xf) == 1);
    assert(c.regs[ES8316_CLKMGR_DACDIV2] == 0);
    p.rate = 24000;
    assert(es8316_pcm_hw_params(&stream, &p, &dai) == 0);
    assert(c.regs[ES8316_CLKMGR_CLKSW] & ES8316_CLKMGR_CLKSW_MCLK_DIV);
    puts("PASS: 24k -> 48k -> 24k restores the correct MCLK divider and preserves other clocks");
}

static void check_duplex_rate(unsigned int rate, int first_format, int second_format)
{
    struct es8316_priv priv = { .sysclk = 12288000 };
    struct snd_soc_component c = { .priv = &priv };
    struct snd_soc_dai dai = { .component = &c };
    struct snd_pcm_substream playback = { .stream = SNDRV_PCM_STREAM_PLAYBACK };
    struct snd_pcm_substream capture = { .stream = SNDRV_PCM_STREAM_CAPTURE };
    struct snd_pcm_hw_params p = { .rate = rate, .format = first_format };
    c.regs[ES8316_SERDATA_DAC] = c.regs[ES8316_SERDATA_ADC] = 0xe3;
    assert(es8316_pcm_hw_params(&playback, &p, &dai) == 0);
    unsigned int dac = c.regs[ES8316_SERDATA_DAC];
    unsigned int bclk = c.regs[ES8316_SERDATA1];
    p.format = second_format;
    assert(es8316_pcm_hw_params(&capture, &p, &dai) == 0);
    assert(c.regs[ES8316_SERDATA_DAC] == dac);
    assert(c.regs[ES8316_SERDATA1] == bclk);
    unsigned int expected = second_format == SNDRV_PCM_FORMAT_S32_LE ? ES8316_SERDATA2_LEN_32 :
                            second_format == SNDRV_PCM_FORMAT_S20_3LE ? ES8316_SERDATA2_LEN_20 :
                            ES8316_SERDATA2_LEN_24;
    assert((c.regs[ES8316_SERDATA_ADC] & ES8316_SERDATA2_LEN_MASK) == expected);
    unsigned int adc = c.regs[ES8316_SERDATA_ADC];
    assert(es8316_pcm_hw_params(&playback, &p, &dai) == 0);
    assert(c.regs[ES8316_SERDATA_ADC] == adc);
    assert((c.regs[ES8316_SERDATA_DAC] & ~ES8316_SERDATA2_LEN_MASK) == 0xe3);
    assert((adc & ~ES8316_SERDATA2_LEN_MASK) == 0xe3);
}

static void check_duplex(void)
{
    static const unsigned int rates[] = { 8000, 12000, 16000, 24000, 32000, 48000 };
    for (unsigned int i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
        check_duplex_rate(rates[i], SNDRV_PCM_FORMAT_S32_LE, SNDRV_PCM_FORMAT_S24_LE);
        check_duplex_rate(rates[i], SNDRV_PCM_FORMAT_S24_LE, SNDRV_PCM_FORMAT_S32_LE);
        check_duplex_rate(rates[i], SNDRV_PCM_FORMAT_S20_3LE, SNDRV_PCM_FORMAT_S24_3LE);
        check_duplex_rate(rates[i], SNDRV_PCM_FORMAT_S24_3LE, SNDRV_PCM_FORMAT_S20_3LE);
    }
    puts("PASS: duplex significant-width changes preserve opposite streams/BCLK at all six oscillator rates");
}

static void check_invalid_params(void)
{
    struct es8316_priv priv = { .sysclk = 12288000 };
    struct snd_soc_component c = { .priv = &priv };
    struct snd_soc_dai dai = { .component = &c };
    struct snd_pcm_substream stream = { .stream = SNDRV_PCM_STREAM_PLAYBACK };
    struct snd_pcm_hw_params p = { .rate = 44100, .format = SNDRV_PCM_FORMAT_S16_LE };
    unsigned int before[256];
    memset(c.regs, 0x35, sizeof(c.regs));
    memcpy(before, c.regs, sizeof(before));
    assert(es8316_pcm_hw_params(&stream, &p, &dai) == -EINVAL);
    assert(memcmp(before, c.regs, sizeof(before)) == 0);
    p.rate = 24000;
    p.format = UNSUPPORTED_FORMAT;
    assert(es8316_pcm_hw_params(&stream, &p, &dai) == -EINVAL);
    assert(memcmp(before, c.regs, sizeof(before)) == 0);
    puts("PASS: unsupported rate/format leaves all codec registers unchanged");
}

int main(void)
{
    check_rate_transition();
    check_duplex();
    check_invalid_params();
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    codecs = args.kernel_source / 'sound/soc/codecs'
    source = (codecs / 'es8316.c').read_text()
    dai = re.search(r'static struct snd_soc_dai_driver es8316_dai = \{(.*?)\n\};',
                    source, re.S).group(1)
    assert re.search(r'\.symmetric_sample_bits\s*=\s*1', dai), \
        'ES8316 must constrain duplex physical sample widths because BCLK is shared'
    with tempfile.TemporaryDirectory(prefix='pinetabv-audio-clock-') as directory:
        root = Path(directory)
        (root / 'es8316.h').write_text((codecs / 'es8316.h').read_text())
        (root / 'hw-params-under-test.c').write_text(
            extract_function(source, 'es8316_pcm_hw_params'))
        harness = root / 'harness.c'
        binary = root / 'regression-test'
        harness.write_text(HARNESS)
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', str(harness), '-o', str(binary)],
                       check=True)
        subprocess.run([str(binary)], check=True)
    print('ES8316 source regression passed; analog noise and physical audio need tablet testing')


if __name__ == '__main__':
    main()
