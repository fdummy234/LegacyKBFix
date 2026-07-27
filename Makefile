TARGET := iphone:clang:latest:14.0
ARCHS  := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LegacyKBFix

LegacyKBFix_FILES     = Tweak.m
LegacyKBFix_CFLAGS    = -fobjc-arc -Wno-deprecated-declarations
LegacyKBFix_FRAMEWORKS = UIKit Foundation
LegacyKBFix_LIBRARIES =

include $(THEOS_MAKE_PATH)/tweak.mk

# Build :  make clean && make package FINALPACKAGE=1
# Le .deb sort dans ./packages/ — c'est ce fichier que tu donnes à Feather.
