#!/usr/bin/env python3
"""Write FactoryLayout.plist as a *binary* plist (the format QuietUI's .deb ships).

usage: filters/make-filter.py bundles|executables|classes|any|uikit [output]
  bundles      Bundles    = com.apple.springboard
  executables  Executables = SpringBoard
  classes      Classes    = SpringBoard
  any          all three above with Mode = Any
  uikit        Bundles = com.apple.UIKit (QuietUI's filter; the ctor idles outside SpringBoard)
"""
import plistlib, sys

FILTERS = {
    "bundles":     {"Bundles": ["com.apple.springboard"]},
    "executables": {"Executables": ["SpringBoard"]},
    "classes":     {"Classes": ["SpringBoard"]},
    "uikit":       {"Bundles": ["com.apple.UIKit"]},
    "any":         {"Bundles": ["com.apple.springboard"], "Executables": ["SpringBoard"],
                    "Classes": ["SpringBoard"], "Mode": "Any"},
}

if len(sys.argv) < 2 or sys.argv[1] not in FILTERS:
    sys.exit(__doc__)
out = sys.argv[2] if len(sys.argv) > 2 else "FactoryLayout.plist"
with open(out, "wb") as f:
    plistlib.dump({"Filter": FILTERS[sys.argv[1]]}, f, fmt=plistlib.FMT_BINARY)
print("wrote %s (%s)" % (out, sys.argv[1]))
