#!/bin/bash
set -euo pipefail # Exit on error, unset var, or pipe failure

# --- Configuration ---
# Directory where the kernel source will be cloned
KERNEL_SRC_DIR="linux"
# Number of parallel jobs for make. Defaults to number of CPU cores.
# Override with: export MAKE_JOBS=4; ./build.sh
: "${MAKE_JOBS:=$(nproc)}"
# ---

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
   echo "This script should not be run as root. Use sudo when needed." >&2
   exit 1
fi

LOGFILE="build_$(date +%Y%m%d_%H%M%S).log"
# Redirect stdout and stderr to both console and log file
exec > >(tee -a "$LOGFILE") 2>&1

START_TIME=$(date +%s)

echo "===== Kernel Build Started: $(date) ====="
echo "Using ${MAKE_JOBS} parallel jobs for make."

echo
echo "--> Step 1: Installing build dependencies..."
# Install kernel build dependencies
sudo dnf builddep -y kernel

echo
echo "--> Step 2: Cloning/Updating Linux kernel source..."
# Clone kernel source from the canonical repository
if [ ! -d "$KERNEL_SRC_DIR" ]; then
  # Using the canonical kernel.org git repository
  git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KERNEL_SRC_DIR"
else
  echo "'$KERNEL_SRC_DIR' directory already exists. Fetching latest changes..."
  (cd "$KERNEL_SRC_DIR" && git pull)
fi
cd "$KERNEL_SRC_DIR"

echo
echo "--> Step 3: Configuring the kernel..."
# Copy the current kernel configuration
echo "Copying config from running kernel: /boot/config-$(uname -r)"
cp "/boot/config-$(uname -r)" .config

# Update the configuration with default values for new options
echo "Updating .config with 'make olddefconfig'..."
make olddefconfig

echo
echo "--> Step 4: Building the kernel (this will take a while)..."
# Build the kernel using a configurable number of parallel jobs
make -j"${MAKE_JOBS}"

echo
echo "--> Step 5: Installing kernel and modules..."
echo "Installing kernel modules..."
sudo make modules_install

# Install the kernel itself
echo "Installing kernel..."
sudo make install
# Note: On modern Fedora, 'make install' automatically runs kernel-install,
# which creates bootloader entries. The explicit grub2-mkconfig below is
# often redundant but acts as a safeguard.

echo
echo "--> Step 6: Updating GRUB configuration..."
# On some Fedora systems, /boot/grub2/grub.cfg is used for both BIOS and UEFI.
# The file at /boot/efi/EFI/fedora/grub.cfg can be a wrapper that should not be overwritten.
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

echo
echo "✅ Kernel build and installation complete."
echo "Please reboot your system to use the new kernel."

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo
echo "Total elapsed time: ${ELAPSED} seconds ($((${ELAPSED}/60)) minutes)."
echo "===== Kernel Build Finished: $(date) ====="
