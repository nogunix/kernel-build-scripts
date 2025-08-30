#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---
KERNEL_SRC_DIR="linux"
BRANCH_OR_TAG="master"       # Default for torvalds/linux
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
DO_INSTALL=1                 # 0 for build only
UPDATE_GRUB=0                # Usually not needed for Fedora+BLS. Use -g if required.
USE_LOCALMODCONFIG=0         # Enable with -L
LOGFILE="build_$(date +%Y%m%d_%H%M%S).log"

# Extra make variables
WARN_LEVEL=""               # -W <level> -> make W=<level>
PARTIAL_M=""                # -M <path>  -> make M=<path>
OUT_DIR=""                  # -O <dir>   -> make O=<dir>

SUDO_KEEPALIVE_PID=""        # PID of the sudo keep-alive process

# Destination for staging modules as non-root
STAGING_DIR="${STAGING_DIR:-$PWD/_staging}"  # Relative paths are OK. Can be overridden by environment variable before -d changes.

# --- Helpers ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [-j N] [-d DIR] [-b BRANCH|TAG] [-n] [-g] [-L] [-W N] [-M PATH] [-O DIR]
  -j N   : make -jN (default: $(nproc) or $MAKE_JOBS)
  -d DIR : Kernel source directory (default: linux)
  -b REF : Branch/tag to checkout (default: master)
  -n     : Do not install (build only)
  -g     : Update GRUB configuration (usually not needed for Fedora)
  -L     : Use make localmodconfig (optimizes for running modules)
  -W N   : Warning level for kernel build (passes make W=N)
  -M PATH: Partial build target path (in-tree), passes make M=PATH and builds modules only
  -O DIR : Out-of-tree build directory (passes make O=DIR). Used for all make invocations
Environment variables:
  STAGING_DIR : INSTALL_MOD_PATH for modules_install (default: $PWD/_staging)
EOF
}

msg()  { printf "\n--> %s\n" "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

cleanup() {
  local ec=$?
  # PID of the sudo keep-alive process
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    # Background jobs are killed when the shell exits, but explicitly stop for safety
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  if (( ec != 0 )); then
    echo
    echo "❌ Failed with exit code $ec. See log: $LOGFILE" >&2
  fi
}
trap cleanup EXIT

# --- Parse options ---
while getopts ":j:d:b:ngLW:M:O:h" opt; do
  case "$opt" in
    j) MAKE_JOBS="$OPTARG" ;;
    d) KERNEL_SRC_DIR="$OPTARG" ;;
    b) BRANCH_OR_TAG="$OPTARG" ;;
    n) DO_INSTALL=0 ;;
    g) UPDATE_GRUB=1 ;;
    L) USE_LOCALMODCONFIG=1 ;;
    W) WARN_LEVEL="$OPTARG" ;;
    M) PARTIAL_M="$OPTARG" ;;
    O) OUT_DIR="$OPTARG" ;;
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
  # Prevent sudo timeout during script execution
  # Ask for password initially, then keep updating timestamp in background
  msg "Updating sudo authentication to prevent timeout..."
  sudo -v
  ( while true; do sleep 60; sudo -n true; done ) &
  SUDO_KEEPALIVE_PID=$! 
fi

need git; need make; need tee; need rsync; need ccache

# Log both to console and file
exec > >(tee -a "$LOGFILE") 2>&1

START_TIME=$(date +%s)
echo "===== Kernel Build Started: $(date) ====="
echo "Dir=${KERNEL_SRC_DIR}  Ref=${BRANCH_OR_TAG}  -j${MAKE_JOBS}"
echo "Install=${DO_INSTALL}  UpdateGRUB=${UPDATE_GRUB}  localmodconfig=${USE_LOCALMODCONFIG}"
echo "StagingDir=${STAGING_DIR}  W=${WARN_LEVEL:-""}  M=${PARTIAL_M:-""}  O=${OUT_DIR:-""}"

# --- Step 1: Dependencies (Fedora only) ---
msg "Checking/Installing build dependencies (Fedora only)"
need dnf
${SUDO} dnf -y builddep kernel
${SUDO} dnf -y install make gcc flex bison openssl-devel elfutils-libelf-devel ncurses-devel bc dwarves

# --- Step 2: Clone or update source ---
msg "Cloning/Updating Linux source"
if [[ ! -d "$KERNEL_SRC_DIR/.git" ]]; then
  git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KERNEL_SRC_DIR"
fi

cd "$KERNEL_SRC_DIR"
git fetch --tags origin
git checkout -f "$BRANCH_OR_TAG" || die "Cannot checkout $BRANCH_OR_TAG"
# If it's a branch, perform a fast-forward update
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "HEAD" ]]; then
  git pull --ff-only || die "git pull failed (non-ff?)"
fi

# --- Step 3: Configure ---
msg "Configuring the kernel"
# Prepare common make variables
MAKE_VARS_COMMON=()
if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  MAKE_VARS_COMMON+=("O=$OUT_DIR")
fi
if [[ -n "$WARN_LEVEL" ]]; then
  MAKE_VARS_COMMON+=("W=$WARN_LEVEL")
fi

if [[ -f "/boot/config-$(uname -r)" ]]; then
  echo "Copying running kernel config"
  if [[ -n "$OUT_DIR" ]]; then
    cp "/boot/config-$(uname -r)" "$OUT_DIR/.config"
  else
    cp "/boot/config-$(uname -r)" .config
  fi
else
  echo "No running config found; using defconfig"
  make ${MAKE_VARS_COMMON[@]} defconfig
fi

if (( USE_LOCALMODCONFIG )); then
  echo "Optimizing with localmodconfig"
  yes "" | make ${MAKE_VARS_COMMON[@]} localmodconfig
else
  echo "Updating .config with olddefconfig"
  make ${MAKE_VARS_COMMON[@]} olddefconfig
fi

# --- Step 4: Build (non-root, signs modules here if enabled) ---
msg "Building the kernel (this may take a while)"
export CC="ccache gcc"
export CXX="ccache g++"
# Build vars (include M only for the build step)
MAKE_VARS_BUILD=("${MAKE_VARS_COMMON[@]}")
if [[ -n "$PARTIAL_M" ]]; then
  MAKE_VARS_BUILD+=("M=$PARTIAL_M")
fi

if [[ -n "$PARTIAL_M" ]]; then
  make -j"${MAKE_JOBS}" ${MAKE_VARS_BUILD[@]} modules
else
  make -j"${MAKE_JOBS}" ${MAKE_VARS_BUILD[@]}
fi

# --- Step 5: Install (Stage as non-root -> Sync as root) ---
if (( DO_INSTALL )); then
  msg "Staging modules to INSTALL_MOD_PATH (non-root)"
  # Example: Placed under ${SRC}/_staging/lib/modules/<version>
  rm -rf -- "${STAGING_DIR}"
  mkdir -p "${STAGING_DIR}"
  make ${MAKE_VARS_COMMON[@]} modules_install INSTALL_MOD_PATH="${STAGING_DIR}"

  # Identify the target version for installation (obtained from staging)
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
  # Fedora uses kernel-install. Root is fine here.
  sudo make ${MAKE_VARS_COMMON[@]} install

  # Record directory
  RECORD_DIR="/var/lib/kernel-build-scripts"
  RECORD_FILE="$RECORD_DIR/last-installed"

  # Get the most recently updated one under /lib/modules
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
  # Fedora has BLS enabled by default. Usually not needed, but performed only if explicitly requested.
  ${SUDO} grub2-mkconfig -o /boot/grub2/grub.cfg || true
else
  msg "Skipping GRUB update"
fi


END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo
echo "✅ Done. Total elapsed: ${ELAPSED}s (~$((ELAPSED/60)) min). Log: $LOGFILE"
echo "===== Kernel Build Finished: $(date) ====="
