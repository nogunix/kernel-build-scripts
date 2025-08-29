#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---
KERNEL_SRC_DIR="linux"
BRANCH_OR_TAG="master"       # torvalds/linux の既定
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
DO_INSTALL=1                 # 0 で build のみ
UPDATE_GRUB=0                # Fedora+BLSは通常不要。必要なら -g
USE_LOCALMODCONFIG=0         # 有効なら -L
LOGFILE="build_$(date +%Y%m%d_%H%M%S).log"

SUDO_KEEPALIVE_PID=""        # sudo keep-alive プロセスのPID

# 非rootでmodulesをステージする先
STAGING_DIR="${STAGING_DIR:-$PWD/_staging}"  # 相対OK。-d 変更前に使うので環境変数でも上書き可。

# --- Helpers ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [-j N] [-d DIR] [-b BRANCH|TAG] [-n] [-g] [-L]
  -j N   : make -jN（既定: $(nproc) or \$MAKE_JOBS)
  -d DIR : カーネルソースディレクトリ（既定: linux）
  -b REF : チェックアウトするブランチ/タグ（既定: master）
  -n     : インストールを行わない（buildのみ）
  -g     : GRUB設定を更新する（通常Fedoraでは不要）
  -L     : make localmodconfig を使う（稼働中モジュールに最適化）
環境変数:
  STAGING_DIR : modules_install の INSTALL_MOD_PATH（既定: \$PWD/_staging）
EOF
}

msg()  { printf "\n--> %s\n" "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

cleanup() {
  local ec=$?
  # sudo keep-alive プロセスを停止
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    # シェルが終了する際にバックグラウンドジョブもkillされるが、念のため明示的に停止
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  if (( ec != 0 )); then
    echo
    echo "❌ Failed with exit code $ec. See log: $LOGFILE" >&2
  fi
}
trap cleanup EXIT

# --- Parse options ---
while getopts ":j:d:b:ngLh" opt; do
  case "$opt" in
    j) MAKE_JOBS="$OPTARG" ;;
    d) KERNEL_SRC_DIR="$OPTARG" ;;
    b) BRANCH_OR_TAG="$OPTARG" ;;
    n) DO_INSTALL=0 ;;
    g) UPDATE_GRUB=1 ;;
    L) USE_LOCALMODCONFIG=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

# --- Sanity checks ---
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
  need sudo
  # スクリプト実行中にsudoのタイムアウトを防ぐ
  # 最初にパスワードを尋ね、バックグラウンドでタイムスタンプを更新し続ける
  msg "sudo のタイムアウトを回避するため、認証を更新します..."
  sudo -v
  ( while true; do sleep 60; sudo -n true; done ) &
  SUDO_KEEPALIVE_PID=$!
fi

need git; need make; need tee; need rsync

# Log both to console and file
exec > >(tee -a "$LOGFILE") 2>&1

START_TIME=$(date +%s)
echo "===== Kernel Build Started: $(date) ====="
echo "Dir=${KERNEL_SRC_DIR}  Ref=${BRANCH_OR_TAG}  -j${MAKE_JOBS}"
echo "Install=${DO_INSTALL}  UpdateGRUB=${UPDATE_GRUB}  localmodconfig=${USE_LOCALMODCONFIG}"
echo "StagingDir=${STAGING_DIR}"

# --- Step 1: Dependencies (Fedora only) ---
msg "Checking/Installing build dependencies (Fedora only)"
if [[ -f /etc/fedora-release ]]; then
  need dnf
  ${SUDO} dnf -y builddep kernel
  ${SUDO} dnf install -y git-email patch ctags cscope sparse coccinelle \
    gcc clang llvm make bc ncurses-devel openssl-devel dwarves \
    perl-Email-Address perl-TermReadKey
else
  echo "Note: Non-Fedora detected. Ensure build deps (gcc, make, ncurses-devel, flex, bison, elfutils-libelf-devel, openssl-devel, bc, dwarves, etc.)"
fi

# --- Step 2: Clone or update source ---
msg "Cloning/Updating Linux source"
if [[ ! -d "$KERNEL_SRC_DIR/.git" ]]; then
  git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KERNEL_SRC_DIR"
fi

cd "$KERNEL_SRC_DIR"
git fetch --tags origin
git checkout -f "$BRANCH_OR_TAG" || die "Cannot checkout $BRANCH_OR_TAG"
# ブランチなら fast-forward 更新
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "HEAD" ]]; then
  git pull --ff-only || die "git pull failed (non-ff?)"
fi

# --- Step 3: Configure ---
msg "Configuring the kernel"
if [[ -f "/boot/config-$(uname -r)" ]]; then
  echo "Copying running kernel config"
  cp "/boot/config-$(uname -r)" .config
else
  echo "No running config found; using defconfig"
  make defconfig
fi

if (( USE_LOCALMODCONFIG )); then
  echo "Optimizing with localmodconfig"
  yes "" | make localmodconfig
else
  echo "Updating .config with olddefconfig"
  make olddefconfig
fi

# --- Step 4: Build (non-root, signs modules here if enabled) ---
msg "Building the kernel (this may take a while)"
make -j"${MAKE_JOBS}"

# --- Step 5: Install (非rootでステージ → rootで同期) ---
if (( DO_INSTALL )); then
  msg "Staging modules to INSTALL_MOD_PATH (non-root)"
  # 例: ${SRC}/_staging/lib/modules/<version> 配下に配置される
  rm -rf -- "${STAGING_DIR}"
  mkdir -p "${STAGING_DIR}"
  make modules_install INSTALL_MOD_PATH="${STAGING_DIR}"

  # インストール対象のバージョン特定（ステージングから取得）
  STAGED_VERSION="$(
    find "${STAGING_DIR}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | head -n1
  )"
  [[ -n "${STAGED_VERSION:-}" ]] || die "Failed to detect staged modules version"
  echo "Staged modules version: ${STAGED_VERSION}"

  msg "Syncing staged modules into /lib/modules (root only for this step)"
  sudo rsync -a "${STAGING_DIR}/lib/modules/${STAGED_VERSION}/" "/lib/modules/${STAGED_VERSION}/"

  msg "Running depmod for ${STAGED_VERSION}"
  sudo depmod -a "${STAGED_VERSION}"

  msg "Installing kernel image & BLS entries (root)"
  # Fedora系は kernel-install 経由。ここはrootでOK
  sudo make install

  # 記録ディレクトリ
  RECORD_DIR="/var/lib/kernel-build-scripts"
  RECORD_FILE="$RECORD_DIR/last-installed"

  # /lib/modules 配下で最終更新が新しいものを1つ取得
  INSTALLED_VERSION="$(
    find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' \
      | sort -nr | awk 'NR==1{print $2}'
  )"

  echo "Recording installed kernel version: $INSTALLED_VERSION"
  ${SUDO} mkdir -p "$RECORD_DIR"
  echo "$INSTALLED_VERSION" | ${SUDO} tee "$RECORD_FILE" >/dev/null
else
  msg "Skipping install (-n specified)"
fi

# --- Step 6: GRUB update (optional) ---
if (( DO_INSTALL && UPDATE_GRUB )); then
  msg "Updating GRUB config"
  if [[ -f /etc/fedora-release ]]; then
    # FedoraはBLS有効が既定。通常は不要だが、明示要求時のみ実施。
    ${SUDO} grub2-mkconfig -o /boot/grub2/grub.cfg || true
  else
    if [[ -d /boot/grub ]]; then
      ${SUDO} grub-mkconfig -o /boot/grub/grub.cfg
    elif [[ -d /boot/grub2 ]]; then
      ${SUDO} grub2-mkconfig -o /boot/grub2/grub.cfg
    else
      echo "GRUB directory not found; skip."
    fi
  fi
else
  msg "Skipping GRUB update"
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo
echo "✅ Done. Total elapsed: ${ELAPSED}s (~$((ELAPSED/60)) min). Log: $LOGFILE"
echo "===== Kernel Build Finished: $(date) ====="
