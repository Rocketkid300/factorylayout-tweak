# FLProbe: four bare-bones tweaks, identical code, different filter plists.
#   A  Bundles    com.apple.springboard   old-style ASCII plist -> Theos stages it as a binary plist (like QuietUI)
#   B  Executables SpringBoard            same format as A
#   C  Bundles    com.apple.UIKit         baseline: exactly QuietUI's filter, acts only inside SpringBoard
#   D  Bundles    com.apple.springboard   XML plist, staged as XML (exactly what FactoryLayout shipped)
export TARGET := iphone:clang:15.6:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FLProbeA FLProbeB FLProbeC FLProbeD

FLProbeA_FILES = Probe.m
FLProbeA_FRAMEWORKS = UIKit
FLProbeA_CFLAGS = -fobjc-arc -DPROBE_NAME=\"A\" -DPROBE_LEVEL=1 -DPROBE_SB_ONLY=0

FLProbeB_FILES = Probe.m
FLProbeB_FRAMEWORKS = UIKit
FLProbeB_CFLAGS = -fobjc-arc -DPROBE_NAME=\"B\" -DPROBE_LEVEL=2 -DPROBE_SB_ONLY=0

FLProbeC_FILES = Probe.m
FLProbeC_FRAMEWORKS = UIKit
FLProbeC_CFLAGS = -fobjc-arc -DPROBE_NAME=\"C\" -DPROBE_LEVEL=3 -DPROBE_SB_ONLY=1

FLProbeD_FILES = Probe.m
FLProbeD_FRAMEWORKS = UIKit
FLProbeD_CFLAGS = -fobjc-arc -DPROBE_NAME=\"D\" -DPROBE_LEVEL=4 -DPROBE_SB_ONLY=0

include $(THEOS_MAKE_PATH)/tweak.mk
