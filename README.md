[![Last Commit](https://img.shields.io/github/last-commit/nogunix/kernel-build-scripts/main.svg)](https://github.com/nogunix/kernel-build-scripts/commits/main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# kernel-build-scripts

A collection of scripts for easily and safely building, installing, and uninstalling the Linux kernel.
It is intended for use in Fedora environments, but can also be used in other distributions by installing the necessary dependencies.

## Structure

| File            | Role                                                              |
| --------------- | ----------------------------------------------------------------- |
| **install.sh**  | Acquires, configures, builds, and installs the kernel             |
| **uninstall.sh**| Safely removes unnecessary kernels (prioritizes the most recently installed one) |


## install.sh

### Key Features
- Obtains the Linux kernel from the official `kernel.org` repository
- Applies `make olddefconfig` or `localmodconfig` based on the current kernel configuration
- Supports parallel builds (`-jN`)
- Records the version of the most recently installed kernel after installation
  `/var/lib/kernel-build-scripts/last-installed`

### Options

| Option     | Description                                     | Example        |
| ---------- | ----------------------------------------------- | -------------- |
| `-j N`     | Specifies the number of parallel builds (default: CPU cores) | `-j 8`         |
| `-d DIR`   | Specifies the kernel source directory (default: linux) | `-d linux-src` |
| `-b REF`   | Branch/tag to checkout                          | `-b v6.11-rc1` |
| `-n`       | Build only (no installation)                    | `-n`           |
| `-g`       | Update GRUB configuration (usually not needed for Fedora) | `-g`           |
| `-L`       | Use `make localmodconfig` (optimizes for currently running modules) | `-L`           |

### Examples
```bash
# Build and install using current configuration
./install.sh

# Optimize configuration for currently running modules
./install.sh -L

# Specify branch/tag
./install.sh -b v6.11-rc1

# Build only, no installation
./install.sh -n
````


## uninstall.sh

### Key Features

* Automatically determines the target for deletion based on the record file `/var/lib/kernel-build-scripts/last-installed`
* Prohibits deletion of the currently running kernel or the default boot kernel
* In Fedora/BLS environments, uses `kernel-install remove` for safe deletion
* In non-BLS environments, manually deletes files and executes `grub-mkconfig` / `grub2-mkconfig`
* Supports dry run (`-n`) and automatic Yes (`-y`)

### Options

| Option        | Description                                     | Example          |
| ------------- | ----------------------------------------------- | ---------------- |
| `-v VERSION`  | Specifies the kernel version to delete          | `-v 6.16.0-rc5+` |
| `-n`          | Dry run (shows steps without actual deletion)   | `-n`             |
| `-y`          | Executes deletion without confirmation          | `-y`             |

### Examples

```bash
# Delete the most recently recorded installed kernel
./uninstall.sh

# Delete a specific version
./uninstall.sh -v 6.16.0-rc5+

# Delete without confirmation
./uninstall.sh -y

# Dry run
./uninstall.sh -n
```


## Caution

* You can run as root, but if you are a non-root user, `sudo` will be called internally as needed.
* Building and deleting kernels can significantly impact your system, so always back up important data before proceeding.


## License

MIT License - see the [LICENSE](LICENSE) file for details.


This is my personal project. It is created and maintained in my personal capacity, and has no relation to my employer's business or confidential information.