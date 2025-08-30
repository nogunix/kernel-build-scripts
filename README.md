[![Last Commit](https://img.shields.io/github/last-commit/nogunix/kernel-build-scripts/main.svg)](https://github.com/nogunix/kernel-build-scripts/commits/main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bats Tests](https://github.com/nogunix/kernel-build-scripts/actions/workflows/bats-tests.yml/badge.svg)](https://github.com/nogunix/kernel-build-scripts/actions/workflows/bats-tests.yml)
[![ShellCheck](https://github.com/nogunix/kernel-build-scripts/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/nogunix/kernel-build-scripts/actions/workflows/shellcheck.yml)

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
| `-W N`     | Kernel build warning level (passes `make W=N`)           | `-W 1`         |
| `-M PATH`  | Partial in-tree module build path (passes `make M=PATH`) | `-M drivers/staging/xxx` |
| `-O DIR`   | Out-of-tree build directory (passes `make O=DIR`)        | `-O build`     |

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

# Partial module build with custom warning level and out-dir
./install.sh -W 1 -M drivers/staging/xxx -O build -n
````

### Practice: Fix W=1 warnings in drivers/staging and create a patch

Use this script to iterate on `drivers/staging/*` with `W=1` warnings and prepare patches.

#### Quick command

```bash
./install.sh -n -W 1 -M drivers/staging/xxx -O build
```

- `-n`: build only (no install)
- `-W 1`: enable kernel warning level 1
- `-M drivers/staging/xxx`: partial in-tree module build target
- `-O build`: out-of-tree build directory (puts `.config` in `build/`)

On first run, the script fetches sources, copies the running kernel config to `build/.config`, and runs `olddefconfig` (or `localmodconfig` if `-L`). Subsequent runs only rebuild changes.

#### Iteration workflow

1) Build and list warnings

```bash
./install.sh -n -W 1 -M drivers/staging/xxx -O build
```

2) Fix sources based on warnings (e.g., make functions `static`, correct `printf` formats, remove unused variables)

3) Rebuild quickly with the same command to verify fixes

4) Style checks with `checkpatch.pl`

```bash
linux/scripts/checkpatch.pl --strict -f drivers/staging/xxx/target.c
```

5) Optional: Sparse analysis

```bash
make -C linux O=build M=drivers/staging/xxx C=1 W=1 modules
```

Common W=1 fixes:
- Unused variables/functions: remove, or mark with `__maybe_unused`; make internal functions `static`
- printk to pr_*: use `pr_err/pr_warn/pr_info` and correct format specifiers (e.g. `%zu` for `size_t`)
- Types/casts: fix explicit casts and use proper helpers/APIs
- Kernel-doc/comments: keep `/** ... */` in sync with function signatures
- Whitespace/style: follow `scripts/checkpatch.pl` guidance

#### Create a patch

From the `linux/` source directory:

```bash
cd linux
git checkout -b staging-w1-xxx-fixes
git add -p
git commit -s -m "staging: xxx: fix W=1 warnings in foo.c"
git format-patch -1 -o ../out/patches
linux/scripts/get_maintainer.pl -f drivers/staging/xxx/*
```

Helpful extras:

```bash
# Clean partial build when needed
make -C linux O=build M=drivers/staging/xxx clean

# Try stricter levels later
./install.sh -n -W 2 -M drivers/staging/xxx -O build
```

Note: For real submissions, follow the staging tree’s guidelines and send patches to the maintainers listed by `get_maintainer.pl`.


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
