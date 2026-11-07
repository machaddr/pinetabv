#!/usr/bin/env python3
"""Exercise generated ACP profiles and all route pairs with real spa-acp-tool.

The external ALSA test control driver and null PCMs never touch host audio.
This checks PipeWire's native profile/path parser, mixer element discovery,
jack availability, hardware control writes, and duplex mapping preservation.
It does not replace playback and microphone tests on a tablet.
"""
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

# This private config replaces all hw controls/PCMs used by the ACP tool.
# No host asound.conf is included and no kernel sound device can be opened.
ALSA_CONFIG = '''
ctl.hw {
 @args [ CARD ]
 @args.CARD { type string default 0 }
 type pinetabv_mock
}
pcm.hw {
 @args [ CARD DEV SUBDEV ]
 @args.CARD { type string default 0 }
 @args.DEV { type integer default 0 }
 @args.SUBDEV { type integer default -1 }
 type null
}
'''


class AcpTool:
    def __init__(self, profile, environment):
        properties = ('api.alsa.use-ucm=false api.alsa.soft-mixer=true '
                      'api.acp.disable-pro-audio=true api.acp.probe-rate=48000 '
                      f'device.profile-set={profile}')
        self.process = subprocess.Popen(
            ['spa-acp-tool', '-c', '0', '-p', properties], env=environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.read_prompt()

    def read_prompt(self):
        output = bytearray()
        deadline = time.monotonic() + 10
        while not output.endswith(b'>>>'):
            assert self.selector.select(max(0, deadline - time.monotonic())), output.decode()
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, output.decode()
            output.extend(data)
        text = output.decode()
        assert not re.search(r'Failed|Invalid|unknown command|parse error|arguments:', text), text
        return text

    def command(self, command):
        self.process.stdin.write((command + '\n').encode())
        self.process.stdin.flush()
        return self.read_prompt()

    def close(self):
        try:
            self.process.stdin.write(b'quit\n')
            self.process.stdin.flush()
            assert self.process.wait(timeout=10) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.selector.close()
            self.process.stdin.close()
            self.process.stdout.close()


def controls(path):
    return {name: tuple(map(int, values.split(',')))
            for name, values in (line.split('=', 1) for line in path.read_text().splitlines())}


def active_duplex(tool):
    listing = tool.command('list')
    active = re.findall(r'\* device (\d+): direction:(playback|capture) name:"([^"]+)"', listing)
    assert set(active) == {('0', 'playback', 'pinetabv-output'),
                           ('1', 'capture', 'pinetabv-input')}, listing
    assert re.search(r'\* profile \d+: name:"HiFi"', listing), listing
    assert not re.search(r'\* profile \d+: name:"off"', listing), listing
    return listing


def exercise(stage, environment, plugged):
    state_file = stage / 'controls.state'
    environment = {**environment, 'PINETABV_MOCK_CTL_STATE': str(state_file),
                   'PINETABV_MOCK_HEADPHONES': str(int(plugged))}
    tool = AcpTool(stage / 'test-profile.conf', environment)
    try:
        listing = active_duplex(tool)
        profiles = re.findall(r'profile \d+: name:"([^"]+)"', listing)
        assert profiles == ['off', 'HiFi'], listing
        ports = dict((name, int(index)) for index, name in
                     re.findall(r'port (\d+): name:"([^"]+)"', listing))
        expected = {'pinetabv-output-speaker', 'pinetabv-output-headphones',
                    'pinetabv-output-off', 'pinetabv-input-internal-mic',
                    'pinetabv-input-headset-mic', 'pinetabv-input-off'}
        assert set(ports) == expected, listing
        assert re.search(r'port \d+: name:"pinetabv-output-headphones".*available: ' +
                         ('yes' if plugged else 'no'), listing), listing
        # Plugging plain headphones must not mark either microphone unavailable.
        for mic in ('internal-mic', 'headset-mic', 'off'):
            assert re.search(r'port \d+: name:"pinetabv-input-' + mic +
                             '".*available: unknown', listing), listing

        # ACP, rather than UCM BootSequence, now owns desktop initialization.
        # The mock starts with zero gains and incorrect path/filter switches.
        initial = controls(state_file)
        for name, expected_value in {
            'Headphone Playback Volume': (3, 3),
            'Headphone Mixer Volume': (11, 11),
            'DAC Playback Volume': (192, 192),
            'ADC Capture Volume': (192, 0),
            'ADC PGA Gain Volume': (7, 0),
            'ALC Capture Switch': (0, 0),
            'DAC Soft Ramp Switch': (1, 0),
            'Left Headphone Mixer LLIN Switch': (0, 0),
            'Right Headphone Mixer RLIN Switch': (0, 0),
            'Left Headphone Mixer Left DAC Switch': (1, 0),
            'Right Headphone Mixer Right DAC Switch': (1, 0),
            'Internal Microphone Switch': (1, 0),
            'Headset Microphone Switch': (0, 0),
            'Internal Speakers Switch': (int(not plugged), 0),
        }.items():
            assert initial[name] == expected_value, (name, initial[name], expected_value)

        playback_keys = {name for name in controls(state_file)
                         if any(word in name for word in ('DAC', 'Headphone', 'Speakers'))
                         and name != 'Headphones Jack'}
        capture_keys = set(controls(state_file)) - playback_keys - {'Headphones Jack'}
        for output in ('speaker', 'headphones', 'off'):
            before = controls(state_file)
            tool.command(f'set-port 0 {ports["pinetabv-output-" + output]}')
            after = controls(state_file)
            assert {key: before[key] for key in capture_keys} == {
                key: after[key] for key in capture_keys}, (output, before, after)
            assert after['Internal Speakers Switch'][0] == int(output == 'speaker'), after
            for mixer in ('Left Headphone Mixer Left DAC Switch',
                          'Right Headphone Mixer Right DAC Switch'):
                assert after[mixer][0] == int(output != 'off'), after
            assert after['Left Headphone Mixer LLIN Switch'][0] == 0, after
            assert after['Right Headphone Mixer RLIN Switch'][0] == 0, after
            assert after['DAC Soft Ramp Switch'][0] == 1, after
            if output != 'off':
                assert after['Headphone Playback Volume'] == (3, 3), after
                assert after['Headphone Mixer Volume'] == (11, 11), after
                assert after['DAC Playback Volume'] == (192, 192), after
            for mic in ('internal-mic', 'headset-mic', 'off'):
                before = controls(state_file)
                tool.command(f'set-port 1 {ports["pinetabv-input-" + mic]}')
                after = controls(state_file)
                assert {key: before[key] for key in playback_keys} == {
                    key: after[key] for key in playback_keys}, (mic, before, after)
                assert after['Internal Microphone Switch'][0] == int(mic == 'internal-mic'), after
                assert after['Headset Microphone Switch'][0] == int(mic == 'headset-mic'), after
                assert after['ADC Capture Volume'][0] == (0 if mic == 'off' else 192), after
                if mic != 'off':
                    assert after['Differential Mux'][0] == int(mic == 'internal-mic'), after
                    assert after['ADC PGA Gain Volume'][0] == 7, after
                    assert after['ALC Capture Switch'][0] == 0, after
                active_duplex(tool)
    finally:
        tool.close()


def main():
    if not shutil.which('spa-acp-tool'):
        raise SystemExit('spa-acp-tool is required (PipeWire ALSA tools)')
    with tempfile.TemporaryDirectory(prefix='pinetabv-audio-routes-') as directory:
        stage = Path(directory)
        env = {**os.environ, 'WORKDIR': str(stage / 'work'), 'SUDO_UID': '', 'SUDO_GID': ''}
        subprocess.run(['bash', '-c',
                        'source "$1"; trap - EXIT; ROOT_MNT="$2"; install_pinetabv_audio_ucm',
                        'test', str(ROOT / 'build-pinetabv-debian-sd.sh'), str(stage)],
                       env=env, check=True)
        acp = stage / 'usr/share/alsa-card-profile/mixer'
        profile = (acp / 'profile-sets/pinetabv.conf').read_text()
        for path in (acp / 'paths').glob('pinetabv-*.conf'):
            profile = profile.replace(path.stem, str(path.with_suffix('')))
        (stage / 'test-profile.conf').write_text(profile)
        (stage / 'asound.conf').write_text(ALSA_CONFIG)
        library = stage / 'libasound_module_ctl_pinetabv_mock.so'
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'alsa'],
                                        text=True).split()
        subprocess.run(['cc', '-shared', '-fPIC', '-DPIC', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/pinetabv-audio-mock.c'), '-o', str(library),
                        *flags], check=True)
        env.update(ALSA_CONFIG_PATH=str(stage / 'asound.conf'), ALSA_PLUGIN_DIR=str(stage),
                   LD_PRELOAD=str(library))
        exercise(stage, env, plugged=False)
        exercise(stage, env, plugged=True)
    print('Audio routes: real ACP parser and mixer restored stale controls and passed all 18 duplex route pairs; '
          'Off cuts only its direction; microphone changes preserve the output; '
          'both jack states passed (mock controls, no tablet hardware)')


if __name__ == '__main__':
    main()
