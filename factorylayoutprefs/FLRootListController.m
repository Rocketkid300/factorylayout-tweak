#import "FLRootListController.h"
#import <Preferences/PSSpecifier.h>

#define FL_DOMAIN CFSTR("com.factorylayout.prefs")

static void FLPost(CFStringRef name) {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, NULL, NULL, YES);
}

@implementation FLRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:@"key"];
	if (!key) return [super readPreferenceValue:specifier];
	CFPreferencesAppSynchronize(FL_DOMAIN);
	CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, FL_DOMAIN);
	if (!v) return [specifier propertyForKey:@"default"];
	return CFBridgingRelease(v);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:@"key"];
	if (!key) { [super setPreferenceValue:value specifier:specifier]; return; }
	CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, FL_DOMAIN);
	CFPreferencesAppSynchronize(FL_DOMAIN);
	FLPost(CFSTR("com.factorylayout.prefs/changed"));
}

- (void)resetNow {
	FLPost(CFSTR("com.factorylayout.prefs/resetNow"));
}

- (void)checkMissing {
	FLPost(CFSTR("com.factorylayout.prefs/checkMissing"));
}

@end
