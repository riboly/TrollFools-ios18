ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = TrollFoolsLoader

TrollFoolsLoader_FILES = TrollFoolsLoader.m
TrollFoolsLoader_CFLAGS = -fobjc-arc
TrollFoolsLoader_FRAMEWORKS = Foundation UIKit
TrollFoolsLoader_LDFLAGS = -Wl,-install_name,@rpath/TrollFoolsLoader.dylib -Wl,-rpath,@executable_path/Frameworks
TrollFoolsLoader_INSTALL_PATH = /usr/local/lib

include $(THEOS_MAKE_PATH)/library.mk
