#!/bin/bash
set -euo pipefail

#TARGET_VERSION=$(ls -d /lib/modules/* | grep -v "$(uname -r)" | sort -r | head -n 1 | xargs basename)
TARGET_VERSION="6.16.0-rc5+"

if [ -z "$TARGET_VERSION" ]; then
  echo "❌ 削除対象のカーネルが見つかりません。現在起動中のカーネルは削除できません。"
  exit 1
fi

#ALL_KERNELS=($(ls -d /lib/modules/* | xargs -n1 basename))
#if [ "${#ALL_KERNELS[@]}" -le 1 ]; then
#  echo "⚠️ 残り1つのカーネルのみです。削除を中止します。"
#  exit 1
#fi

echo "🗑️  カーネルバージョン $TARGET_VERSION をアンインストールします..."

# 削除対象のファイルパス
KERNEL_IMG="/boot/vmlinuz-$TARGET_VERSION"
INITRAMFS_IMG="/boot/initramfs-$TARGET_VERSION.img"
CONFIG_FILE="/boot/config-$TARGET_VERSION"
SYSTEMMAP_FILE="/boot/System.map-$TARGET_VERSION"
MODULES_DIR="/lib/modules/$TARGET_VERSION"
LOADER_ENTRY_CONF=$(find /boot/loader/entries/ -name "*-$TARGET_VERSION.conf" 2>/dev/null)

# ファイル削除
sudo rm -f "$KERNEL_IMG" "$INITRAMFS_IMG" "$CONFIG_FILE" "$SYSTEMMAP_FILE" "$LOADER_ENTRY_CONF"
sudo rm -rf "$MODULES_DIR"

# Update GRUB configuration (for both EFI/BIOS)
echo "Updating GRUB configuration..."
# On some Fedora systems, /boot/grub2/grub.cfg is used for both BIOS and UEFI.
# The file at /boot/efi/EFI/fedora/grub.cfg can be a wrapper that should not be overwritten.
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

echo "✅ カーネル $TARGET_VERSION のアンインストールが完了しました。"
