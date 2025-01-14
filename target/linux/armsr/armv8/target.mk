ARCH:=aarch64
SUBTARGET:=armv8
BOARDNAME:=64-bit (armv8) machines
CPU_TYPE:=cortex-a53
KERNELNAME:=vmlinuz.efi

define Target/Description
  Build multi-platform images for the ARMv8 instruction set architecture
endef
