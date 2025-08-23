#!/usr/bin/env bash

# Load support libraries. The 'load' command resolves paths relative to
# the directory of the file where it is used. This file is in 'test/',
# so the paths to the submodules should be relative to 'test/'.
load 'bats-support/load.bash'
load 'bats-assert/load.bash'