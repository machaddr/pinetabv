#!/usr/bin/env python3
"""Validate generated PineTab-V UCM and WirePlumber policy with their libraries."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent

HARNESS = r'''
#include <assert.h>
#include <string.h>
#include <alsa/asoundlib.h>
#include <wp/wp.h>

static snd_config_t *lookup(snd_config_t *config, const char *path)
{
    snd_config_t *value = NULL;
    assert(snd_config_search(config, path, &value) == 0);
    return value;
}

static long integer(snd_config_t *config, const char *path)
{
    long value;
    assert(snd_config_get_integer(lookup(config, path), &value) == 0);
    return value;
}

static void absent(snd_config_t *config, const char *path)
{
    snd_config_t *value = NULL;
    assert(snd_config_search(config, path, &value) < 0);
}

static void prop(WpProperties *props, const char *key, const char *expected)
{
    const char *value = wp_properties_get(props, key);
    assert(value != NULL && strcmp(value, expected) == 0);
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    snd_input_t *input = NULL;
    snd_config_t *ucm = NULL;
    assert(snd_input_stdio_open(&input, argv[1], "r") == 0);
    assert(snd_config_top(&ucm) == 0);
    assert(snd_config_load(ucm, input) == 0);
    /* Both microphones remain unknown-availability (manual headset choice),
     * so insertion cannot outrank or make the internal microphone unavailable.
     */
    assert(integer(ucm, "SectionDevice.Mic.Value.CapturePriority") >
           integer(ucm, "SectionDevice.Headset.Value.CapturePriority"));
    absent(ucm, "SectionDevice.Mic.Value.JackControl");
    absent(ucm, "SectionDevice.Headset.Value.JackControl");
    absent(ucm, "SectionDevice.Headset.Value.JackHWMute");
    const char *name;
    assert(snd_config_get_string(lookup(ucm,
        "SectionDevice.Headphones.Value.JackControl"), &name) == 0);
    assert(strcmp(name, "Headphones Jack") == 0);
    /* These must be reapplied on profile activation, not only first boot. */
    snd_config_t *sequence = lookup(ucm, "SectionVerb.EnableSequence");
    snd_config_iterator_t i, next;
    unsigned int ramp = 0, bypass = 0;
    snd_config_for_each(i, next, sequence) {
        if (snd_config_get_string(snd_config_iterator_entry(i), &name) == 0) {
            if (strcmp(name, "name='DAC Soft Ramp Switch' on") == 0) ramp++;
            if (strstr(name, "Headphone Mixer") && strstr(name, "LIN Switch' off")) bypass++;
        }
    }
    assert(ramp == 1 && bypass == 2);
    snd_config_delete(ucm);
    snd_input_close(input);

    wp_init(WP_INIT_ALL);
    GError *error = NULL;
    WpConf *conf = wp_conf_new_open(argv[2], NULL, &error);
    if (!conf) g_error("Policy parse failed: %s", error->message);
    WpSpaJson *rules = wp_conf_get_section(conf, "monitor.alsa.rules");
    assert(rules != NULL);
    WpProperties *card = wp_properties_new("api.alsa.card.name", "PineTab-V ES8316 Audio", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, card) > 0);
    prop(card, "api.alsa.soft-mixer", "true");
    prop(card, "api.alsa.use-ucm", "false");
    prop(card, "device.profile-set", "pinetabv.conf");
    prop(card, "device.profile", "HiFi");
    prop(card, "api.acp.disable-pro-audio", "true");
    prop(card, "api.acp.probe-rate", "48000");

    WpProperties *output = wp_properties_new("alsa.card_name", "PineTab-V ES8316 Audio",
                                            "media.class", "Audio/Sink", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, output) > 0);
    prop(output, "audio.rate", "48000");
    prop(output, "session.suspend-timeout-seconds", "1");
    prop(output, "node.pause-on-idle", "false");
    WpProperties *input_props = wp_properties_new("alsa.card_name", "PineTab-V ES8316 Audio",
                                                 "media.class", "Audio/Source", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, input_props) > 0);
    prop(input_props, "audio.rate", "48000");
    assert(wp_properties_get(input_props, "session.suspend-timeout-seconds") == NULL);
    WpProperties *usb = wp_properties_new("api.alsa.card.name", "USB Audio",
        "alsa.card_name", "USB Audio", "media.class", "Audio/Sink", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, usb) == 0);
    assert(wp_properties_get(usb, "audio.rate") == NULL);
    assert(wp_properties_get(usb, "api.alsa.soft-mixer") == NULL);
    assert(wp_properties_get(usb, "api.alsa.use-ucm") == NULL);
    assert(wp_properties_get(usb, "device.profile-set") == NULL);
    wp_properties_unref(card);
    wp_properties_unref(output);
    wp_properties_unref(input_props);
    wp_properties_unref(usb);
    wp_spa_json_unref(rules);
    g_object_unref(conf);
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path,
                        help='also check generated mixer names against the patched codec and DT')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pinetabv-audio-policy-') as directory:
        stage = Path(directory)
        subprocess.run(['bash', '-c',
                        'source "$1"; trap - EXIT; ROOT_MNT="$2"; install_pinetabv_audio_ucm',
                        'test', str(ROOT / 'build-pinetabv-debian-sd.sh'), str(stage)],
                       check=True)
        if args.kernel_source:
            codec = (args.kernel_source / 'sound/soc/codecs/es8316.c').read_text()
            controls = set(re.findall(r'SOC_[A-Z0-9_]+\(\s*"([^"]+)"', codec))
            for widget, array in re.findall(
                    r'SND_SOC_DAPM_MIXER\("([^"]+)",[^;]*?\b(es8316_\w+)\[0\],\s*ARRAY_SIZE', codec):
                body = re.search(r'\b' + array + r'\[\]\s*=\s*\{(.*?)\};', codec, re.S).group(1)
                controls.update(widget + ' ' + name for name in
                                re.findall(r'SOC_DAPM_\w+\("([^"]+)"', body))
            controls.update(re.findall(r'SND_SOC_DAPM_MUX\("([^"]+)"', codec))
            dt = (args.kernel_source /
                  'arch/riscv/boot/dts/starfive/jh7110-pine64-pinetab-v.dtsi').read_text()
            pins = re.search(r'simple-audio-card,pin-switches\s*=\s*(.*?);', dt, re.S).group(1)
            controls.update(name + ' Switch' for name in re.findall(r'"([^"]+)"', pins))
            for config in (stage / 'usr/share/alsa/ucm2/PineTabV').glob('*.conf'):
                names = set(re.findall(r'cset "name=\x27([^\x27]+)\x27', config.read_text()))
                assert not names - controls, f'{config.name}: unknown controls {names - controls}'
        source = stage / 'policy-test.c'
        binary = stage / 'policy-test'
        source.write_text(HARNESS)
        flags = subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'alsa', 'wireplumber-0.5'], text=True).split()
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', str(source),
                        '-o', str(binary), *flags], check=True)
        subprocess.run([str(binary), str(stage / 'usr/share/alsa/ucm2/PineTabV/HiFi.conf'),
                        str(stage / 'etc/wireplumber/wireplumber.conf.d/51-pinetabv-audio.conf')],
                       check=True)
        for card in ('PineTab-V', 'PineTab-V ES8316 Audio'):
            link = stage / f'usr/share/alsa/ucm2/conf.d/soundcard/{card}.conf'
            assert link.resolve().is_file(), link
    print('Audio policy: ALSA syntax, microphone routing, ramp/bypass controls, '
          'WirePlumber matching and unrelated-card isolation passed')


if __name__ == '__main__':
    main()
