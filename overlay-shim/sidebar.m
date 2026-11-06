// Bridgeplay quick settings: an in-game sidebar for the performance overlay, the frame rate
// limit and the scaling filter, with the battery and power the Mac reports. Included by
// overlay_shim.m after scalefilter.m.
//
// Option-Command-P shows it on the right edge of the game's window; Option-Command-P or
// Escape hides it, and so does a click outside it. Up and Down pick a setting, Left and
// Right (or Return) change it, and a click on a choice picks it. While it shows, the game gets
// no key presses or clicks; releases still pass, so nothing it saw pressed stays held. The
// game keeps drawing behind it.
//
// A change takes effect on the game's next frame and is written to
// <support>/quick-settings/<appid>.conf. Steam's page collects it through the
// NotProton.TakeQuickSettings route (dylib/feats/quicksettings.c) and saves it to the game's
// launch options with the Bridgeplay panel's own logic, so the next launch and Steam
// Properties › Bridgeplay show the same value.
//
// It is a layer above the game's CAMetalLayer, as the performance overlay is: no window of
// its own and no change of focus. BRIDGEPLAY_QUICK_SETTINGS=0 turns it off.

#import <pwd.h>
#import <sys/stat.h>

enum { sb_overlay, sb_limit, sb_filter, sb_rows };

static const char *const sb_keys[sb_rows] = { "BRIDGEPLAY_PERF_OVERLAY", "BRIDGEPLAY_FPS_LIMIT",
	                                      "BRIDGEPLAY_SCALING_FILTER" };
static const char *const sb_titles[sb_rows] = { "Performance overlay", "Frame rate limit", "Scaling filter" };
static const char *const sb_values[sb_rows][6] = {
	{ "0", "fps", "summary", "detailed" },
	{ "0", "display", "half", "60", "40", "30" },
	{ "0", "linear", "nearest", "integer" },
};
static const char *const sb_labels[sb_rows][6] = {
	{ "Off", "FPS", "Summary", "Detailed" },
	{ "Off", "Display", "Half", "60", "40", "30" },
	{ "Auto", "Linear", "Nearest", "Integer" },
};
static const int sb_counts[sb_rows] = { 4, 6, 4 };

#define sb_key_p 35
#define sb_key_return 36
#define sb_key_tab 48
#define sb_key_space 49
#define sb_key_escape 53
#define sb_key_left 123
#define sb_key_right 124
#define sb_key_down 125
#define sb_key_up 126

#define sb_mod_shift (1UL << 17)
#define sb_mod_control (1UL << 18)
#define sb_mod_option (1UL << 19)
#define sb_mod_command (1UL << 20)

static int sb_enabled;
static char sb_appid[16];

// The layer the game draws to, from its render thread
static os_unfair_lock sb_lock = OS_UNFAIR_LOCK_INIT;
static id sb_seen; // retained
static double sb_seen_at;

// Main thread only
static int sb_open;
static int sb_row;
static CAMetalLayer *sb_host; // retained while open
static CALayer *sb_panel, *sb_scrim, *sb_hint;
static dispatch_source_t sb_timer;
static char sb_status[120];
static double sb_width;

static int sb_drag_row = -1; // a slider being dragged, main thread

static int sidebar_wanted(void)
{
	const char *off = getenv("NOTPROTON_QUICK_SETTINGS");
	if (off == NULL)
		off = getenv("BRIDGEPLAY_QUICK_SETTINGS");
	return off == NULL || strcmp(off, "0") != 0;
}

static int sb_digits(const char *v)
{
	size_t n = v != NULL ? strlen(v) : 0;
	if (n == 0 || n > 10 || v[0] == '0')
		return 0;
	for (size_t i = 0; i < n; i++)
		if (v[i] < '0' || v[i] > '9')
			return 0;
	return 1;
}

static int sidebar_init(void)
{
	sb_enabled = sidebar_wanted();
	const char *names[] = { "SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]) && !sb_appid[0]; i++)
		if (sb_digits(getenv(names[i])))
			snprintf(sb_appid, sizeof(sb_appid), "%s", getenv(names[i]));
	return sb_enabled;
}

static void sb_support(char *out, size_t cap)
{
	const char *home = getenv("HOME");
	if (home == NULL || home[0] == '\0') {
		struct passwd *pw = getpwuid(getuid());
		home = pw != NULL ? pw->pw_dir : NULL;
	}
	out[0] = '\0';
	if (home == NULL)
		return;
	char current[1024], legacy[1024];
	struct stat st;
	snprintf(current, sizeof(current), "%s/Library/Application Support/bridgeplay", home);
	snprintf(legacy, sizeof(legacy), "%s/Library/Application Support/notproton", home);
	snprintf(out, cap, "%s", stat(current, &st) != 0 && stat(legacy, &st) == 0 ? legacy : current);
}

static void sb_maybe_hint(void);

// Render thread: remember the layer the game draws to. Another layer takes over only once
// this one has gone quiet (a launcher window closing, the game replacing a splash).
static void sidebar_note_layer(id layer)
{
	if (!sb_enabled || fg_internal || layer == nil)
		return;
	double now = CACurrentMediaTime();
	id dropped = nil;
	int first = 0;
	os_unfair_lock_lock(&sb_lock);
	if (layer == sb_seen) {
		sb_seen_at = now;
	} else if (sb_seen == nil || now - sb_seen_at > 1.0) {
		first = sb_seen == nil;
		dropped = sb_seen;
		sb_seen = [layer retain];
		sb_seen_at = now;
	}
	os_unfair_lock_unlock(&sb_lock);
	if (dropped != nil)
		dispatch_async(dispatch_get_main_queue(), ^{
			[dropped release];
		});
	if (first)
		dispatch_async(dispatch_get_main_queue(), ^{
			sb_maybe_hint();
		});
}

static CAMetalLayer *sb_current_layer(void)
{
	os_unfair_lock_lock(&sb_lock);
	id layer = [sb_seen retain];
	os_unfair_lock_unlock(&sb_lock);
	return [layer autorelease];
}

// MARK: Settings

// Where each setting stands now, as an index into its choices; -1 when it has none (a
// number set by hand in Steam) or cannot change (the Metal HUD owns the overlay).
static int sb_index(int row)
{
	switch (row) {
	case sb_overlay:
		return ph_hud_locked ? -1 : atomic_load(&ph_level);
	case sb_limit: {
		int mode = atomic_load(&fl_mode), fps = atomic_load(&fl_fixed_fps);
		if (mode == fl_off)
			return 0;
		if (mode == fl_display)
			return 1;
		if (mode == fl_half)
			return 2;
		return fps == 60 ? 3 : fps == 40 ? 4 : fps == 30 ? 5 : -1;
	}
	default:
		return atomic_load(&sf_mode);
	}
}

// The change waits there until Steam's page takes it; a newer pick of the same setting
// replaces it, and the other settings still waiting stay.
static int sb_save(const char *key, const char *value)
{
	if (!sb_appid[0]) {
		snprintf(sb_status, sizeof(sb_status), "Applied for this session. No Steam app to save it to.");
		return 0;
	}
	char support[1024], dir[1100], path[1200], tmp[1300];
	sb_support(support, sizeof(support));
	snprintf(dir, sizeof(dir), "%s/quick-settings", support);
	if (!support[0] || (mkdir(dir, 0700) != 0 && errno != EEXIST)) {
		snprintf(sb_status, sizeof(sb_status), "Applied for this session. Could not save it.");
		return 0;
	}
	snprintf(path, sizeof(path), "%s/%s.conf", dir, sb_appid);
	snprintf(tmp, sizeof(tmp), "%s.%d.tmp", path, getpid());

	char kept[sb_rows][16] = { { 0 } };
	FILE *in = fopen(path, "r");
	if (in != NULL) {
		char line[128];
		while (fgets(line, sizeof(line), in) != NULL) {
			line[strcspn(line, "\r\n")] = '\0';
			for (int i = 0; i < sb_rows; i++) {
				size_t n = strlen(sb_keys[i]);
				if (strncmp(line, sb_keys[i], n) == 0 && line[n] == '=')
					snprintf(kept[i], sizeof(kept[i]), "%s", line + n + 1);
			}
		}
		fclose(in);
	}
	for (int i = 0; i < sb_rows; i++)
		if (strcmp(key, sb_keys[i]) == 0)
			snprintf(kept[i], sizeof(kept[i]), "%s", value);

	FILE *out = fopen(tmp, "w");
	int ok = out != NULL;
	for (int i = 0; ok && i < sb_rows; i++)
		if (kept[i][0])
			ok = fprintf(out, "%s=%s\n", sb_keys[i], kept[i]) > 0;
	if (out != NULL && fclose(out) != 0)
		ok = 0;
	if (!ok || rename(tmp, path) != 0) {
		unlink(tmp);
		snprintf(sb_status, sizeof(sb_status), "Applied for this session. Could not save it.");
		return 0;
	}
	snprintf(sb_status, sizeof(sb_status), "Applied. Saved for this game's next launch.");
	return 1;
}

// Applies one setting now and saves it. Main thread.
static int sb_apply(const char *key, const char *value)
{
	CAMetalLayer *host = sb_host != nil ? sb_host : sb_current_layer();
	int ok = 0;
	if (strcmp(key, sb_keys[sb_overlay]) == 0) {
		for (int i = 0; i < sb_counts[sb_overlay]; i++)
			if (strcmp(value, sb_values[sb_overlay][i]) == 0)
				ok = perfhud_set_level(i);
	} else if (strcmp(key, sb_keys[sb_limit]) == 0) {
		ok = framelimit_set(value, host);
	} else if (strcmp(key, sb_keys[sb_filter]) == 0) {
		ok = scalefilter_set(value, host);
	}
	if (!ok)
		return 0;
	int saved = sb_save(key, value);
	shim_log("overlay_shim sidebar: %s=%s applied, %s\n", key, value, saved ? "saved" : sb_status);
	return 1;
}

static CGColorRef sb_gray(double alpha);

// MARK: Drawing
//
// Two control kinds, chosen by what the choices are. The overlay level and the frame rate
// limit are ordered steps, so each is a stepped slider whose position means something: more
// detail to the right, a higher rate to the right with Off (no limit) at the end. The scaling
// filters are not an order, so they stay a selector that shows every name. Text is placed by
// centring its capitals on the line it belongs to (ph_centred), so labels and values of
// different sizes share one optical centre.

// Layout, in points from the panel's top-left
#define sb_pad 22.0
#define sb_head_mid 38.0     // title line
#define sb_power_mid 84.0    // battery line
#define sb_power_bar 104.0   // battery gauge
#define sb_rows_top 132.0
#define sb_row_h 92.0
#define sb_title_mid 12.0    // a row's title line, from the row's top
#define sb_track_mid 42.0    // slider track centre
#define sb_stops_mid 64.0    // slider stop labels
#define sb_hit_above 18.0    // a press this far above the track to below its labels picks a stop
#define sb_hit_below 32.0
#define sb_seg_top 28.0      // selector
#define sb_seg_h 32.0
#define sb_note_mid 74.0     // the selector's measured note
#define sb_thumb_r 8.0
#define sb_inset 9.0         // stops start this far in, so the end thumbs stay inside

struct sb_fonts {
	CTFontRef title, big, row, value, stop, stop_on, seg, seg_on, small;
};
static struct sb_fonts sb_f;

static void sb_fonts_load(void)
{
	ph_style_load();
	if (sb_f.title != NULL)
		return;
	sb_f.title = ph_font(17, 600);
	sb_f.big = ph_font(22, 600);
	sb_f.row = ph_font(13, 600);
	sb_f.value = ph_font(13, 500);
	sb_f.stop = ph_font(11, 500);
	sb_f.stop_on = ph_font(11, 650);
	sb_f.seg = ph_font(12, 500);
	sb_f.seg_on = ph_font(12, 650);
	sb_f.small = ph_font(11, 400);
}

// A rectangle given from the top of a box h tall
static CGRect sb_rect(double h, double x, double y, double w, double rh)
{
	return CGRectMake(x, h - y - rh, w, rh);
}

static void sb_fill_round(CGContextRef ctx, CGRect r, double radius, double red, double green, double blue,
                          double alpha)
{
	CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
	CGContextAddPath(ctx, path);
	CGContextSetRGBFillColor(ctx, red, green, blue, alpha);
	CGContextFillPath(ctx);
	CGPathRelease(path);
}

static void sb_stroke_round(CGContextRef ctx, CGRect r, double radius, double alpha)
{
	CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
	CGContextAddPath(ctx, path);
	CGContextSetRGBStrokeColor(ctx, 1, 1, 1, alpha);
	CGContextSetLineWidth(ctx, 1);
	CGContextStrokePath(ctx);
	CGPathRelease(path);
}

static void sb_hairline(CGContextRef ctx, double h, double x, double y, double w)
{
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, sb_rect(h, x, y, w, 1));
}

static double sb_text_right(CGContextRef ctx, double h, double right, double mid, const char *text, CTFontRef font,
                            CGColorRef color)
{
	double tw = ph_width(text, font, 0);
	ph_text(ctx, h, right - tw, ph_centred(mid, font), text, font, color, 0);
	return tw;
}

// The frame rate a limit choice gives on this display, for ordering; Off sorts last.
static double sb_rate(const char *v, int hz)
{
	if (strcmp(v, "0") == 0)
		return 1e9;
	if (strcmp(v, "display") == 0)
		return hz > 0 ? hz : 1e6 - 1;
	if (strcmp(v, "half") == 0)
		return hz > 0 ? hz / 2.0 : 1e6 - 2;
	return atof(v);
}

// Each choice's place along its control, left to right. The limit's places follow the rate
// each choice gives on this display (Display and Half take what they work out to, a fixed
// number first on a tie), so the slider stays in order on any display.
static int sb_order(int row, int order[6])
{
	int n = sb_counts[row];
	for (int i = 0; i < n; i++)
		order[i] = i;
	if (row != sb_limit)
		return n;
	int hz = atomic_load(&ph_refresh_hz);
	for (int i = 1; i < n; i++)
		for (int j = i; j > 0; j--) {
			const char *a = sb_values[row][order[j - 1]], *b = sb_values[row][order[j]];
			double ra = sb_rate(a, hz), rb = sb_rate(b, hz);
			int b_fixed = b[0] >= '1' && b[0] <= '9', a_fixed = a[0] >= '1' && a[0] <= '9';
			if (rb < ra || (rb == ra && b_fixed && !a_fixed)) {
				int t = order[j - 1];
				order[j - 1] = order[j];
				order[j] = t;
			} else {
				break;
			}
		}
	return n;
}

// Where the current choice sits along the control; -1 when it has none
static int sb_position(int row, const int *order, int n)
{
	int sel = sb_index(row);
	for (int k = 0; k < n; k++)
		if (order[k] == sel)
			return k;
	return -1;
}

static double sb_stop_x(double w, int k, int n)
{
	double x0 = sb_pad + sb_inset, x1 = w - sb_pad - sb_inset;
	return n > 1 ? x0 + (x1 - x0) * k / (n - 1) : x0;
}

// The readout beside a row's title: the choice in words
static void sb_readout(int row, char *out, size_t cap)
{
	int sel = sb_index(row), hz = atomic_load(&ph_refresh_hz);
	if (row == sb_overlay) {
		snprintf(out, cap, "%s", ph_hud_locked ? "Metal HUD, set in Steam" : sb_labels[row][sel < 0 ? 0 : sel]);
	} else if (row == sb_limit) {
		const char *v = sel < 0 ? NULL : sb_values[row][sel];
		if (v == NULL)
			snprintf(out, cap, "%d FPS, set in Steam", atomic_load(&fl_fixed_fps));
		else if (strcmp(v, "0") == 0)
			snprintf(out, cap, "Off");
		else if (strcmp(v, "display") == 0)
			snprintf(out, cap, hz > 0 ? "Display rate · %d FPS" : "Display rate", hz);
		else if (strcmp(v, "half") == 0)
			snprintf(out, cap, hz > 0 ? "Half rate · %d FPS" : "Half rate", hz / 2);
		else
			snprintf(out, cap, "%s FPS", v);
	} else {
		static const char *const names[] = { "Automatic", "Linear", "Nearest", "Integer" };
		snprintf(out, cap, "%s", names[sel < 0 ? 0 : sel]);
	}
}

static void sb_draw_slider(CGContextRef ctx, double w, double h, double top, int row, int focused, int disabled)
{
	int order[6], n = sb_order(row, order), pos = sb_position(row, order, n);
	double cy = top + sb_track_mid, x0 = sb_stop_x(w, 0, n), x1 = sb_stop_x(w, n - 1, n);

	// The track, and from its start to the choice the brand gradient: the one place it shows
	sb_fill_round(ctx, sb_rect(h, x0 - 2, cy - 2, x1 - x0 + 4, 4), 2, PH_RGB(0x2C2C30, 1));
	if (pos > 0 && !disabled) {
		double xp = sb_stop_x(w, pos, n);
		CGContextSaveGState(ctx);
		CGPathRef fill = CGPathCreateWithRoundedRect(sb_rect(h, x0 - 2, cy - 2, xp - x0 + 4, 4), 2, 2, NULL);
		CGContextAddPath(ctx, fill);
		CGContextClip(ctx);
		ph_gradient(ctx, CGPointMake(x0, 0), CGPointMake(x1, 0));
		CGContextRestoreGState(ctx);
		CGPathRelease(fill);
	}
	// Stops: a notch at each step, so the steps read before the labels do
	for (int k = 0; k < n; k++) {
		if (k == pos)
			continue;
		double sx = sb_stop_x(w, k, n);
		double a = k < pos && !disabled ? 0.85 : 1;
		if (k < pos && !disabled)
			CGContextSetRGBFillColor(ctx, 1, 1, 1, a);
		else
			CGContextSetRGBFillColor(ctx, PH_RGB(0x5A5A60, a));
		CGContextFillEllipseInRect(ctx, sb_rect(h, sx - 2, cy - 2, 4, 4));
	}
	// The thumb, with a soft offset shadow so it sits on the track
	if (pos >= 0) {
		double tx = sb_stop_x(w, pos, n);
		if (focused && !disabled)
			sb_stroke_round(ctx, sb_rect(h, tx - sb_thumb_r - 3.5, cy - sb_thumb_r - 3.5, 2 * sb_thumb_r + 7,
			                             2 * sb_thumb_r + 7), sb_thumb_r + 3.5, 0.32);
		CGContextSaveGState(ctx);
		CGColorRef shadow = sb_gray(0.55);
		CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 3, shadow);
		CGColorRelease(shadow);
		if (disabled)
			CGContextSetRGBFillColor(ctx, PH_RGB(0x6E6E73, 1));
		else
			CGContextSetRGBFillColor(ctx, PH_RGB(0xF5F5F7, 1));
		CGContextFillEllipseInRect(ctx, sb_rect(h, tx - sb_thumb_r, cy - sb_thumb_r, 2 * sb_thumb_r, 2 * sb_thumb_r));
		CGContextRestoreGState(ctx);
	}
	// Every stop named under it; the ends line up with the track's ends
	double mid = top + sb_stops_mid;
	for (int k = 0; k < n; k++) {
		const char *label = sb_labels[row][order[k]];
		CTFontRef font = k == pos ? sb_f.stop_on : sb_f.stop;
		double tw = ph_width(label, font, 0), sx = sb_stop_x(w, k, n);
		double lx = k == 0 ? sb_pad : k == n - 1 ? w - sb_pad - tw : sx - tw / 2;
		CGColorRef color = disabled ? ph_style.fg3 : k == pos ? ph_style.fg : ph_style.fg3;
		ph_text(ctx, h, lx, ph_centred(mid, font), label, font, color, 0);
	}
}

static double sb_seg_width(double w, int row)
{
	return (w - 2 * sb_pad - 6) / sb_counts[row];
}

static void sb_draw_selector(CGContextRef ctx, double w, double h, double top, int row, int focused)
{
	int sel = sb_index(row);
	CGRect box = sb_rect(h, sb_pad, top + sb_seg_top, w - 2 * sb_pad, sb_seg_h);
	sb_fill_round(ctx, box, 8, PH_RGB(0x18181B, 1));
	if (focused)
		sb_stroke_round(ctx, CGRectInset(box, 0.5, 0.5), 7.5, 0.22);
	double segw = sb_seg_width(w, row), mid = top + sb_seg_top + sb_seg_h / 2;
	for (int i = 0; i < sb_counts[row]; i++) {
		double x = sb_pad + 3 + i * segw;
		int on = i == sel;
		if (on)
			sb_fill_round(ctx, sb_rect(h, x, top + sb_seg_top + 3, segw, sb_seg_h - 6), 6, PH_RGB(0x34343A, 1));
		CTFontRef font = on ? sb_f.seg_on : sb_f.seg;
		const char *label = sb_labels[row][i];
		double tw = ph_width(label, font, 0);
		ph_text(ctx, h, x + (segw - tw) / 2, ph_centred(mid, font), label, font, on ? ph_style.fg : ph_style.fg2, 0);
	}
	// What the filter has to work with, measured from the game's layer
	char note[96] = "";
	if (sb_host != nil) {
		CGSize d = sb_host.drawableSize;
		double scale = atomic_load(&ph_scale), sx = d.width > 0 ? sb_host.bounds.size.width * scale / d.width : 0;
		if (sx > 1.01)
			snprintf(note, sizeof(note), "Game draws %.0f × %.0f, shown %.1f× larger", d.width, d.height, sx);
		else
			snprintf(note, sizeof(note), "Game draws at full resolution: nothing to scale");
	}
	ph_text(ctx, h, sb_pad, ph_centred(top + sb_note_mid, sb_f.small), note, sb_f.small, ph_style.fg3, 0);
}

static void sb_draw_row(CGContextRef ctx, double w, double h, int row)
{
	double top = sb_rows_top + row * sb_row_h;
	int focused = row == sb_row, disabled = row == sb_overlay && ph_hud_locked;
	char readout[48];
	sb_readout(row, readout, sizeof(readout));
	double mid = top + sb_title_mid;
	ph_text(ctx, h, sb_pad, ph_centred(mid, sb_f.row), sb_titles[row], sb_f.row, focused ? ph_style.fg : ph_style.fg2,
	        -0.1);
	sb_text_right(ctx, h, w - sb_pad, mid, readout, sb_f.value, disabled ? ph_style.fg3 : ph_style.fg);
	if (row == sb_filter)
		sb_draw_selector(ctx, w, h, top, row, focused);
	else
		sb_draw_slider(ctx, w, h, top, row, focused, disabled);
}

static void sb_draw(CGContextRef ctx, double w, double h)
{
	CGContextSetRGBFillColor(ctx, PH_RGB(0x0B0B0D, 0.97));
	CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, CGRectMake(0, 0, 1, h));

	// Title and the shortcut that closes it again
	ph_text(ctx, h, sb_pad, ph_centred(sb_head_mid, sb_f.title), "Quick settings", sb_f.title, ph_style.fg, -0.3);
	const char *keys = "⌥⌘P";
	double kw = ph_width(keys, sb_f.small, 0.4);
	CGRect key = sb_rect(h, w - sb_pad - kw - 14, sb_head_mid - 11, kw + 14, 22);
	sb_stroke_round(ctx, CGRectInset(key, 0.5, 0.5), 5.5, 0.14);
	ph_text(ctx, h, w - sb_pad - kw - 7, ph_centred(sb_head_mid, sb_f.small), keys, sb_f.small, ph_style.fg2, 0.4);

	// Battery and power, where the Mac reports them
	int battery, on_ac, charging, minutes;
	ph_read_battery(&battery, &on_ac, &charging, &minutes);
	double watts = ph_power();
	char text[64], state[48] = "";
	if (battery >= 0) {
		snprintf(text, sizeof(text), "%d%%", battery);
		ph_text(ctx, h, sb_pad, ph_centred(sb_power_mid, sb_f.big), text, sb_f.big, ph_style.fg, -0.4);
		if (on_ac == 1)
			snprintf(state, sizeof(state), "%s", charging == 1 ? "Charging" : "On power");
		else if (minutes > 0)
			snprintf(state, sizeof(state), "%d:%02d left", minutes / 60, minutes % 60);
		else
			snprintf(state, sizeof(state), "On battery");
		if (watts > 0)
			snprintf(text, sizeof(text), "%s · %.1f W", state, watts);
		else
			snprintf(text, sizeof(text), "%s", state);
		sb_text_right(ctx, h, w - sb_pad, sb_power_mid, text, sb_f.value, ph_style.fg2);
		// A plain gauge; amber only when the battery is low and draining
		CGRect track = sb_rect(h, sb_pad, sb_power_bar, w - 2 * sb_pad, 3);
		sb_fill_round(ctx, track, 1.5, PH_RGB(0x222226, 1));
		int low = battery <= 20 && on_ac != 1;
		CGRect fill = sb_rect(h, sb_pad, sb_power_bar, (w - 2 * sb_pad) * battery / 100.0, 3);
		if (low)
			sb_fill_round(ctx, fill, 1.5, PH_RGB(0xFF9F0A, 1));
		else
			sb_fill_round(ctx, fill, 1.5, PH_RGB(0xA1A1A6, 1));
	} else if (watts > 0) {
		snprintf(text, sizeof(text), "%.1f W", watts);
		ph_text(ctx, h, sb_pad, ph_centred(sb_power_mid, sb_f.big), text, sb_f.big, ph_style.fg, -0.4);
		sb_text_right(ctx, h, w - sb_pad, sb_power_mid, "Drawn by this Mac", sb_f.value, ph_style.fg2);
	} else {
		ph_text(ctx, h, sb_pad, ph_centred(sb_power_mid, sb_f.small), "No battery or power reading on this Mac",
		        sb_f.small, ph_style.fg3, 0);
	}
	sb_hairline(ctx, h, sb_pad, sb_rows_top - 14, w - 2 * sb_pad);

	for (int row = 0; row < sb_rows; row++)
		sb_draw_row(ctx, w, h, row);

	// At the bottom, or right under the settings in a short window
	double foot = sb_rows_top + sb_rows * sb_row_h + 4;
	if (foot < h - 72)
		foot = h - 72;
	sb_hairline(ctx, h, sb_pad, foot, w - 2 * sb_pad);
	ph_text(ctx, h, sb_pad, ph_centred(foot + 22, sb_f.small),
	        sb_status[0] ? sb_status : "Changes apply now and are saved for this game.", sb_f.small,
	        sb_status[0] ? ph_style.fg : ph_style.fg2, 0);
	ph_text(ctx, h, sb_pad, ph_centred(foot + 44, sb_f.small), "↑↓ setting    ←→ change    esc close",
	        sb_f.small, ph_style.fg3, 0.2);
}

static CGImageRef sb_render(double w, double h, double scale)
{
	sb_fonts_load();
	size_t pw = (size_t)ceil(w * scale), phh = (size_t)ceil(h * scale);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(NULL, pw, phh, 8, 0, srgb,
	                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(srgb);
	if (ctx == NULL)
		return NULL;
	CGContextScaleCTM(ctx, scale, scale);
	CGContextSetShouldSmoothFonts(ctx, false);
	sb_draw(ctx, w, h);
	CGImageRef image = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	return image;
}

static CGColorRef sb_gray(double alpha)
{
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGFloat c[] = { 0, 0, 0, alpha };
	CGColorRef color = CGColorCreate(srgb, c);
	CGColorSpaceRelease(srgb);
	return color;
}

// Lays the scrim and the panel over the host and draws the panel. Main thread.
static void sb_redraw(void)
{
	if (!sb_open || sb_host == nil)
		return;
	CGRect b = sb_host.bounds;
	double w = b.size.width < 380 ? b.size.width : 320;
	double scale = atomic_load(&ph_scale);
	CGImageRef image = sb_render(w, b.size.height, scale);
	fg_ca_begin();
	if (sb_scrim == nil) {
		sb_scrim = [[CALayer alloc] init];
		// Under the performance overlay (2000), so it stays readable while settings change
		sb_scrim.zPosition = 1500;
		CGColorRef dim = sb_gray(0.32);
		sb_scrim.backgroundColor = dim;
		CGColorRelease(dim);
	}
	if (sb_panel == nil) {
		sb_panel = [[CALayer alloc] init];
		sb_panel.anchorPoint = CGPointZero;
		sb_panel.zPosition = 3000;
		sb_panel.contentsGravity = kCAGravityResize;
	}
	if (sb_scrim.superlayer != sb_host) {
		[sb_scrim removeFromSuperlayer];
		[sb_host addSublayer:sb_scrim];
	}
	if (sb_panel.superlayer != sb_host) {
		[sb_panel removeFromSuperlayer];
		[sb_host addSublayer:sb_panel];
	}
	sb_scrim.frame = b;
	sb_panel.bounds = CGRectMake(0, 0, w, b.size.height);
	sb_panel.position = CGPointMake(b.origin.x + b.size.width - w, b.origin.y);
	sb_panel.contentsScale = scale;
	sb_panel.contents = (id)image;
	sb_scrim.hidden = NO;
	sb_panel.hidden = NO;
	fg_ca_end();
	if (image != NULL)
		CGImageRelease(image);
	sb_width = w;
}

// MARK: Showing and input

static id sb_msg(id target, const char *selector)
{
	SEL sel = sel_registerName(selector);
	return target != nil && [target respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

static id sb_view(CALayer *layer)
{
	Class view_class = objc_getClass("NSView");
	for (CALayer *l = layer; l != nil && view_class != Nil; l = l.superlayer)
		if (l.delegate != nil && [l.delegate isKindOfClass:view_class])
			return l.delegate;
	return nil;
}

static void sb_mark_seen(void)
{
	char support[1024], marker[1100];
	sb_support(support, sizeof(support));
	if (!support[0])
		return;
	snprintf(marker, sizeof(marker), "%s/.quick-settings-seen", support);
	int fd = open(marker, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd >= 0)
		close(fd);
}

static void sb_close(void)
{
	if (!sb_open)
		return;
	sb_open = 0;
	sb_drag_row = -1;
	fg_ca_begin();
	sb_panel.hidden = YES;
	sb_scrim.hidden = YES;
	fg_ca_end();
	if (sb_timer != NULL) {
		dispatch_source_cancel(sb_timer);
		dispatch_release(sb_timer);
		sb_timer = NULL;
	}
	[sb_host release];
	sb_host = nil;
	shim_log("overlay_shim sidebar: closed\n");
}

static void sb_show(void)
{
	CAMetalLayer *host = sb_current_layer();
	if (host == nil)
		return;
	sb_host = [host retain];
	sb_open = 1;
	sb_status[0] = '\0';
	ph_read_screen(sb_host);
	if (sb_hint != nil) {
		fg_ca_begin();
		sb_hint.hidden = YES;
		fg_ca_end();
	}
	sb_mark_seen();
	sb_redraw();
	// The battery and power figures move while it is open
	sb_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	dispatch_source_set_timer(sb_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC,
	                          200 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(sb_timer, ^{
		@autoreleasepool {
			sb_redraw();
		}
	});
	dispatch_resume(sb_timer);
	id view = sb_view(sb_host);
	CALayer *view_layer = (CALayer *)sb_msg(view, "layer");
	shim_log("overlay_shim sidebar: open, layer %.0fx%.0f, view %.0fx%.0f flipped=%d, app %s\n",
	         sb_host.bounds.size.width, sb_host.bounds.size.height, view_layer.bounds.size.width,
	         view_layer.bounds.size.height,
	         view != nil ? (int)((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isFlipped")) : -1,
	         sb_appid[0] ? sb_appid : "unknown");
}

// Left and Right move along the control as drawn; Return and Space go to the next stop and
// wrap.
static void sb_step(int row, int delta)
{
	if (row == sb_overlay && ph_hud_locked)
		return;
	int order[6], n = sb_order(row, order), at = sb_position(row, order, n);
	int next = at < 0 ? (delta > 0 ? 0 : n - 1) : at + delta;
	if (delta == 0)
		next = at < 0 ? 0 : (at + 1) % n;
	if (next < 0 || next >= n || next == at)
		return;
	sb_apply(sb_keys[row], sb_values[row][order[next]]);
}

// The slider stop nearest x, applied when it is not already the choice
static void sb_pick_stop(int row, double x)
{
	if (row == sb_overlay && ph_hud_locked)
		return;
	int order[6], n = sb_order(row, order), best = 0;
	for (int k = 1; k < n; k++)
		if (fabs(x - sb_stop_x(sb_width, k, n)) < fabs(x - sb_stop_x(sb_width, best, n)))
			best = k;
	if (best != sb_position(row, order, n))
		sb_apply(sb_keys[row], sb_values[row][order[best]]);
}

// A click's place in the panel, from its top-left; 0 when it is not in the game's window.
static int sb_point(id event, double *x, double *y)
{
	id view = sb_view(sb_host);
	id window = sb_msg(view, "window");
	if (window == nil || sb_msg(event, "window") != window)
		return 0;
	CGPoint loc = ((CGPoint (*)(id, SEL))objc_msgSend)(event, sel_registerName("locationInWindow"));
	CGPoint p = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(view, sel_registerName("convertPoint:fromView:"),
	                                                              loc, nil);
	CALayer *view_layer = (CALayer *)sb_msg(view, "layer");
	CGSize size = view_layer != nil ? view_layer.bounds.size : sb_host.bounds.size;
	BOOL flipped = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isFlipped"));
	*x = p.x - (size.width - sb_width);
	*y = flipped ? p.y : size.height - p.y;
	return 1;
}

static void sb_click(id event)
{
	double x, y;
	if (!sb_point(event, &x, &y))
		return;
	if (x < 0) {
		sb_close();
		return;
	}
	int row = (int)floor((y - sb_rows_top) / sb_row_h);
	if (row < 0 || row >= sb_rows || y < sb_rows_top)
		return;
	sb_row = row;
	double top = sb_rows_top + row * sb_row_h;
	if (row == sb_filter) {
		double seg_top = top + sb_seg_top;
		if (y >= seg_top && y <= seg_top + sb_seg_h && x >= sb_pad + 3) {
			int i = (int)floor((x - sb_pad - 3) / sb_seg_width(sb_width, row));
			if (i >= 0 && i < sb_counts[row] && i != sb_index(row))
				sb_apply(sb_keys[row], sb_values[row][i]);
		}
	} else if (y >= top + sb_track_mid - sb_hit_above && y <= top + sb_track_mid + sb_hit_below) {
		// A press on the track or its labels picks the nearest stop and starts a drag
		sb_pick_stop(row, x);
		sb_drag_row = row;
	}
	sb_redraw();
}

// NSApplication sendEvent:, before the game sees the event; returns 1 when it is taken.
static int sidebar_send_event(id event)
{
	if (!sb_enabled)
		return 0;
	NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
	int key_down = type == 10;
	unsigned short code = 0;
	int shortcut = 0;
	if (key_down) {
		code = ((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode"));
		NSUInteger flags = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags"));
		BOOL repeat = ((BOOL (*)(id, SEL))objc_msgSend)(event, sel_registerName("isARepeat"));
		shortcut = code == sb_key_p && (flags & sb_mod_command) && (flags & sb_mod_option) &&
		           !(flags & (sb_mod_control | sb_mod_shift)) && !repeat;
	}
	if (!sb_open) {
		if (!shortcut)
			return 0;
		sb_show();
		return 1;
	}
	switch (type) {
	case 10: // key down: every key is the sidebar's while it shows
		if (shortcut || code == sb_key_escape)
			sb_close();
		else if (code == sb_key_up)
			sb_row = (sb_row + sb_rows - 1) % sb_rows;
		else if (code == sb_key_down || code == sb_key_tab)
			sb_row = (sb_row + 1) % sb_rows;
		else if (code == sb_key_left)
			sb_step(sb_row, -1);
		else if (code == sb_key_right)
			sb_step(sb_row, 1);
		else if (code == sb_key_return || code == sb_key_space)
			sb_step(sb_row, 0);
		sb_redraw();
		return 1;
	case 1: // left mouse down
		sb_click(event);
		return 1;
	case 6: { // left mouse dragged: a slider follows the pointer from stop to stop
		double x, y;
		if (sb_drag_row >= 0 && sb_point(event, &x, &y)) {
			sb_pick_stop(sb_drag_row, x);
			sb_redraw();
		}
		return 1;
	}
	case 2: // left mouse up ends a drag, and still reaches the game
		sb_drag_row = -1;
		return 0;
	case 3: case 5: case 7: case 22: case 25: case 27: // other presses, moves, drags, scrolls
		return 1;
	default: // key and button releases, modifier changes: the game keeps an accurate picture
		return 0;
	}
}

// The first time a game runs with the sidebar available, a short pointer to its shortcut.
static void sb_maybe_hint(void)
{
	char support[1024], marker[1100];
	struct stat st;
	sb_support(support, sizeof(support));
	snprintf(marker, sizeof(marker), "%s/.quick-settings-seen", support);
	if (!support[0] || stat(marker, &st) == 0 || sb_hint != nil)
		return;
	CAMetalLayer *host = sb_current_layer();
	// Only on a layer in a window: an offscreen layer has nobody to tell
	if (host == nil || sb_view(host) == nil)
		return;
	ph_read_screen(host);
	sb_fonts_load();
	const char *keys = "⌥⌘P", *text = "Bridgeplay quick settings";
	double kw = ph_width(keys, sb_f.row, 0.4), tw = ph_width(text, sb_f.small, 0);
	double w = 16 + kw + 10 + tw + 16, h = 32, scale = atomic_load(&ph_scale);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)ceil(w * scale), (size_t)ceil(h * scale), 8, 0, srgb,
	                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(srgb);
	if (ctx == NULL)
		return;
	CGContextScaleCTM(ctx, scale, scale);
	sb_fill_round(ctx, CGRectMake(0.5, 0.5, w - 1, h - 1), 8, PH_RGB(0x0D0D0F, 0.9));
	sb_stroke_round(ctx, CGRectMake(0.5, 0.5, w - 1, h - 1), 8, 0.10);
	ph_text(ctx, h, 16, ph_centred(h / 2, sb_f.row), keys, sb_f.row, ph_style.fg, 0.4);
	ph_text(ctx, h, 16 + kw + 10, ph_centred(h / 2, sb_f.small), text, sb_f.small, ph_style.fg2, 0);
	CGImageRef image = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);

	int flipped = 0;
	for (CALayer *l = host; l != nil; l = l.superlayer)
		flipped ^= l.geometryFlipped ? 1 : 0;
	CGRect b = host.bounds;
	fg_ca_begin();
	sb_hint = [[CALayer alloc] init];
	sb_hint.anchorPoint = CGPointZero;
	sb_hint.zPosition = 2900;
	sb_hint.contentsScale = scale;
	sb_hint.contents = (id)image;
	sb_hint.bounds = CGRectMake(0, 0, w, h);
	sb_hint.position = CGPointMake(b.origin.x + b.size.width - w - 12,
	                               flipped ? b.origin.y + 12 : b.origin.y + b.size.height - h - 12);
	[host addSublayer:sb_hint];
	fg_ca_end();
	CGImageRelease(image);
	shim_log("overlay_shim sidebar: showing the shortcut hint\n");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		fg_ca_begin();
		sb_hint.hidden = YES;
		fg_ca_end();
	});
}

// Test entry: applies and saves one setting as the sidebar does. Main thread.
__attribute__((visibility("default"))) int np_quick_settings_set(const char *key, const char *value)
{
	return sb_apply(key, value);
}
