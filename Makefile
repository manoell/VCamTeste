TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

THEOS_DEVICE_IP=192.168.0.165

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamTeste

TTtest_FILES = Tweak.x
TTtest_CFLAGS = -fobjc-arc -Werror -Wdeprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
