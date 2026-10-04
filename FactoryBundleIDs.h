// Detection data only. Icon ORDER always comes from the system DefaultIconState plist.
// Only apps the user can delete on iOS 15 are listed, so non-removable apps
// (Phone, Safari, Messages, Photos, Camera, App Store, Settings) are never flagged.
#ifndef FACTORY_BUNDLE_IDS_H
#define FACTORY_BUNDLE_IDS_H

typedef struct {
	const char *bundleID;
	const char *name;
	const char *appStoreID; // verified App Store ID, or NULL -> fall back to a search link
	int optional;           // 1: not preinstalled on a fresh iPhone, only flagged once seen installed
} FLExpectedApp;

static const FLExpectedApp kFLExpectedApps[] = {
	{ "com.apple.iBooks",            "Books",       "364709193", 0 },
	{ "com.apple.mobilecal",         "Calendar",    NULL, 0 },
	{ "com.apple.compass",           "Compass",     NULL, 0 },
	{ "com.apple.MobileAddressBook", "Contacts",    NULL, 0 },
	{ "com.apple.facetime",          "FaceTime",    NULL, 0 },
	{ "com.apple.DocumentsApp",      "Files",       NULL, 0 },
	{ "com.apple.Home",              "Home",        NULL, 0 },
	{ "com.apple.mobilemail",        "Mail",        NULL, 0 },
	{ "com.apple.Maps",              "Maps",        NULL, 0 },
	{ "com.apple.measure",           "Measure",     NULL, 0 },
	{ "com.apple.Music",             "Music",       NULL, 0 },
	{ "com.apple.news",              "News",        NULL, 0 },
	{ "com.apple.mobilenotes",       "Notes",       NULL, 0 },
	{ "com.apple.podcasts",          "Podcasts",    NULL, 0 },
	{ "com.apple.reminders",         "Reminders",   NULL, 0 },
	{ "com.apple.shortcuts",         "Shortcuts",   NULL, 0 },
	{ "com.apple.stocks",            "Stocks",      NULL, 0 },
	{ "com.apple.tips",              "Tips",        NULL, 0 },
	{ "com.apple.tv",                "TV",          NULL, 0 },
	{ "com.apple.VoiceMemos",        "Voice Memos", NULL, 0 },
	{ "com.apple.weather",           "Weather",     NULL, 0 },
	{ "com.apple.Bridge",            "Watch",       NULL, 0 },
	{ "com.apple.Pages",             "Pages",       "361309726", 1 },
	{ "com.apple.Numbers",           "Numbers",     "361304891", 1 },
	{ "com.apple.Keynote",           "Keynote",     "361285480", 1 },
	{ "com.apple.iMovie",            "iMovie",      "377298193", 1 },
	{ "com.apple.mobilegarageband",  "GarageBand",  "408709785", 1 },
};
#define FL_EXPECTED_COUNT (sizeof(kFLExpectedApps) / sizeof(kFLExpectedApps[0]))

// Bundle IDs that mean the same app (lower-case). Installing either satisfies both.
static const char *const kFLAliases[][2] = {
	{ "com.apple.music",      "com.apple.mobilemusic" },
	{ "com.apple.mobiletimer", "com.apple.mobileclock" },
};
#define FL_ALIAS_COUNT (sizeof(kFLAliases) / sizeof(kFLAliases[0]))

#endif
