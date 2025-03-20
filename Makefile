TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

THEOS_DEVICE_IP=192.168.0.165

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamTeste

VCamTeste_FILES = Tweak.x
VCamTeste_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
