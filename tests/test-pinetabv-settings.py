#!/usr/bin/env python3
"""Exercise the installed Settings launcher without starting a GUI or GTK."""
import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class SettingsLauncher(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pinetabv-settings-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run([
            "bash", "-c",
            'source "$1"; ROOT_MNT="$2"; install_pinetabv_settings_compat',
            "test", str(PROJECT / "build-pinetabv-debian-sd.sh"), str(self.root),
        ], check=True, stdout=subprocess.DEVNULL)
        self.compatible = self.root / "compatible"
        self.capture = self.root / "invocation.json"
        self.binary = self.root / "real-settings"
        self.binary.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['TEST_CAPTURE']).write_text(json.dumps({"
            "'argv': sys.argv[1:], 'renderer': os.environ.get('GSK_RENDERER'), "
            "'media': os.environ.get('GTK_MEDIA')}))\n"
        )
        self.binary.chmod(0o755)
        self.launcher = self.root / "usr/local/bin/gnome-control-center"
        wrapper = self.launcher.read_text()
        # Substitute filesystem paths only in the test copy: production has no
        # environment override that could bypass board detection or exec a fake.
        self.assertEqual(wrapper.count("/proc/device-tree/compatible"), 2)
        self.assertEqual(wrapper.count("/usr/bin/gnome-control-center"), 1)
        wrapper = wrapper.replace("/proc/device-tree/compatible", str(self.compatible))
        wrapper = wrapper.replace("/usr/bin/gnome-control-center", str(self.binary))
        self.launcher.write_text(wrapper)
        self.environment = os.environ.copy()
        self.environment.pop("GSK_RENDERER", None)
        self.environment.pop("GTK_MEDIA", None)
        self.environment["TEST_CAPTURE"] = str(self.capture)
        self.environment["PATH"] = f"{self.launcher.parent}:{os.environ['PATH']}"

    def invoke(self, *arguments, **environment):
        subprocess.run([str(self.launcher), *arguments], check=True,
                       env={**self.environment, **environment})
        return json.loads(self.capture.read_text())

    def test_pinetabv_and_arguments(self):
        # Test fallback-compatible matching, rather than only the first string.
        self.compatible.write_bytes(b"pine64,pinetab-v-20240730\0pine64,pinetab-v\0starfive,jh7110\0")
        self.assertEqual(self.invoke("mouse", "argument with spaces", "--name=value"), {
            "argv": ["mouse", "argument with spaces", "--name=value"],
            "renderer": "cairo", "media": "none",
        })

    def test_non_tablet_and_missing_device_tree(self):
        self.assertEqual(self.invoke("sound")["renderer"], None)
        self.compatible.write_bytes(b"pine64,pinetab2\0rockchip,rk3566\0")
        self.assertEqual(self.invoke("mouse"), {
            "argv": ["mouse"], "renderer": None, "media": None,
        })

    def test_explicit_diagnostic_overrides(self):
        self.compatible.write_bytes(b"pine64,pinetab-v\0")
        self.assertEqual(self.invoke("mouse", GSK_RENDERER="gl", GTK_MEDIA="gstreamer"), {
            "argv": ["mouse"], "renderer": "gl", "media": "gstreamer",
        })

    def test_desktop_exec_uses_path_wrapper(self):
        if not shutil.which("gio"):
            self.skipTest("gio is required to exercise desktop-file activation")
        self.compatible.write_bytes(b"pine64,pinetab-v\0")
        desktop = self.root / "gnome-mouse-panel.desktop"
        # GNOME 48.4's packaged desktop Exec and categories are kept unchanged.
        desktop.write_text(
            "[Desktop Entry]\nName=Mouse & Touchpad\nType=Application\n"
            "Exec=gnome-control-center mouse\nTerminal=false\n"
            "Categories=GNOME;GTK;Settings;HardwareSettings;X-GNOME-Settings-Panel;\n"
        )
        subprocess.run(["desktop-file-validate", str(desktop)], check=True)
        subprocess.run(["gio", "launch", str(desktop)], env=self.environment,
                       check=True, stdout=subprocess.DEVNULL)
        # Gio launches asynchronously; wait through the child rather than
        # assuming the result is present when gio returns.
        subprocess.run([sys.executable, "-c",
                        "import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); "
                        "exec('for _ in range(100):\\n if p.exists(): break\\n time.sleep(.02)'); "
                        "sys.exit(not p.exists())", str(self.capture)], check=True)
        self.assertEqual(json.loads(self.capture.read_text()), {
            "argv": ["mouse"], "renderer": "cairo", "media": "none",
        })

    def test_dbus_service_override(self):
        if not shutil.which("dbus-run-session") or not shutil.which("gdbus"):
            self.skipTest("D-Bus tools are required to exercise session activation")
        self.compatible.write_bytes(b"pine64,pinetab-v\0")
        local_share = self.root / "usr/local/share"
        service = local_share / "dbus-1/services/org.gnome.Settings.service"
        parsed = configparser.ConfigParser()
        parsed.read(service)
        self.assertEqual(parsed["D-BUS Service"]["Name"], "org.gnome.Settings")
        self.assertEqual(parsed["D-BUS Service"]["Exec"], "/usr/local/bin/gnome-control-center")
        service.write_text(service.read_text().replace(
            "/usr/local/bin/gnome-control-center", str(self.launcher)))
        system_share = self.root / "usr/share"
        system_service = system_share / "dbus-1/services/org.gnome.Settings.service"
        system_service.parent.mkdir(parents=True)
        system_service.write_text("[D-BUS Service]\nName=org.gnome.Settings\nExec=/bin/false\n")
        environment = {
            **self.environment,
            "XDG_DATA_DIRS": f"{local_share}:{system_share}",
            "XDG_DATA_HOME": str(self.root / "home-data"),
            "XDG_RUNTIME_DIR": str(self.root / "runtime"),
        }
        Path(environment["XDG_RUNTIME_DIR"]).mkdir(mode=0o700)
        result = subprocess.run([
            "dbus-run-session", "--", "gdbus", "call", "--session", "--timeout", "2",
            "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
            "--method", "org.freedesktop.DBus.StartServiceByName", "org.gnome.Settings", "0",
        ], env=environment, capture_output=True, text=True, timeout=15)
        # The fake binary deliberately does not own a bus name. The activation
        # error is expected; recording its execution proves override precedence.
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.capture.exists(), result.stderr)
        self.assertEqual(json.loads(self.capture.read_text()), {
            "argv": [], "renderer": "cairo", "media": "none",
        })


if __name__ == "__main__":
    unittest.main()
