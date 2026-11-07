#!/usr/bin/env python3
"""Fault-inject the actual Realtek initializer and verify failures cannot reach firmware download."""

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
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16;
#define GFP_KERNEL 0
#define RTL_ROM_LMP_8822B 0x8822
#define RTL_ROM_LMP_8852A 0x8852
#define RTL_CHIP_SUBVER 1
#define RTL_CHIP_REV 2
#define RTL_SEC_PROJ 3
#define HCI_COMMAND_PKT 1
#define HCI_COMMAND_HDR_SIZE sizeof(struct hci_command_hdr)
#define ERR_PTR(error) ((void *)(intptr_t)(error))
#define PTR_ERR(ptr) ((long)(intptr_t)(ptr))
#define IS_ERR(ptr) ((uintptr_t)(ptr) >= (uintptr_t)-4095)
#define cpu_to_le16(n) (n)
#define le16_to_cpu(n) (n)
#define INIT_LIST_HEAD(head) ((void)(head))
struct list_head { int unused; };
struct ic_info { unsigned hci_ver,hci_rev,lmp_subver,hci_bus; bool has_rom_version, config_needed,has_msft_ext; const char *fw_name,*cfg_name,*hw_info; };
struct btrtl_device_info { struct ic_info *ic_info; struct list_head patch_subsecs; bool drop_fw; u8 key_id,rom_version; long fw_len,cfg_len; void *fw_data,*cfg_data; };
struct btrealtek_data { struct { const char *controller; } rtl_dump; };
struct sk_buff { unsigned char *data; unsigned pkt_type; };
struct hci_dev { int bus; int (*send)(struct hci_dev *, struct sk_buff *); };
struct hci_rp_read_local_version { u8 hci_ver; u16 hci_rev; u8 lmp_ver; u16 lmp_subver; };
struct hci_command_hdr { u16 opcode; u8 plen; };
static struct btrealtek_data core;
static struct ic_info chip={ .has_rom_version=true, .fw_name="rtl_bt/test_fw", .hw_info="test controller" };
static bool fail_alloc,fail_skb,unknown_chip;
static int subver_result,sec_result,free_calls,downloads,quirks;
static void *mock_zalloc(size_t size) { return fail_alloc ? NULL : calloc(1,size); }
#define kzalloc_obj(obj) mock_zalloc(sizeof(obj))
static void *hci_get_priv(struct hci_dev *hdev) { (void)hdev; return &core; }
static void log_message(struct hci_dev *hdev, const char *fmt, ...) { (void)hdev;(void)fmt; }
#define rtl_dev_info log_message
#define rtl_dev_err log_message
#define bt_dev_err log_message
static int btrtl_vendor_read_reg16(struct hci_dev *hdev,int command,u8 *out) {
    (void)hdev; if(command==RTL_SEC_PROJ) { if(sec_result<0)return sec_result; out[0]=7;out[1]=0;return 0; }
    if(subver_result<0)return subver_result;
    u16 value=command==RTL_CHIP_SUBVER?RTL_ROM_LMP_8852A:1;memcpy(out,&value,2);return 0;
}
static u16 get_unaligned_le16(u8 *p) { u16 n;memcpy(&n,p,2);return n; }
static struct ic_info *btrtl_match_ic(u16 lmp,u16 rev,u8 ver,int bus,u8 type) { (void)lmp;(void)rev;(void)ver;(void)bus;(void)type;return unknown_chip?NULL:&chip; }
static struct sk_buff *btrtl_read_local_version(struct hci_dev *hdev) {
    (void)hdev;struct sk_buff *skb=calloc(1,sizeof(*skb));
    struct hci_rp_read_local_version version={.hci_ver=9,.hci_rev=1,.lmp_ver=9,.lmp_subver=RTL_ROM_LMP_8852A};
    skb->data=malloc(sizeof(version));memcpy(skb->data,&version,sizeof(version));return skb;
}
static void kfree_skb(struct sk_buff *skb) { free(skb->data);free(skb); }
static bool rtl_has_chip_type(u16 version) { (void)version;return false; }
static int rtl_read_chip_type(struct hci_dev *hdev,u8 *type) { (void)hdev;*type=0;return 0; }
static struct sk_buff *bt_skb_alloc(size_t n,int gfp) { (void)gfp;if(fail_skb)return NULL;struct sk_buff *skb=calloc(1,sizeof(*skb));skb->data=malloc(n);return skb; }
static void *skb_put(struct sk_buff *skb,size_t n) { (void)n;return skb->data; }
#define hci_skb_pkt_type(skb) ((skb)->pkt_type)
static void msleep(unsigned n) { (void)n; }
static int rtl_read_rom_version(struct hci_dev *hdev,u8 *v) { (void)hdev;*v=1;return 0; }
static long rtl_load_file(struct hci_dev *hdev,const char *name,void **out) { (void)hdev;(void)name;*out=calloc(1,8);return 8; }
static void hci_set_msft_opcode(struct hci_dev *hdev,unsigned opcode) { (void)hdev;(void)opcode; }
static void btrtl_free(struct btrtl_device_info *info) { assert(info);free_calls++;free(info->fw_data);free(info->cfg_data);free(info); }
#include "initializer-under-test.c"
static int btrtl_download_firmware(struct hci_dev *hdev,struct btrtl_device_info *info) { (void)hdev;assert(info&&info->key_id==7);downloads++;return 0; }
static void btrtl_set_quirks(struct hci_dev *hdev,struct btrtl_device_info *info) { (void)hdev;assert(info);quirks++; }
#define hci_set_hw_info log_message
#include "setup-under-test.c"
static int send_command(struct hci_dev *hdev,struct sk_buff *skb) { (void)hdev;kfree_skb(skb);return 0; }
static void reset(void) { fail_alloc=fail_skb=unknown_chip=false;subver_result=sec_result=free_calls=downloads=quirks=0; }
int main(void) {
    struct hci_dev hdev={ .bus=3,.send=send_command };
    reset();sec_result=-EPROTO;
    struct btrtl_device_info *result=btrtl_initialize(&hdev,NULL);
    if(!result){puts("BASELINE BUG: security read error returns NULL instead of ERR_PTR(-EPROTO)");return 2;}
    assert(IS_ERR(result)&&PTR_ERR(result)==-EPROTO&&free_calls==1);
    reset();sec_result=-EPROTO;
    assert(btrtl_setup_realtek(&hdev)==-EPROTO&&!downloads&&!quirks&&free_calls==1);
    puts("PASS: -EPROTO is preserved and firmware download is never entered");
    reset();unknown_chip=true;fail_skb=true;
    assert(btrtl_setup_realtek(&hdev)==-ENOMEM&&!downloads&&!quirks&&free_calls==1);
    puts("PASS: drop-firmware command allocation failure returns -ENOMEM");
    reset();fail_alloc=true;
    assert(btrtl_setup_realtek(&hdev)==-ENOMEM&&!free_calls&&!downloads);
    puts("PASS: initial allocation failure remains -ENOMEM");
    reset();subver_result=-EIO;
    assert(btrtl_setup_realtek(&hdev)==-EIO&&free_calls==1&&!downloads);
    puts("PASS: earlier register error remains -EIO");
    reset();
    assert(!btrtl_setup_realtek(&hdev)&&free_calls==1&&downloads==1&&quirks==1);
    puts("PASS: successful identification still downloads firmware and sets quirks");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-source', type=Path, required=True)
    args = parser.parse_args()
    source = (args.kernel_source / 'drivers/bluetooth/btrtl.c').read_text()
    with tempfile.TemporaryDirectory(prefix='pinetabv-bluetooth-init-') as directory:
        root = Path(directory)
        (root / 'initializer-under-test.c').write_text(extract_function(source, 'btrtl_initialize'))
        (root / 'setup-under-test.c').write_text(extract_function(source, 'btrtl_setup_realtek'))
        harness = root / 'harness.c'
        binary = root / 'regression-test'
        harness.write_text(HARNESS)
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', str(harness), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('Realtek initialization: five source-level checks passed; USB hardware is not exercised')


if __name__ == '__main__':
    main()
