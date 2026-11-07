/* Test-only ALSA control card. PCM traffic uses alsa-lib's null plugin.
 * Loaded only by test-pinetabv-audio-routes.py with a private ALSA config;
 * neither this plugin nor the test opens a kernel sound control or PCM.
 */
#include <alsa/asoundlib.h>
#include <alsa/control_external.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

struct control {
	const char *name;
	int type, count;
	long maximum, value[2];
};

/* Deliberately stale ALSA state: prove ACP replaces UCM BootSequence setup.
 * Closed digital paths, open analog bypasses, disabled ramp, zero gains and
 * enabled ALC must all be corrected when the active routes are selected.
 */
static struct control controls[] = {
	{ "Internal Speakers Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
	{ "Headset Microphone Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
	{ "Internal Microphone Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
	{ "Left Headphone Mixer LLIN Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 1 } },
	{ "Right Headphone Mixer RLIN Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 1 } },
	{ "Left Headphone Mixer Left DAC Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
	{ "Right Headphone Mixer Right DAC Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
	{ "DAC Soft Ramp Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
	{ "Headphone Playback Volume", SND_CTL_ELEM_TYPE_INTEGER, 2, 3, { 0, 0 } },
	{ "Headphone Mixer Volume", SND_CTL_ELEM_TYPE_INTEGER, 2, 11, { 0, 0 } },
	{ "DAC Playback Volume", SND_CTL_ELEM_TYPE_INTEGER, 2, 192, { 0, 0 } },
	{ "ADC Capture Volume", SND_CTL_ELEM_TYPE_INTEGER, 1, 192, { 0, 0 } },
	{ "ADC PGA Gain Volume", SND_CTL_ELEM_TYPE_INTEGER, 1, 10, { 0, 0 } },
	{ "ALC Capture Switch", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 1 } },
	{ "Differential Mux", SND_CTL_ELEM_TYPE_ENUMERATED, 1, 3, { 0 } },
	{ "Headphones Jack", SND_CTL_ELEM_TYPE_BOOLEAN, 1, 1, { 0 } },
};
#define N_CONTROLS (sizeof(controls) / sizeof(controls[0]))
#define JACK_KEY (N_CONTROLS - 1)

static const char *mux_items[] = {
	"lin1-rin1", "lin2-rin2", "lin1-rin1 with 20db Boost",
	"lin2-rin2 with 20db Boost",
};

static void snapshot(void)
{
	const char *path = getenv("PINETABV_MOCK_CTL_STATE");
	if (!path)
		return;
	FILE *out = fopen(path, "w");
	if (!out)
		abort();
	for (unsigned int i = 0; i < N_CONTROLS; i++)
		fprintf(out, "%s=%ld,%ld\n", controls[i].name,
			controls[i].value[0], controls[i].value[1]);
	fclose(out);
}

static void close_ctl(snd_ctl_ext_t *ext)
{
	close(ext->poll_fd);
	free(ext);
}

static int elem_count(snd_ctl_ext_t *ext)
{
	(void)ext;
	return N_CONTROLS;
}

static int elem_list(snd_ctl_ext_t *ext, unsigned int offset, snd_ctl_elem_id_t *id)
{
	(void)ext;
	if (offset >= N_CONTROLS)
		return -EINVAL;
	snd_ctl_elem_id_set_interface(id, offset == JACK_KEY ?
		SND_CTL_ELEM_IFACE_CARD : SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_id_set_name(id, controls[offset].name);
	snd_ctl_elem_id_set_numid(id, offset + 1);
	return 0;
}

static snd_ctl_ext_key_t find_elem(snd_ctl_ext_t *ext, const snd_ctl_elem_id_t *id)
{
	(void)ext;
	unsigned int num = snd_ctl_elem_id_get_numid(id);
	if (num && num <= N_CONTROLS)
		return num - 1;
	for (unsigned int i = 0; i < N_CONTROLS; i++)
		if (!strcmp(snd_ctl_elem_id_get_name(id), controls[i].name))
			return i;
	return SND_CTL_EXT_KEY_NOT_FOUND;
}

static int attribute(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, int *type,
		     unsigned int *access, unsigned int *count)
{
	(void)ext;
	*type = controls[key].type;
	*access = key == JACK_KEY ? SND_CTL_EXT_ACCESS_READ : SND_CTL_EXT_ACCESS_READWRITE;
	*count = controls[key].count;
	return 0;
}

static int integer_info(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key,
			long *minimum, long *maximum, long *step)
{
	(void)ext;
	*minimum = 0;
	*maximum = controls[key].maximum;
	*step = 1;
	return 0;
}

static int enumerated_info(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int *items)
{
	(void)ext;
	(void)key;
	*items = sizeof(mux_items) / sizeof(mux_items[0]);
	return 0;
}

static int enumerated_name(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key,
			   unsigned int item, char *name, size_t size)
{
	(void)ext;
	(void)key;
	if (item >= sizeof(mux_items) / sizeof(mux_items[0]))
		return -EINVAL;
	snprintf(name, size, "%s", mux_items[item]);
	return 0;
}

static int read_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	(void)ext;
	for (int i = 0; i < controls[key].count; i++)
		value[i] = controls[key].value[i];
	return 0;
}

static int write_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	(void)ext;
	for (int i = 0; i < controls[key].count; i++)
		controls[key].value[i] = value[i];
	snapshot();
	return 1;
}

static int read_enumerated(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int *value)
{
	(void)ext;
	*value = controls[key].value[0];
	return 0;
}

static int write_enumerated(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int *value)
{
	(void)ext;
	controls[key].value[0] = *value;
	snapshot();
	return 1;
}

static int read_event(snd_ctl_ext_t *ext, snd_ctl_elem_id_t *id, unsigned int *mask)
{
	(void)ext;
	(void)id;
	(void)mask;
	return -EAGAIN;
}

static const snd_ctl_ext_callback_t callbacks = {
	.close = close_ctl,
	.elem_count = elem_count,
	.elem_list = elem_list,
	.find_elem = find_elem,
	.get_attribute = attribute,
	.get_integer_info = integer_info,
	.get_enumerated_info = enumerated_info,
	.get_enumerated_name = enumerated_name,
	.read_integer = read_integer,
	.write_integer = write_integer,
	.read_enumerated = read_enumerated,
	.write_enumerated = write_enumerated,
	.read_event = read_event,
};

SND_CTL_PLUGIN_DEFINE_FUNC(pinetabv_mock)
{
	(void)root;
	(void)conf;
	snd_ctl_ext_t *ext = calloc(1, sizeof(*ext));
	if (!ext)
		return -ENOMEM;
	ext->version = SND_CTL_EXT_VERSION;
	ext->card_idx = 0;
	snprintf(ext->id, sizeof(ext->id), "PineTabV");
	snprintf(ext->driver, sizeof(ext->driver), "pinetabv-mock");
	snprintf(ext->name, sizeof(ext->name), "PineTab-V ES8316 Audio");
	snprintf(ext->longname, sizeof(ext->longname), "PineTab-V ES8316 Audio");
	snprintf(ext->mixername, sizeof(ext->mixername), "ES8316");
	ext->poll_fd = eventfd(0, EFD_NONBLOCK);
	ext->callback = &callbacks;
	controls[JACK_KEY].value[0] = getenv("PINETABV_MOCK_HEADPHONES") ?
		atoi(getenv("PINETABV_MOCK_HEADPHONES")) : 0;
	snapshot();
	int err = snd_ctl_ext_create(ext, name, mode);
	if (err < 0) {
		close_ctl(ext);
		return err;
	}
	*handlep = ext->handle;
	return 0;
}
SND_CTL_PLUGIN_SYMBOL(pinetabv_mock);

/* Associate null PCMs with the mock mixer when ACP probes a mapping. */
int snd_pcm_info_get_card(const snd_pcm_info_t *info)
{
	(void)info;
	return 0;
}
