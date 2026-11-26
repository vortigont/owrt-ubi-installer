## An OpenWrt All-UBI layout Installer Image Generator

Supported models:

 - Elecom WRC-X6000QS [device page](https://openwrt.org/toh/elecom/wrc-x6000qs)
 - CreatLentem CLT-R30B1

Scripts here are based on [andros-ua/owrt-ubi-installer](https://github.com/andros-ua/owrt-ubi-installer).

> [!WARNING]
> This will replace the bootloader (TF-A 2.13, U-Boot 2025.10) and convert the flash layout of the device to an all-in-UBI layout. The installer stores a copy of the previous bootchain in a dedicated UBI volume `boot_backup`.

> [!CAUTION]
>Re-flashing the installer when the device is already using UBI flash layout will erase the previously backed up bootchain, which in most cases would be the vendor/official one.

If you plan to ever go back to the stock firmware, you will need a backup of the vendor bootchain and firmware.

> [!CAUTION]
> The installer is meant to be executed only __once__ per device.

## Table of Contents
* [Script information](#script-information)
* [Building image for Elecom WRC-x6000qs](#building-image-for-elecom-wrc-x6000qs)
* [Installing OpenWrt](#installing-openwrt)
* [Enter recovery mode under OpenWrt](#enter-recovery-mode-under-openwrt)


## Script information

This script downloads the OpenWrt ImageBuilder to generate a firmware upgrade image compatible with the stock firmware which will automatically carry out the installation. The process involves re-packaging the *initramfs* image to contain everything necessary for a permanent installation of a replacement Das U-Boot bootloader, ARM TrustedFirmware-A and an OpenWrt recovery (initramfs) image within the NAND flash, plus the installer script itself.

You'll need the below to use the script to generate the installer image:
* All [prerequisites of the OpenWrt ImageBuilder](https://openwrt.org/docs/guide-user/additional-software/imagebuilder#prerequisites) 
* `libfdt-dev`
* `cmake`
* `zstd`


## Building image for Elecom WRC-x6000qs

OpenWrt support for Elecom WRC-x6000qs is not yet present for major releases, only [snapshot](https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/) builds are available.

**If you are not interested in building yourself**, the pre-built files are available [here](https://github.com/vortigont/owrt-ubi-installer/releases). Download it to your PC and proceed with [Installing OpenWrt](#installing-openwrt).

You'd have to build `imagebuilder` yourself using patches from https://github.com/vortigont/openwrt/tree/elecom_wrc-x6000qs_ubi
Build the snapshot image for Elecom WRC-x6000qs as per OpenWrt build instructions. You'd have to set a web server to provide packages
download URL for builder script to fetch required pkgs to embed into installer image.

A sample config for snapshot build:

```
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_elecom_wrc-x6000qs-ubi=y
CONFIG_IB=y
CONFIG_IB_ONLY_SELECTED_DEVICES=y
CONFIG_PACKAGE_u-boot-mt7981_keenetic_kn-1012=y
# CONFIG_IB_STANDALONE is not set
CONFIG_PACKAGE_luci-mod-admin-full=y
CONFIG_PACKAGE_luci-theme-bootstrap=y
CONFIG_PACKAGE_uhttpd=y
```

Run builder script, supply path to your build dir, e.g.
```sh
./build_installer.sh -r elecom_wrc-x6000qs --img-url ~/owrt_trunk/bin/targets/mediatek/filogic --pkg-url http://localhost/your_pkg_repo
```

script should generate the following files:
```
openwrt-mediatek-filogic-elecom_wrc-x6000qs-ubi-initramfs-recovery-installer.itb
openwrt-mediatek-filogic-elecom_wrc-x6000qs-ubi-initramfs-recovery.itb
openwrt-mediatek-filogic-elecom_wrc-x6000qs-ubi-squashfs-sysupgrade.itb
```


## Installing OpenWrt all-in-UBI

1. Ensure your router is running the latest generic OpenWrt firmware. Upgrade it if necessary.

2. Assign IP 192.168.1.254/24 to your computer's Ethernet port

3. Connect Ethernet to the 1GE LAN port

4. Upload `openwrt-mediatek-filogic-elecom_wrc-x6000qs-ubi-initramfs-recovery-installer.itb` to `/tmp/` with an `scp -O` command

5. Flash `openwrt-mediatek-filogic-elecom_wrc-x6000qs-ubi-initramfs-recovery-installer.itb` via `sysupgrade -F` command.

6. Once OpenWrt initramfs system comes up, do flash sysupgrade image using
   `openwrt-mediatek-filogic-elecom_wrc-x6000qs-ubi-squashfs-sysupgrade.itb`

## Backup stock/vendor bootchain

Connect to the device via SSH and enter the following command:

```shell
cat /dev/ubi0_6 > /tmp/boot_backup.tar
```

Then, copy `/tmp/boot_backup.tar` archive using *scp* to your computer. These files are needed in case you want to restore the original/vendor firmware. They can also be used in emergency case for reflashing via [UART].


## Enter recovery mode under OpenWrt


#### Using the RESET button:

1. Hold down the "reset" button whilst powering on the device.

2. Release the button once the status LED turns into red.

This will remove any user configuration and allow restoring or upgrading from [ssh](https://openwrt.org/docs/guide-user/installation/sysupgrade.cli)/http/[tftp](https://openwrt.org/docs/guide-user/installation/generic.flashing.tftp).

#### Using PSTORE/ramoops

1. While running the production firmware enter this command in the shell

   ```shell
   echo c > /proc/sysrq-trigger
   ```

2. Once the router has rebooted into recovery mode, clear PSTORE to make it reboot into production mode again:

   ```shell
   rm /sys/fs/pstore/*
   ```

This keep user configuration but still allow restoring or upgrading from [ssh](https://openwrt.org/docs/guide-user/installation/sysupgrade.cli)/http/[tftp](https://openwrt.org/docs/guide-user/installation/generic.flashing.tftp).
