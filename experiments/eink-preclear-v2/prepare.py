#!/usr/bin/env python3
"""Generate the paired, opt-in v2 binaries from the exact installed revision."""
import pathlib, subprocess, sys
rev = 'c40c8f325f3095e9846920dbb08b02726fbebe81'
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
def read(name):
    return subprocess.check_output(['git','show',f'{rev}:display/{name}']).decode()
def change(s, old, new):
    if s.count(old) != 1:
        raise SystemExit(f'Unexpected anchor ({s.count(old)}): {old!r}')
    return s.replace(old,new,1)
header = change(read('pb626-epd.h'), "RESET = 'R' };", "RESET = 'R', INIT_PANEL = 'I' };")
worker = change(read('pb626-epd.c'), 'puts("pb626-epd-shm-3");', 'puts("pb626-epd-shm-4-preclear");')
worker = change(worker, '\t\t\tcase CLEAN: case RESET: mode = GC16; break;', '\t\t\tcase INIT_PANEL: mode = INIT; break;\n\t\t\tcase CLEAN: case RESET: mode = GC16; break;')
# INIT already resets the committed pixel model to WHITE and sets known only
# after refresh succeeds. Acknowledgement is sent by the existing serve loop.
bridge = change(read('pb626-x11-epd.c'), 'execl("/usr/bin/pb626-epd", "pb626-epd",', 'execl("/usr/bin/pb626-epd-preclear-v2", "pb626-epd-preclear-v2",')
bridge = change(bridge, '\tsetup_gray(selected, lightness, gamma);\n\tsetup_quantization();\n', '')
bridge = change(bridge, '\tDisplay *display = XOpenDisplay(NULL);', '''	/* Start the persistent worker before expensive gray tables and X setup. */
	struct worker worker;
	if (start_worker(&worker, argv[1]))
		return EXIT_FAILURE;
	unlink(argv[2]);
	int profile = getenv("PB626_EPD_PROFILE") != NULL;
	if (profile)
		fprintf(stderr, "preclear-v2: INIT begin mono_us=%llu\\n", (unsigned long long)now_us());
	int precleared = submit(&worker, INIT_PANEL) == 0;
	if (profile)
		fprintf(stderr, "preclear-v2: %s mono_us=%llu\\n",
			precleared ? "INIT_ACK" : "FALLBACK_RESET", (unsigned long long)now_us());
	if (!precleared) {
		stop_worker(&worker);
		if (start_worker(&worker, argv[1]))
			return EXIT_FAILURE;
	}
	setup_gray(selected, lightness, gamma);
	setup_quantization();
	Display *display = XOpenDisplay(NULL);''')
bridge = change(bridge, '\t\tfprintf(stderr, "pb626-x11-epd: cannot connect to Xorg\\n");\n\t\treturn EXIT_FAILURE;', '\t\tfprintf(stderr, "pb626-x11-epd: cannot connect to Xorg\\n");\n\t\tstop_worker(&worker);\n\t\treturn EXIT_FAILURE;')
bridge = change(bridge, '\t\tfprintf(stderr, "pb626-x11-epd: unexpected Xorg screen dimensions\\n");\n\t\treturn EXIT_FAILURE;', '\t\tfprintf(stderr, "pb626-x11-epd: unexpected Xorg screen dimensions\\n");\n\t\tstop_worker(&worker);\n\t\treturn EXIT_FAILURE;')
bridge = change(bridge, '\tstruct worker worker;\n\tif (start_worker(&worker, argv[1]))\n\t\treturn EXIT_FAILURE;\n\tunlink(argv[2]);\n\tint profile = getenv("PB626_EPD_PROFILE") != NULL;\n\tconst char *halo', '\tconst char *halo')
bridge = change(bridge, '\t\t\tif (submit(&worker, command)) {', '''			uint8_t wire = command;
			if (precleared && !has_frame && command == RESET && !controls.clean_requested)
				wire = CLEAN;
			precleared = 0; /* One shot only; manual and recovery RESET stay intact. */
			if (profile && !has_frame)
				fprintf(stderr, "preclear-v2: first wire=%c mono_us=%llu\\n", wire, (unsigned long long)now_us());
			if (submit(&worker, wire)) {''')
# Diagnose actual submitted pixels, not the much larger XDamage regions.
# Emit after the worker ACK so the current update's timing is unaffected.
bridge = change(bridge, '\nint main(int argc, char **argv)\n', r'''
static void trace_startup_pixels(uint8_t command, const struct shared_frame *frame)
{
    int left = WIDTH, top = HEIGHT, right = 0, bottom = 0;
    unsigned int count = 0, tiles = 0;
    for (int ty = 0; ty < TILE_ROWS; ty++)
        for (int tx = 0; tx < TILE_COLS; tx++) {
            if (!frame->tiles[ty][tx])
                continue;
            int end_x, end_y;
            tile_bounds(tx, ty, &end_x, &end_y);
            unsigned int local = 0;
            for (int y = ty * TILE; y < end_y; y++)
                for (int x = tx * TILE; x < end_x; x++) {
                    if (frame->pixels[y * WIDTH + x] == KEEP)
                        continue;
                    local++;
                    if (x < left) left = x;
                    if (y < top) top = y;
                    if (x + 1 > right) right = x + 1;
                    if (y + 1 > bottom) bottom = y + 1;
                }
            if (local) {
                count += local;
                tiles++;
                fprintf(stderr, "startup-tile: mode=%c tx=%d ty=%d pixels=%u\n",
                        command, tx, ty, local);
            }
        }
    fprintf(stderr, "startup-bbox: mode=%c pixels=%u tiles=%u left=%d top=%d right=%d bottom=%d\n",
            command, count, tiles, left, top, right, bottom);
}

int main(int argc, char **argv)
''')
bridge = change(bridge, '\tuint64_t damage_seen = 0;', '\tuint64_t damage_seen = 0, startup_ready = 0;')
bridge = change(bridge, '\t\t\tacknowledge(command, worker.frame, frame, previous);', '''			if (profile && has_frame && startup_ready && command != RESET &&
			    ack - startup_ready <= 2000000)
				trace_startup_pixels(command, worker.frame);
			acknowledge(command, worker.frame, frame, previous);''')
bridge = change(bridge, '\t\t\tif (!has_frame) {\n\t\t\t\tFILE *ready', '\t\t\tif (!has_frame) {\n\t\t\t\tstartup_ready = now_us();\n\t\t\t\tFILE *ready')
orig = read('pb626-xsession')
script = change(orig, 'pb626-x11-epd "$1" "$2" &\nscreen=$!\n', '')
script = change(script, 'matchbox-window-manager -theme PB626 -use_titlebar yes &', '''# One paired worker owns the panel for the entire X session.
# Its initial INIT runs while Matchbox clients are starting.
/usr/bin/pb626-x11-epd-preclear-v2 "$1" "$2" &
screen=$!
matchbox-window-manager -theme PB626 -use_titlebar yes &''')
for name, content in [('pb626-epd.h',header),('pb626-epd.c',worker),('pb626-x11-epd.c',bridge),('xsession.original',orig),('xsession.experimental',script)]:
    (out/name).write_text(content)
for name in ['test-pb626-epd.c','test-pb626-x11-epd.c']:
    (out/name).write_text(read(name))
# Keep the exact tested v1 session for rollback, generated by the v1 recipe.
v1=out/'v1'
subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve().parent.parent/'eink-preclear'/'prepare.py'), str(v1)],check=True)
(out/'xsession.v1').write_bytes((v1/'xsession.experimental').read_bytes())
