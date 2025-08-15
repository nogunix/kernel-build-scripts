 kernel-build-scripts

Linuxカーネルをビルド／インストールするためのシンプルなスクリプト集。

## Requirements
- Fedora（他ディストリも可）
- 必要パッケージ: gcc make ncurses-devel flex bison elfutils-libelf-devel openssl-devel bc

## Usage
```bash
# ビルド＆インストール（例）
chmod +x install.sh uninstall.sh
./install.sh  # カーネルをビルドして /boot に導入、grub 更新など
# ロールバック
./uninstall.sh