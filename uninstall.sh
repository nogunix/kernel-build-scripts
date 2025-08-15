#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---
TARGET_VERSION=""     # -v で指定。未指定なら自動選択
DRY_RUN=0             # -n で有効
ASSUME_YES=0          # -y で有効
LOGFILE="uninstall_$(date +%Y%m%d_%H%M%S).log"

# --- Helpers ---
msg(){ printf "\n--> %s\n" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

usage(){
  cat <<EOF
Usage: $0 [-v VERSION] [-n] [-y]
  -v VERSION : 削除するカーネルバージョン（例: 6.16.0-rc5+）
               未指定なら uname -r 以外で最新を自動選択
  -n         : ドライラン（実際には削除しない）
  -y         : 確認をスキップして実行
EOF
}

cleanup(){
  local ec=$?
  if (( ec != 0 )); then
    echo
    echo "❌ Failed with exit code $ec. See log: $LOGFILE" >&2
  fi
}
trap cleanup EXIT

# --- Parse options ---
while getopts ":v:nyh" opt; do
  case "$opt" in
    v) TARGET_VERSION="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

# --- Sanity checks ---
if [[ "$(id -u)" -eq 0 ]]; then
  die "Do NOT run as root. sudo は内部で必要に応じて使います。"
fi

need find
need uname
need tee

# ログ
exec > >(tee -a "$LOGFILE") 2>&1

RUNNING="$(uname -r)"
ALL_VERSIONS=()
	mapfile -t ALL_VERSIONS < <(
	find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V
)

(( ${#ALL_VERSIONS[@]} )) || die "/lib/modules にカーネルが見つかりません。"

# 少なくとも2つ以上（保険）
if (( ${#ALL_VERSIONS[@]} <= 1 )); then
  die "残り1つのカーネルのみです。削除を中止します。"
fi

# 既定ブートカーネル（可能なら grubby から取得）
DEFAULT_VERSION=""
if command -v grubby >/dev/null 2>&1; then
  # 例: /boot/vmlinuz-6.16.0-rc5+ → 末尾のバージョンを抽出
  DEFAULT_KERNEL_PATH="$(grubby --default-kernel 2>/dev/null || true)"
  if [[ -n "$DEFAULT_KERNEL_PATH" ]]; then
    DEFAULT_VERSION="${DEFAULT_KERNEL_PATH##*/vmlinuz-}"
  fi
fi

# 対象決定
RECORD_FILE="/var/lib/kernel-build-scripts/last-installed"
if [[ -z "$TARGET_VERSION" && -f "$RECORD_FILE" ]]; then
  TARGET_VERSION=$(<"$RECORD_FILE")
  echo "Using recorded installed kernel version: $TARGET_VERSION"
fi

msg "削除対象: $TARGET_VERSION"
echo "走行中: $RUNNING"
echo "既定起動: ${DEFAULT_VERSION:-"(取得不可)"}"
echo "インストール済: ${ALL_VERSIONS[*]}"

# 危険防止
if [[ "$TARGET_VERSION" == "$RUNNING" ]]; then
  die "現在起動中のカーネル ($RUNNING) は削除できません。"
fi
if [[ -n "$DEFAULT_VERSION" && "$TARGET_VERSION" == "$DEFAULT_VERSION" ]]; then
  die "既定起動のカーネル ($DEFAULT_VERSION) は削除できません。先に既定を切り替えてください。"
fi

# 対象の存在確認
MODULES_DIR="/lib/modules/$TARGET_VERSION"
[[ -d "$MODULES_DIR" ]] || die "$MODULES_DIR が見つかりません。"

# Fedora/BLS 環境の検出
IS_BLS=0
if [[ -d /boot/loader/entries ]] || [[ -f /etc/kernel/install.conf ]] || command -v kernel-install >/dev/null 2>&1; then
  IS_BLS=1
fi

# ファイルパス候補
KERNEL_IMG="/boot/vmlinuz-$TARGET_VERSION"
INITRAMFS_IMG="/boot/initramfs-$TARGET_VERSION.img"
CONFIG_FILE="/boot/config-$TARGET_VERSION"
SYSTEMMAP_FILE="/boot/System.map-$TARGET_VERSION"
readarray -t LOADER_ENTRIES < <(find /boot/loader/entries/ -maxdepth 1 -type f -name "*-$TARGET_VERSION.conf" 2>/dev/null || true)

# 実行前の確認
if (( !ASSUME_YES )); then
  echo
  echo "以下を削除します（検出できたもののみ）："
  [[ -e "$KERNEL_IMG" ]] && echo "  $KERNEL_IMG"
  [[ -e "$INITRAMFS_IMG" ]] && echo "  $INITRAMFS_IMG"
  [[ -e "$CONFIG_FILE" ]] && echo "  $CONFIG_FILE"
  [[ -e "$SYSTEMMAP_FILE" ]] && echo "  $SYSTEMMAP_FILE"
  [[ ${#LOADER_ENTRIES[@]} -gt 0 ]] && printf "  %s\n" "${LOADER_ENTRIES[@]}"
  echo "  $MODULES_DIR"
  read -rp "本当に削除しますか？ [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || die "中止しました。"
fi

# --- 実処理 ---
if (( IS_BLS )) && command -v kernel-install >/dev/null 2>&1; then
  msg "BLS 環境を検出: kernel-install でエントリを削除します"
  # kernel-install は root 必須
  run sudo kernel-install remove "$TARGET_VERSION"
else
  msg "非BLS/手動モード: 直接ファイルを削除します"
  run sudo rm -f "$KERNEL_IMG" "$INITRAMFS_IMG" "$CONFIG_FILE" "$SYSTEMMAP_FILE"
  if (( ${#LOADER_ENTRIES[@]} )); then
    run sudo rm -f "${LOADER_ENTRIES[@]}"
  fi

  # GRUB再生成（自動検出）
  if command -v grub2-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub2 ]]; then
    msg "Updating GRUB (grub2-mkconfig)"
    run sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  elif command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
    msg "Updating GRUB (grub-mkconfig)"
    run sudo grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo "Note: GRUBの自動更新は実行されませんでした。必要なら手動で更新してください。"
  fi
fi

# モジュールを最後に削除（依存ファイルが残っても参照されないように順序を考慮）
msg "Deleting modules directory: $MODULES_DIR"
run sudo rm -rf "$MODULES_DIR"

echo
echo "✅ カーネル $TARGET_VERSION のアンインストールが完了しました。"
echo "ログ: $LOGFILE"
