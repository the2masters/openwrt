include $(TOPDIR)/rules.mk

ARCH:=mips
BOARD:=ath79
BOARDNAME:=Atheros ATH79
CPU_TYPE:=24kc
SUBTARGETS:=generic mikrotik nand tiny

KERNEL_PATCHVER:=5.4
KERNEL_TESTING_PATCHVER:=5.4

include $(INCLUDE_DIR)/target.mk

DEFAULT_PACKAGES += \
	kmod-gpio-button-hotplug swconfig \
	kmod-ath9k uboot-envtools

$(eval $(call BuildTarget))
