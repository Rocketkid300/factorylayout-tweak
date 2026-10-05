// Bare-bones injection probe: no hooks, no preferences. On load it logs to syslog (NSLog) and
// appends to /var/mobile/FLProbe.log + /var/tmp/FLProbe.log, then shows an alert 12s later.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

static UIWindow *sWindow;

static void ProbeLog(NSString *line) {
	NSLog(@"[FactoryLayout][probe %s] %@", PROBE_NAME, line);
	NSString *full = [NSString stringWithFormat:@"%@ [probe %s] %@\n", [NSDate date], PROBE_NAME, line];
	const char *paths[] = { "/var/mobile/FLProbe.log", "/var/tmp/FLProbe.log" };
	for (int i = 0; i < 2; i++) {
		FILE *f = fopen(paths[i], "a");
		if (f) { fputs(full.UTF8String, f); fclose(f); }
	}
}

static void ProbeAlert(NSString *text) {
	UIWindowScene *scene = nil;
	for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
		if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
	sWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
	                : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	sWindow.windowLevel = UIWindowLevelAlert + PROBE_LEVEL;
	sWindow.rootViewController = [UIViewController new];
	sWindow.hidden = NO;
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"FLProbe %s", PROBE_NAME]
		message:text preferredStyle:UIAlertControllerStyleAlert];
	[ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { sWindow.hidden = YES; }]];
	[sWindow.rootViewController presentViewController:ac animated:YES completion:nil];
}

__attribute__((constructor)) static void ProbeInit(void) {
	const char *prog = getprogname() ?: "?";
	if (PROBE_SB_ONLY && strcmp(prog, "SpringBoard") != 0) return;
	Dl_info info = {0};
	dladdr((void *)&ProbeInit, &info);
	NSString *line = [NSString stringWithFormat:@"loaded pid=%d progname=%s bundleID=%@ image=%s",
		(int)getpid(), prog, [[NSBundle mainBundle] bundleIdentifier], info.dli_fname ?: "?"];
	ProbeLog(line);
	if (strcmp(prog, "SpringBoard") != 0) return;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		ProbeLog(@"showing alert");
		ProbeAlert(line);
	});
}
