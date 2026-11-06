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

// Layout, in points from the panel's top-left
#define sb_pad 22.0
#define sb_rows_top 168.0
#define sb_row_h 96.0
#define sb_seg_top 26.0
#define sb_seg_h 34.0

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

// MARK: Drawing

struct sb_fonts {
	CTFontRef title, big, label, seg, seg_bold, small, tiny;
	CGColorRef black, fg_dim;
};
static struct sb_fonts sb_f;

static void sb_fonts_load(void)
{
	ph_style_load();
	if (sb_f.title != NULL)
		return;
	sb_f.title = ph_font(19, 600);
	sb_f.big = ph_font(28, 600);
	sb_f.label = ph_font(13, 600);
	sb_f.seg = ph_font(12, 500);
	sb_f.seg_bold = ph_font(12, 650);
	sb_f.small = ph_font(11, 400);
	sb_f.tiny = ph_font(10, 500);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGFloat black[] = { 0, 0, 0, 1 }, dim[] = { PH_RGB(0x86868B, 0.55) };
	sb_f.black = CGColorCreate(srgb, black);
	sb_f.fg_dim = CGColorCreate(srgb, dim);
	CGColorSpaceRelease(srgb);
}

// A rectangle given from the top of a box h tall
static CGRect sb_rect(double h, double x, double y, double w, double rh)
{
	return CGRectMake(x, h - y - rh, w, rh);
}

static void sb_round(CGContextRef ctx, CGRect r, double radius, const CGFloat *fill, CGColorRef stroke)
{
	CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
	if (fill != NULL) {
		CGContextAddPath(ctx, path);
		CGContextSetRGBFillColor(ctx, fill[0], fill[1], fill[2], fill[3]);
		CGContextFillPath(ctx);
	}
	if (stroke != NULL) {
		CGContextAddPath(ctx, path);
		CGContextSetStrokeColorWithColor(ctx, stroke);
		CGContextSetLineWidth(ctx, 1);
		CGContextStrokePath(ctx);
	}
	CGPathRelease(path);
}

static void sb_hairline(CGContextRef ctx, double h, double x, double y, double w)
{
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, sb_rect(h, x, y, w, 1));
}

static double sb_seg_width(double w, int row)
{
	return (w - 2 * sb_pad - 6) / sb_counts[row];
}

static void sb_draw_row(CGContextRef ctx, double w, double h, int row)
{
	double top = sb_rows_top + row * sb_row_h;
	int focused = row == sb_row;
	int sel = sb_index(row);
	int disabled = row == sb_overlay && ph_hud_locked;
	char caption[96] = "", value[32] = "";

	if (focused) {
		CGContextSaveGState(ctx);
		CGPathRef bar = CGPathCreateWithRoundedRect(sb_rect(h, 9, top + 2, 2, 80), 1, 1, NULL);
		CGContextAddPath(ctx, bar);
		CGContextClip(ctx);
		ph_gradient(ctx, CGPointMake(0, h - top - 2), CGPointMake(0, h - top - 82));
		CGContextRestoreGState(ctx);
		CGPathRelease(bar);
	}
	ph_text(ctx, h, sb_pad, top + 14, sb_titles[row], sb_f.label, focused ? ph_style.fg : ph_style.fg2, -0.1);

	if (row == sb_overlay) {
		static const char *const notes[] = { "No overlay", "Frame rate only", "FPS, frame time, CPU, GPU, RAM, battery",
			                             "Adds a frame-time graph" };
		snprintf(caption, sizeof(caption), "%s", disabled ? "Apple's Metal HUD is on. Change it in Steam." :
		                                                    notes[sel < 0 ? 0 : sel]);
	} else if (row == sb_limit) {
		int hz = atomic_load(&ph_refresh_hz);
		if (sel < 0)
			snprintf(value, sizeof(value), "%d FPS, set in Steam", atomic_load(&fl_fixed_fps));
		if (hz > 0)
			snprintf(caption, sizeof(caption), "Paced to the %d Hz display, never changing it", hz);
		else
			snprintf(caption, sizeof(caption), "Paced to the display, never changing it");
	} else if (sb_host != nil) {
		CGSize d = sb_host.drawableSize;
		double scale = atomic_load(&ph_scale), sx = d.width > 0 ? sb_host.bounds.size.width * scale / d.width : 0;
		if (sx > 1.01)
			snprintf(caption, sizeof(caption), "Game draws %.0f×%.0f, shown %.1fx larger", d.width, d.height, sx);
		else
			snprintf(caption, sizeof(caption), "Game draws at full resolution: nothing to scale");
	}
	if (value[0]) {
		double vw = ph_width(value, sb_f.small, 0);
		ph_text(ctx, h, w - sb_pad - vw, top + 14, value, sb_f.small, ph_style.fg2, 0);
	}

	CGFloat track[] = { PH_RGB(0x161618, 1) }, chosen[] = { PH_RGB(0xF5F5F7, disabled ? 0.35 : 1) };
	CGRect box = sb_rect(h, sb_pad, top + sb_seg_top, w - 2 * sb_pad, sb_seg_h);
	sb_round(ctx, box, 8, track, focused ? ph_style.fg3 : ph_style.line);
	double segw = sb_seg_width(w, row);
	for (int i = 0; i < sb_counts[row]; i++) {
		double x = sb_pad + 3 + i * segw;
		int on = i == sel;
		if (on)
			sb_round(ctx, sb_rect(h, x, top + sb_seg_top + 3, segw, sb_seg_h - 6), 6, chosen, NULL);
		CTFontRef font = on ? sb_f.seg_bold : sb_f.seg;
		const char *label = sb_labels[row][i];
		double tw = ph_width(label, font, 0);
		CGColorRef color = on ? sb_f.black : disabled ? sb_f.fg_dim : ph_style.fg2;
		ph_text(ctx, h, x + (segw - tw) / 2, top + sb_seg_top + sb_seg_h / 2 + 4.5, label, font, color, 0);
	}
	ph_text(ctx, h, sb_pad, top + 78, caption, sb_f.small, ph_style.fg3, 0);
}

static void sb_draw(CGContextRef ctx, double w, double h)
{
	CGContextSetRGBFillColor(ctx, PH_RGB(0x0B0B0D, 0.97));
	CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, CGRectMake(0, 0, 1, h));

	ph_text(ctx, h, sb_pad, 36, "BRIDGEPLAY", sb_f.tiny, ph_style.fg3, 1.4);
	ph_text(ctx, h, sb_pad, 62, "Quick settings", sb_f.title, ph_style.fg, -0.3);
	const char *keys = "⌥⌘P";
	double kw = ph_width(keys, sb_f.small, 0.4);
	sb_round(ctx, sb_rect(h, w - sb_pad - kw - 14, 46, kw + 14, 22), 6, NULL, ph_style.line);
	ph_text(ctx, h, w - sb_pad - kw - 7, 61, keys, sb_f.small, ph_style.fg2, 0.4);
	sb_hairline(ctx, h, sb_pad, 82, w - 2 * sb_pad);

	int battery, on_ac, charging, minutes;
	ph_read_battery(&battery, &on_ac, &charging, &minutes);
	double watts = ph_power();
	char text[64];
	if (battery >= 0) {
		snprintf(text, sizeof(text), "%d%%", battery);
		ph_text(ctx, h, sb_pad, 124, text, sb_f.big, ph_style.fg, -0.4);
		if (on_ac == 1)
			snprintf(text, sizeof(text), "%s", charging == 1 ? "Charging" : "On power");
		else if (minutes > 0)
			snprintf(text, sizeof(text), "%d:%02d left", minutes / 60, minutes % 60);
		else
			snprintf(text, sizeof(text), "On battery");
		double tw = ph_width(text, sb_f.label, 0);
		ph_text(ctx, h, w - sb_pad - tw, 108, text, sb_f.label, ph_style.fg, 0);
		if (watts > 0) {
			snprintf(text, sizeof(text), "%.1f W drawn", watts);
			tw = ph_width(text, sb_f.small, 0);
			ph_text(ctx, h, w - sb_pad - tw, 125, text, sb_f.small, ph_style.fg2, 0);
		}
		CGFloat track[] = { PH_RGB(0x1C1C1F, 1) };
		CGRect bar = sb_rect(h, sb_pad, 138, w - 2 * sb_pad, 4);
		sb_round(ctx, bar, 2, track, NULL);
		CGContextSaveGState(ctx);
		CGPathRef fill = CGPathCreateWithRoundedRect(sb_rect(h, sb_pad, 138, (w - 2 * sb_pad) * battery / 100.0, 4),
		                                             2, 2, NULL);
		CGContextAddPath(ctx, fill);
		CGContextClip(ctx);
		ph_gradient(ctx, CGPointMake(sb_pad, 0), CGPointMake(w - sb_pad, 0));
		CGContextRestoreGState(ctx);
		CGPathRelease(fill);
	} else if (watts > 0) {
		snprintf(text, sizeof(text), "%.1f W", watts);
		ph_text(ctx, h, sb_pad, 124, text, sb_f.big, ph_style.fg, -0.4);
		ph_text(ctx, h, w - sb_pad - ph_width("Drawn by this Mac", sb_f.small, 0), 120, "Drawn by this Mac",
		        sb_f.small, ph_style.fg2, 0);
	} else {
		ph_text(ctx, h, sb_pad, 120, "No battery or power reading on this Mac", sb_f.small, ph_style.fg3, 0);
	}
	sb_hairline(ctx, h, sb_pad, 156, w - 2 * sb_pad);

	for (int row = 0; row < sb_rows; row++)
		sb_draw_row(ctx, w, h, row);

	// At the bottom, or right under the settings in a short window
	double foot = sb_rows_top + sb_rows * sb_row_h + 8;
	if (foot < h - 80)
		foot = h - 80;
	sb_hairline(ctx, h, sb_pad, foot, w - 2 * sb_pad);
	ph_text(ctx, h, sb_pad, foot + 24, sb_status[0] ? sb_status : "Changes apply now and are saved for this game.",
	        sb_f.small, sb_status[0] ? ph_style.fg : ph_style.fg2, 0);
	ph_text(ctx, h, sb_pad, foot + 48, "↑↓ choose   ←→ change   esc close", sb_f.small, ph_style.fg3, 0.2);
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
	double w = b.size.width < 360 ? b.size.width : 312;
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

static void sb_step(int row, int delta)
{
	if (row == sb_overlay && ph_hud_locked)
		return;
	int n = sb_counts[row], at = sb_index(row);
	int next = at < 0 ? (delta > 0 ? 0 : n - 1) : at + delta;
	if (delta == 0)
		next = at < 0 ? 0 : (at + 1) % n;
	if (next < 0 || next >= n || next == at)
		return;
	sb_apply(sb_keys[row], sb_values[row][next]);
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
	double seg_top = sb_rows_top + row * sb_row_h + sb_seg_top;
	if (y >= seg_top && y <= seg_top + sb_seg_h && x >= sb_pad + 3 && !(row == sb_overlay && ph_hud_locked)) {
		int i = (int)floor((x - sb_pad - 3) / sb_seg_width(sb_width, row));
		if (i >= 0 && i < sb_counts[row] && i != sb_index(row))
			sb_apply(sb_keys[row], sb_values[row][i]);
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
	case 3: case 5: case 6: case 7: case 22: case 25: case 27: // other presses, moves, drags, scrolls
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
	double kw = ph_width(keys, sb_f.label, 0.4), tw = ph_width(text, sb_f.small, 0);
	double w = 16 + kw + 10 + tw + 16, h = 32, scale = atomic_load(&ph_scale);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)ceil(w * scale), (size_t)ceil(h * scale), 8, 0, srgb,
	                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(srgb);
	if (ctx == NULL)
		return;
	CGContextScaleCTM(ctx, scale, scale);
	CGFloat fill[] = { PH_RGB(0x0D0D0F, 0.9) };
	sb_round(ctx, CGRectMake(0.5, 0.5, w - 1, h - 1), 8, fill, ph_style.line);
	ph_text(ctx, h, 16, 21, keys, sb_f.label, ph_style.fg, 0.4);
	ph_text(ctx, h, 16 + kw + 10, 20.5, text, sb_f.small, ph_style.fg2, 0);
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
