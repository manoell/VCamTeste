TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

# Update with your device's IP address
THEOS_DEVICE_IP=192.168.0.165

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamTeste

VCamTeste_FILES = Tweak.x
VCamTeste_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
VCamTeste_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo

# Add extra flags for optimization
VCamTeste_CFLAGS += -O2 -ffast-math

include $(THEOS_MAKE_PATH)/tweak.mk
