#!/usr/bin/env python3
"""Check the actual RTL8852BU mode-switch decision with mocked USB hardware."""

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
enum { USB_SPEED_HIGH = 2, USB_SPEED_SUPER = 3 };
enum { RTW89_CHIP_AX, RTW89_CHIP_BE };
enum { RTL8852B, RTL8852A, RTL8922A };
struct usb_device { struct usb_device *parent; int speed; struct { uint16_t idVendor,idProduct; } descriptor; };
struct rtw89_usb { struct usb_device *udev; };
struct chip_info { int chip_id,chip_gen; };
struct rtw89_dev { struct chip_info *chip; struct rtw89_usb usb; };
static bool pinetabv;
static unsigned int ax_calls,be_calls,log_calls;
#define le16_to_cpu(value) (value)
static struct rtw89_usb *rtw89_usb_priv(struct rtw89_dev *dev) { return &dev->usb; }
static bool of_machine_is_compatible(const char *compatible) { assert(!strcmp(compatible,"pine64,pinetab-v"));return pinetabv; }
static int rtw89_usb_switch_mode_ax(struct rtw89_dev *dev) { (void)dev;ax_calls++;return 1; }
static int rtw89_usb_switch_mode_be(struct rtw89_dev *dev) { (void)dev;be_calls++;return 1; }
static void rtw89_info(struct rtw89_dev *dev,const char *message) { (void)dev;assert(message);log_calls++; }
#include "switch-under-test.c"
static void reset(void) { pinetabv=true;ax_calls=be_calls=log_calls=0; }
/* Preserve the actual probe's condition which decides whether registration runs. */
static bool registration_continues(struct rtw89_dev *rtwdev) { int ret=rtw89_usb_switch_mode(rtwdev);return !ret; }
int main(void) {
    struct usb_device hub={ .speed=USB_SPEED_HIGH,.descriptor={ .idVendor=0x05e3,.idProduct=0x0608 } };
    struct usb_device radio={ .parent=&hub,.speed=USB_SPEED_HIGH };
    struct chip_info chip={ .chip_id=RTL8852B,.chip_gen=RTW89_CHIP_AX };
    struct rtw89_dev dev={ .chip=&chip,.usb={.udev=&radio} };

    reset();
    assert(registration_continues(&dev)&&!ax_calls&&!be_calls&&log_calls==1);
    puts("PASS: PineTab-V onboard combo radio skips mode-switch writes and continues registration");

    reset();pinetabv=false;
    assert(!registration_continues(&dev)&&ax_calls==1&&!be_calls);
    puts("PASS: other machines retain automatic switching");

    reset();chip.chip_id=RTL8852A;
    assert(!registration_continues(&dev)&&ax_calls==1&&!be_calls);
    puts("PASS: other chip IDs retain automatic switching");

    reset();chip.chip_id=RTL8852B;hub.descriptor.idProduct=0x0610;
    assert(!registration_continues(&dev)&&ax_calls==1&&!be_calls);
    puts("PASS: USB3 hub companion with different product ID retains automatic switching");

    reset();hub.descriptor.idProduct=0x0608;hub.descriptor.idVendor=0x1234;
    assert(!registration_continues(&dev)&&ax_calls==1&&!be_calls);
    puts("PASS: unrelated parent hub vendor does not activate board quirk");

    reset();radio.parent=NULL;
    assert(!registration_continues(&dev)&&ax_calls==1&&!be_calls);
    puts("PASS: missing parent hub is handled without a NULL dereference");

    reset();radio.parent=&hub;radio.speed=USB_SPEED_SUPER;
    assert(registration_continues(&dev)&&!ax_calls&&!be_calls);
    puts("PASS: already-SuperSpeed adapter retains the original registration path");

    reset();radio.speed=USB_SPEED_HIGH;chip.chip_id=RTL8922A;chip.chip_gen=RTW89_CHIP_BE;
    assert(!registration_continues(&dev)&&!ax_calls&&be_calls==1);
    puts("PASS: BE-generation mode-switch path remains available");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    source = (args.kernel_source / 'drivers/net/wireless/realtek/rtw89/usb.c').read_text()
    with tempfile.TemporaryDirectory(prefix='pinetabv-radio-mode-') as directory:
        root = Path(directory)
        (root / 'switch-under-test.c').write_text(extract_function(source, 'rtw89_usb_switch_mode'))
        harness = root / 'harness.c'
        binary = root / 'regression-test'
        harness.write_text(HARNESS)
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', str(harness), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('RTL8852BU USB mode policy: eight source-level checks passed; radio hardware is not exercised')


if __name__ == '__main__':
    main()
