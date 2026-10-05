// FactoryLayout - restore the Home Screen to the system DefaultIconState layout.
// Runs inside SpringBoard (user "mobile"). Every private class/selector is checked at
// runtime and nothing links against private frameworks. This tweak never touches icon
// visibility, so icons hidden by AppHider stay hidden.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <pwd.h>
#import <unistd.h>
#import "FactoryBundleIDs.h"

#define FL_DOMAIN        CFSTR("com.factorylayout.prefs")
#define FL_NOTE_CHANGED  CFSTR("com.factorylayout.prefs/changed")
#define FL_NOTE_RESET    CFSTR("com.factorylayout.prefs/resetNow")
#define FL_NOTE_CHECK    CFSTR("com.factorylayout.prefs/checkMissing")
#define FL_SB_DIR        @"Library/SpringBoard"
#define FL_BACKUP_DIR    @"FactoryLayoutBackup"
#define FL_KEY_PENDING_INSTALL CFSTR("pendingInstall") // bundle IDs we sent the user to install
#define FL_KEY_PENDING_CHECK   CFSTR("pendingCheck")   // run a missing-app check after next launch
#define FL_KEY_LAST_SET        CFSTR("lastAlertedSet") // signature of the last missing set shown
#define FL_KEY_SEEN            CFSTR("seenApps")       // expected apps that were ever seen installed

#define FLLog(fmt, ...) NSLog(@"[FactoryLayout] " fmt, ##__VA_ARGS__)

@interface SpringBoard : UIApplication
- (void)_relaunchSpringBoardNow;
@end

static BOOL gLastEnabled = NO;
static BOOL gAlertShowing = NO;
static BOOL gLaunchHandled = NO;
static UIWindow *gAlertWindow = nil;
static NSUInteger gIconAddedGen = 0;

#pragma mark - Preferences (CFPreferences)

static BOOL FLBoolPref(CFStringRef key, BOOL def) {
	CFPreferencesAppSynchronize(FL_DOMAIN);
	CFPropertyListRef v = CFPreferencesCopyAppValue(key, FL_DOMAIN);
	BOOL out = def;
	if (v) {
		if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue((CFBooleanRef)v);
		else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
			int n = 0;
			CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
			out = (n != 0);
		}
		CFRelease(v);
	}
	return out;
}

static void FLSetPref(CFStringRef key, CFPropertyListRef value) {
	CFPreferencesSetAppValue(key, value, FL_DOMAIN);
	CFPreferencesAppSynchronize(FL_DOMAIN);
}

static void FLSetBoolPref(CFStringRef key, BOOL value) {
	FLSetPref(key, value ? kCFBooleanTrue : kCFBooleanFalse);
}

static id FLObjectPref(CFStringRef key, Class cls) {
	CFPreferencesAppSynchronize(FL_DOMAIN);
	CFPropertyListRef v = CFPreferencesCopyAppValue(key, FL_DOMAIN);
	id obj = v ? CFBridgingRelease(v) : nil;
	return [obj isKindOfClass:cls] ? obj : nil;
}

static NSArray<NSString *> *FLPendingInstalls(void) {
	return FLObjectPref(FL_KEY_PENDING_INSTALL, [NSArray class]) ?: @[];
}

#pragma mark - Runtime helpers

static id FLCall0(id obj, NSString *selName) {
	SEL s = NSSelectorFromString(selName);
	if (!obj || ![obj respondsToSelector:s]) return nil;
	return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static BOOL FLCallBool0(id obj, NSString *selName) {
	SEL s = NSSelectorFromString(selName);
	if (!obj || ![obj respondsToSelector:s]) return NO;
	return ((BOOL (*)(id, SEL))objc_msgSend)(obj, s);
}

static id FLWorkspace(void) {
	return FLCall0((id)objc_getClass("LSApplicationWorkspace"), @"defaultWorkspace");
}

static NSString *FLHardwareModel(void) {
	char buf[64] = {0};
	size_t len = sizeof(buf);
	if (sysctlbyname("hw.model", buf, &len, NULL, 0) != 0) return @"";
	return [NSString stringWithUTF8String:buf] ?: @"";
}

#pragma mark - Installed-app detection

// Lower-cased bundle IDs from both LaunchServices lists (the union keeps apps that another
// tweak such as AppHider hides from one list), plus alias partners. nil if unavailable.
static NSSet<NSString *> *FLInstalledBundleIDs(id ws) {
	NSMutableSet<NSString *> *set = [NSMutableSet set];
	@try {
		for (NSString *sel in @[@"allApplications", @"allInstalledApplications"]) {
			id apps = FLCall0(ws, sel);
			if (![apps isKindOfClass:[NSArray class]]) continue;
			NSArray *ids = [(NSArray *)apps valueForKey:@"bundleIdentifier"];
			for (id i in ids) if ([i isKindOfClass:[NSString class]]) [set addObject:[(NSString *)i lowercaseString]];
		}
	} @catch (NSException *e) {
		FLLog(@"installed-app lookup failed: %@", e);
		return nil;
	}
	if (!set.count) return nil;
	for (size_t i = 0; i < FL_ALIAS_COUNT; i++) {
		NSString *a = [NSString stringWithUTF8String:kFLAliases[i][0]];
		NSString *b = [NSString stringWithUTF8String:kFLAliases[i][1]];
		if ([set containsObject:a]) [set addObject:b];
		if ([set containsObject:b]) [set addObject:a];
	}
	return set;
}

static BOOL FLBundleInstalled(NSSet<NSString *> *installed, id ws, NSString *bid) {
	if ([installed containsObject:bid.lowercaseString]) return YES;
	SEL s = NSSelectorFromString(@"applicationIsInstalled:");
	if (ws && [ws respondsToSelector:s]) {
		@try { return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, bid); } @catch (NSException *e) {}
	}
	return NO;
}

#pragma mark - Reset (files + respring)

// Candidate Library/SpringBoard directories de-duplicated by resolved path. On rootless,
// /var/jb/var/mobile normally symlinks to /var/mobile.
static NSArray<NSString *> *FLSpringBoardDirs(void) {
	NSMutableArray<NSString *> *out = [NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	NSMutableArray<NSString *> *homes = [NSMutableArray array];
	NSString *h = NSHomeDirectory();
	if (h.length) [homes addObject:h];
	[homes addObject:@"/var/mobile"];
	[homes addObject:@"/var/jb/var/mobile"];
	for (NSString *home in homes) {
		NSString *dir = [[home stringByAppendingPathComponent:FL_SB_DIR] stringByResolvingSymlinksInPath];
		if ([seen containsObject:dir]) continue;
		[seen addObject:dir];
		[out addObject:dir];
	}
	return out;
}

static void FLFixOwnership(NSString *path) {
	[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)} ofItemAtPath:path error:nil];
	struct passwd *pw = getpwnam("mobile");
	if (!pw) return;
	if (geteuid() == 0) chown(path.fileSystemRepresentation, pw->pw_uid, pw->pw_gid);
	else if (geteuid() != pw->pw_uid) FLLog(@"warning: not running as mobile (euid %d)", (int)geteuid());
}

// Deletes the named files from every SpringBoard dir. With backup=YES the latest copy is
// kept in Library/SpringBoard/FactoryLayoutBackup/ first.
static void FLDeleteLayoutFiles(NSArray<NSString *> *names, BOOL backup) {
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSString *dir in FLSpringBoardDirs()) {
		for (NSString *name in names) {
			NSString *p = [dir stringByAppendingPathComponent:name];
			if (![fm fileExistsAtPath:p]) continue;
			if (backup) {
				NSString *bdir = [dir stringByAppendingPathComponent:FL_BACKUP_DIR];
				[fm createDirectoryAtPath:bdir withIntermediateDirectories:YES attributes:nil error:nil];
				NSString *bp = [bdir stringByAppendingPathComponent:name];
				[fm removeItemAtPath:bp error:nil];
				if ([fm copyItemAtPath:p toPath:bp error:nil]) FLFixOwnership(bp);
			}
			NSError *err = nil;
			if ([fm removeItemAtPath:p error:&err]) FLLog(@"removed %@", p);
			else FLLog(@"could not remove %@: %@", p, err);
		}
	}
}

// Picks the DefaultIconState*.plist for this device and copies it, unchanged, to
// DesiredIconState.plist. Returns NO if nothing was seeded (caller continues delete-only).
static BOOL FLSeedFromSystemDefault(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *sbApp = @"/System/Library/CoreServices/SpringBoard.app";
	BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;

	NSMutableArray<NSString *> *all = [NSMutableArray array];
	NSMutableArray<NSString *> *usable = [NSMutableArray array];
	for (NSString *f in [[fm contentsOfDirectoryAtPath:sbApp error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
		if (![f hasPrefix:@"DefaultIconState"] || ![f hasSuffix:@".plist"]) continue;
		[all addObject:f];
		if (!isPad && [f.lowercaseString containsString:@"ipad"]) continue;
		[usable addObject:f];
	}

	// 1) screen-size file (e.g. DefaultIconState-414w-736h.plist on a 5.5" 7 Plus), 2) model
	// token, 3) generic file without a size suffix, 4) first sorted. Size comes from the
	// logical screen in points, so Display Zoom (375w-667h) picks its own matching file.
	NSString *model = FLHardwareModel();
	CGRect sb = [UIScreen mainScreen].bounds;
	NSString *sizeToken = [NSString stringWithFormat:@FL_SEED_SIZE_FORMAT,
		(int)lround(MIN(sb.size.width, sb.size.height)), (int)lround(MAX(sb.size.width, sb.size.height))];
	NSString *pick = nil;
	const char *why = "none";
	for (NSString *f in usable) if ([f containsString:sizeToken]) { pick = f; why = "screen size"; break; }
	if (!pick) {
		NSMutableArray<NSString *> *tokens = [NSMutableArray array];
		if (model.length) [tokens addObject:model];
		for (size_t i = 0; i < FL_SEED_MODEL_COUNT; i++) [tokens addObject:[NSString stringWithUTF8String:kFLSeedModelTokens[i]]];
		for (NSString *t in tokens) {
			for (NSString *f in usable) if ([f.lowercaseString containsString:t.lowercaseString]) { pick = f; why = "model token"; break; }
			if (pick) break;
		}
	}
	if (!pick) {
		for (NSString *f in usable)
			if ([f rangeOfString:@FL_SEED_SIZE_REGEX options:NSRegularExpressionSearch].location == NSNotFound) { pick = f; why = "generic file"; break; }
	}
	if (!pick) { pick = usable.firstObject; why = pick ? "first sorted" : "none"; }
	FLLog(@"hw.model=%@ screen=%.0fx%.0fpt sizeToken=%@ DefaultIconState candidates=%@ usable=%@ chosen=%@ (%s)",
		model, sb.size.width, sb.size.height, sizeToken, all, usable, pick ?: @"(none)", why);
	if (!pick) { FLLog(@"no usable DefaultIconState*.plist, delete-only"); return NO; }

	NSString *dir = nil;
	for (NSString *d in FLSpringBoardDirs()) if ([fm fileExistsAtPath:d]) { dir = d; break; }
	if (!dir) {
		dir = FLSpringBoardDirs().firstObject;
		[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	}
	NSString *dst = [dir stringByAppendingPathComponent:@"DesiredIconState.plist"];
	[fm removeItemAtPath:dst error:nil];
	NSError *err = nil;
	if (![fm copyItemAtPath:[sbApp stringByAppendingPathComponent:pick] toPath:dst error:&err]) {
		FLLog(@"seed copy failed: %@", err);
		return NO;
	}
	FLFixOwnership(dst);
	FLLog(@"seeded %@ from %@", dst, pick);
	return YES;
}

// Runs inline (no delay) right after the files are written, so there is no window in which
// SpringBoard could re-save its layout before it is relaunched.
static void FLRespring(void) {
	@try {
		UIApplication *app = [UIApplication sharedApplication];
		if ([app respondsToSelector:@selector(_relaunchSpringBoardNow)]) {
			FLLog(@"respring via _relaunchSpringBoardNow");
			[(SpringBoard *)app _relaunchSpringBoardNow];
			return;
		}
		id svc = FLCall0((id)objc_getClass("FBSystemService"), @"sharedInstance");
		SEL sel = NSSelectorFromString(@"exitAndRelaunch:");
		if (svc && [svc respondsToSelector:sel]) {
			FLLog(@"respring via FBSystemService exitAndRelaunch:");
			((void (*)(id, SEL, BOOL))objc_msgSend)(svc, sel, YES);
			return;
		}
	} @catch (NSException *e) {
		FLLog(@"respring exception: %@", e);
	}
	FLLog(@"ERROR: no respring API available - respring manually (sbreload)");
}

static void FLApplyFactoryLayout(const char *reason) {
	FLLog(@"applying factory layout (%s)", reason);
	FLDeleteLayoutFiles(@[@"IconState.plist", @"DesiredIconState.plist"], YES);
	FLSeedFromSystemDefault();
	// The respring would kill an alert, so ask for the missing-app check after relaunch.
	if (FLBoolPref(CFSTR("notifyMissing"), YES)) FLSetBoolPref(FL_KEY_PENDING_CHECK, YES);
	FLRespring();
}

#pragma mark - Missing-app alert

static NSURL *FLStoreURL(const FLExpectedApp *app) {
	if (app->appStoreID)
		return [NSURL URLWithString:[NSString stringWithFormat:@"itms-apps://itunes.apple.com/app/id%s", app->appStoreID]];
	NSString *q = [[NSString stringWithUTF8String:app->name] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	return [NSURL URLWithString:[@"itms-apps://search?term=" stringByAppendingString:q ?: @""]];
}

// Silent install is impossible on iOS, so the best we can do is deep-link into the App Store.
static void FLOpenURL(NSURL *url) {
	if (!url) return;
	id ws = FLWorkspace();
	SEL s = NSSelectorFromString(@"openSensitiveURL:withOptions:");
	if (ws && [ws respondsToSelector:s]) {
		((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s, url, nil);
		return;
	}
	UIApplication *app = [UIApplication sharedApplication];
	if ([app respondsToSelector:@selector(openURL:options:completionHandler:)])
		[app openURL:url options:@{} completionHandler:nil];
}

static void FLAlertDone(void) {
	gAlertShowing = NO;
	gAlertWindow.hidden = YES;
	gAlertWindow = nil;
}

static UIWindowScene *FLFirstWindowScene(void) {
	for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
		if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
	return nil;
}

static UIViewController *FLTopOf(UIViewController *vc) {
	while (vc.presentedViewController) vc = vc.presentedViewController;
	return vc;
}

static UIViewController *FLPresenter(void) {
	@try {
		for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
			if (![s isKindOfClass:[UIWindowScene class]]) continue;
			for (UIWindow *w in ((UIWindowScene *)s).windows) {
				if (w.isKeyWindow && w.rootViewController) {
					FLLog(@"alert path: scene keyWindow root");
					return FLTopOf(w.rootViewController);
				}
			}
		}
		for (UIWindow *w in [UIApplication sharedApplication].windows) {
			if (w.isKeyWindow && w.rootViewController) {
				FLLog(@"alert path: application keyWindow root");
				return FLTopOf(w.rootViewController);
			}
		}
		UIWindowScene *scene = FLFirstWindowScene();
		gAlertWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
		                     : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
		gAlertWindow.windowLevel = UIWindowLevelAlert;
		gAlertWindow.rootViewController = [UIViewController new];
		gAlertWindow.hidden = NO;
		FLLog(@"alert path: dedicated UIWindowLevelAlert window");
		return gAlertWindow.rootViewController;
	} @catch (NSException *e) {
		FLLog(@"no alert presenter available: %@", e);
		return nil;
	}
}

static void FLPresentMissingAlert(NSArray<NSNumber *> *missing, NSString *signature) {
	if (gAlertShowing || !missing.count) return;
	UIViewController *host = FLPresenter();
	if (!host) return;

	NSMutableString *msg = [NSMutableString stringWithString:@"These removable system apps are not installed. iOS cannot install apps silently, so each one has to be installed from the App Store.\n\n"];
	for (NSNumber *n in missing) [msg appendFormat:@"• %s\n", kFLExpectedApps[n.unsignedIntegerValue].name];
	if (missing.count > 4) [msg appendString:@"\nOnly the first 4 have buttons; search the App Store for the others."];
	[msg appendString:@"\nNew icons are appended at the end of the layout. After installing, run Reset Now again to settle the order."];

	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"FactoryLayout: missing apps"
		message:msg preferredStyle:UIAlertControllerStyleAlert];
	for (NSNumber *n in [missing subarrayWithRange:NSMakeRange(0, MIN(missing.count, (NSUInteger)4))]) {
		const FLExpectedApp *app = &kFLExpectedApps[n.unsignedIntegerValue];
		NSString *name = [NSString stringWithUTF8String:app->name];
		NSString *bid = [NSString stringWithUTF8String:app->bundleID];
		NSURL *url = FLStoreURL(app);
		[ac addAction:[UIAlertAction actionWithTitle:[@"Install " stringByAppendingString:name]
			style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
				NSMutableArray *p = [FLPendingInstalls() mutableCopy];
				if (![p containsObject:bid]) [p addObject:bid];
				FLSetPref(FL_KEY_PENDING_INSTALL, (__bridge CFPropertyListRef)p);
				FLLog(@"opening App Store for %@: %@", name, url);
				FLOpenURL(url);
				FLAlertDone();
			}]];
	}
	[ac addAction:[UIAlertAction actionWithTitle:@"Don't Show Again" style:UIAlertActionStyleDestructive
		handler:^(UIAlertAction *a) {
			FLSetBoolPref(CFSTR("notifyMissing"), NO); // same switch as in Settings
			FLLog(@"missing-app notifications turned off");
			FLAlertDone();
		}]];
	[ac addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel
		handler:^(UIAlertAction *a) { FLAlertDone(); }]];

	gAlertShowing = YES;
	FLSetPref(FL_KEY_LAST_SET, (__bridge CFPropertyListRef)signature); // once per missing set
	[host presentViewController:ac animated:YES completion:nil];
}

// Wait for the lock screen to be dismissed before showing UI (alert would be hidden behind it).
static void FLShowWhenReady(NSArray<NSNumber *> *missing, NSString *signature, NSUInteger attempt) {
	id lock = FLCall0((id)objc_getClass("SBLockScreenManager"), @"sharedInstance");
	if (FLCallBool0(lock, @"isUILocked") && attempt < 120) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			FLShowWhenReady(missing, signature, attempt + 1);
		});
		return;
	}
	FLPresentMissingAlert(missing, signature);
}

// manual=YES (button / after Reset Now) ignores the once-per-set dedupe.
static void FLCheckMissingApps(BOOL manual) {
	id ws = FLWorkspace();
	NSSet<NSString *> *installed = FLInstalledBundleIDs(ws);
	if (!installed) { FLLog(@"cannot enumerate installed apps, skipping check"); return; }

	NSMutableArray<NSNumber *> *missing = [NSMutableArray array];
	NSMutableArray<NSString *> *ids = [NSMutableArray array];
	NSMutableArray<NSString *> *seen = [(FLObjectPref(FL_KEY_SEEN, [NSArray class]) ?: @[]) mutableCopy];
	NSUInteger seenCount = seen.count;
	for (NSUInteger i = 0; i < FL_EXPECTED_COUNT; i++) {
		NSString *bid = [NSString stringWithUTF8String:kFLExpectedApps[i].bundleID];
		if (FLBundleInstalled(installed, ws, bid)) {
			if (![seen containsObject:bid]) [seen addObject:bid];
			continue;
		}
		// optional apps (iWork, iMovie, GarageBand) were never on a fresh iPhone: only
		// report them if they were installed at some earlier check and have since vanished
		if (kFLExpectedApps[i].optional && ![seen containsObject:bid]) continue;
		[missing addObject:@(i)];
		[ids addObject:bid];
	}
	if (seen.count != seenCount) FLSetPref(FL_KEY_SEEN, (__bridge CFPropertyListRef)seen);
	FLLog(@"%lu removable system app(s) missing: %@", (unsigned long)missing.count, ids);
	NSString *signature = [[ids sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
	if (!missing.count) { FLSetPref(FL_KEY_LAST_SET, NULL); return; }
	if (!manual && [signature isEqualToString:FLObjectPref(FL_KEY_LAST_SET, [NSString class])]) {
		FLLog(@"this missing set was already shown, skipping");
		return;
	}
	FLShowWhenReady(missing, signature, 0);
}

static BOOL FLAnyPendingInstalled(void) {
	NSArray<NSString *> *pending = FLPendingInstalls();
	if (!pending.count) return NO;
	id ws = FLWorkspace();
	NSSet<NSString *> *installed = FLInstalledBundleIDs(ws);
	if (!installed) return NO;
	for (NSString *bid in pending) if (FLBundleInstalled(installed, ws, bid)) return YES;
	return NO;
}

#pragma mark - Triggers

static void FLOnLaunch(void) {
	BOOL enabled = FLBoolPref(CFSTR("enabled"), NO);
	if (enabled && FLAnyPendingInstalled()) { // an app we linked to is now installed: re-apply once
		FLSetPref(FL_KEY_PENDING_INSTALL, NULL);
		FLApplyFactoryLayout("installed missing app");
		return;
	}
	if (FLBoolPref(FL_KEY_PENDING_CHECK, NO)) { // requested by Reset Now / toggle before the respring
		FLSetBoolPref(FL_KEY_PENDING_CHECK, NO);
		FLCheckMissingApps(YES);
		return;
	}
	if (enabled && FLBoolPref(CFSTR("notifyMissing"), YES)) FLCheckMissingApps(NO);
}

static void FLPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
	FLLog(@"notification: %@", n);
	dispatch_async(dispatch_get_main_queue(), ^{
		BOOL now = FLBoolPref(CFSTR("enabled"), NO);
		BOOL was = gLastEnabled;
		gLastEnabled = now;
		if (now && !was) FLApplyFactoryLayout("toggle on"); // OFF -> ON only
	});
}

static void FLResetNow(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
	FLLog(@"notification: %@", n);
	dispatch_async(dispatch_get_main_queue(), ^{ FLApplyFactoryLayout("reset now"); });
}

static void FLCheckNow(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
	FLLog(@"notification: %@", n);
	dispatch_async(dispatch_get_main_queue(), ^{ FLCheckMissingApps(YES); });
}

static void FLScheduleIconAdded(void) {
	NSUInteger gen = ++gIconAddedGen; // debounce bursts of adds
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (gen != gIconAddedGen) return;
		if (!FLBoolPref(CFSTR("enabled"), NO) || !FLAnyPendingInstalled()) return;
		FLSeedFromSystemDefault(); // refresh the seed only; the full re-apply happens at next launch
	});
}

static void FLHandleLaunchOnce(const char *trigger) {
	if (gLaunchHandled) return;
	gLaunchHandled = YES;
	FLLog(@"launch handling triggered by %s", trigger);
	// let the home screen finish loading before touching UI or the icon files
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		@try { FLOnLaunch(); } @catch (NSException *e) { FLLog(@"launch handler exception: %@", e); }
	});
}

#pragma mark - Hooks (installed only when the class and selector exist)

%group LaunchHook
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	FLHandleLaunchOnce("applicationDidFinishLaunching:");
}
%end
%end

%group LaunchOptionsHook
%hook SpringBoard
- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
	BOOL r = %orig;
	FLHandleLaunchOnce("application:didFinishLaunchingWithOptions:");
	return r;
}
%end
%end

%group IconAddedHook
%hook SBIconModel
- (void)addIcon:(id)icon {
	%orig;
	FLScheduleIconAdded();
}
%end
%end

// The bundle identifier can still be nil this early in process start-up, so the process
// name is accepted too (the injection filter already limits us to SpringBoard).
static BOOL FLIsSpringBoard(NSString *bundleID) {
	if ([bundleID isEqualToString:@"com.apple.springboard"]) return YES;
	const char *name = getprogname();
	return name && strcmp(name, "SpringBoard") == 0;
}

%ctor {
	@autoreleasepool {
		NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
		FLLog(@"ctor entered: pid=%d progname=%s bundleID=%@ bundlePath=%@",
			(int)getpid(), getprogname() ?: "?", bid, [[NSBundle mainBundle] bundlePath]);
		if (!FLIsSpringBoard(bid)) { FLLog(@"not SpringBoard, staying idle"); return; }
		FLLog(@"loaded in SpringBoard, hw.model=%@", FLHardwareModel());

		gLastEnabled = FLBoolPref(CFSTR("enabled"), NO);
		CFNotificationCenterRef d = CFNotificationCenterGetDarwinNotifyCenter();
		CFNotificationCenterAddObserver(d, NULL, FLPrefsChanged, FL_NOTE_CHANGED, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
		CFNotificationCenterAddObserver(d, NULL, FLResetNow, FL_NOTE_RESET, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
		CFNotificationCenterAddObserver(d, NULL, FLCheckNow, FL_NOTE_CHECK, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

		int launchHooks = 0;
		Class sb = objc_getClass("SpringBoard");
		if (sb && [sb instancesRespondToSelector:@selector(applicationDidFinishLaunching:)]) {
			%init(LaunchHook);
			launchHooks++;
		} else {
			FLLog(@"SpringBoard applicationDidFinishLaunching: not found");
		}
		if (sb && [sb instancesRespondToSelector:NSSelectorFromString(@"application:didFinishLaunchingWithOptions:")]) {
			%init(LaunchOptionsHook);
			launchHooks++;
		} else {
			FLLog(@"SpringBoard application:didFinishLaunchingWithOptions: not found");
		}
		FLLog(@"launch hooks installed: %d", launchHooks);

		// Safety net: if no hook exists, or none ever fires, start the launch handling directly.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((launchHooks ? 30 : 10) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (!gLaunchHandled) FLLog(@"no launch hook fired, running delayed fallback");
			FLHandleLaunchOnce("delayed fallback");
		});

		Class model = objc_getClass("SBIconModel");
		if (model && [model instancesRespondToSelector:NSSelectorFromString(@"addIcon:")]) {
			%init(IconAddedHook);
		} else {
			FLLog(@"SBIconModel addIcon: not found, icon-added reseed skipped - run Reset Now a second time after installing apps");
		}
	}
}
