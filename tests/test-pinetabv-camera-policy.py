#!/usr/bin/env python3
"""Validate generated camera rules against actual WirePlumber device/node keys."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile


PROJECT = Path(__file__).resolve().parents[1]
HARNESS = r'''
#include <assert.h>
#include <string.h>
#include <wp/wp.h>

static void prop(WpProperties *props, const char *key, const char *expected)
{
    const char *value = wp_properties_get(props, key);
    assert(value && !strcmp(value, expected));
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    wp_init(WP_INIT_ALL);
    GError *error = NULL;
    WpConf *conf = wp_conf_new_open(argv[1], NULL, &error);
    if (!conf) g_error("Camera policy parse failed: %s", error->message);
    WpSpaJson *rules = wp_conf_get_section(conf, "monitor.v4l2.rules");
    assert(rules);
    /* PipeWire's V4L2 udev monitor maps ID_V4L_PRODUCT onto this key. */
    WpProperties *raw = wp_properties_new("device.product.name", "PineTab-V Raw Camera", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, raw) > 0);
    prop(raw, "device.disabled", "true");
    WpProperties *isp = wp_properties_new("device.product.name", "PineTab-V Camera", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, isp) > 0);
    prop(isp, "device.description", "PineTab-V Camera");
    assert(!wp_properties_get(isp, "device.disabled"));
    /* SPA supplies the driver key to the node; WP has assigned its name. */
    WpProperties *node = wp_properties_new("api.v4l2.cap.driver", "starfive-camss",
        "node.name", "v4l2_input.platform_19840000.camss", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, node) > 0);
    prop(node, "node.description", "PineTab-V Camera");
    prop(node, "node.pause-on-idle", "true");
    prop(node, "session.suspend-timeout-seconds", "1");
    WpProperties *usb = wp_properties_new("device.product.name", "USB Camera",
        "api.v4l2.cap.driver", "uvcvideo", "node.name", "v4l2_input.usb_camera", NULL);
    assert(wp_json_utils_match_rules_update_properties(rules, usb) == 0);
    assert(!wp_properties_get(usb, "device.disabled"));
    assert(!wp_properties_get(usb, "node.pause-on-idle"));
    wp_properties_unref(raw);
    wp_properties_unref(isp);
    wp_properties_unref(node);
    wp_properties_unref(usb);
    wp_spa_json_unref(rules);
    g_object_unref(conf);
    return 0;
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix='pinetabv-camera-policy-') as directory:
        stage = Path(directory)
        env = dict(os.environ, WORKDIR=str(stage / 'work'), SUDO_UID='', SUDO_GID='')
        subprocess.run(['bash', '-c', 'source "$1"; trap - EXIT; ROOT_MNT="$2"; install_pinetabv_camera_policy; verify_pinetabv_camera_policy',
                        'test', str(PROJECT / 'build-pinetabv-debian-sd.sh'), str(stage)],
                       env=env, check=True)
        source_file = stage / 'policy.c'
        binary = stage / 'policy'
        source_file.write_text(HARNESS)
        flags = shlex.split(subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'wireplumber-0.5'], text=True))
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', str(source_file),
                        '-o', str(binary), *flags], check=True)
        subprocess.run([str(binary), str(stage / 'etc/wireplumber/wireplumber.conf.d/51-pinetabv-camera.conf')], check=True)
    print('Camera policy: raw hidden, ISP device visible, node matching and unrelated-camera isolation passed')


if __name__ == '__main__':
    main()
