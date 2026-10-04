# Same toolchain settings as QuietUI. iPhone 7 Plus (iPhone9,4 / D111AP), iOS 15.8.3, palera1n rootless.
export TARGET := iphone:clang:15.6:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export DEBUG = 0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FactoryLayout

FactoryLayout_FILES = Tweak.x
FactoryLayout_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FactoryLayout_FRAMEWORKS = UIKit

SUBPROJECTS += factorylayoutprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
