#!/usr/bin/env bats

load 'helpers.bash'

# --- Test install.sh ---

@test "install.sh: shows help with -h" {
  run ../install.sh -h
  assert_success
  assert_output --partial "Usage: install.sh"
}

# --- Test uninstall.sh ---

@test "uninstall.sh: shows help with -h" {
  run ../uninstall.sh -h
  assert_success
  assert_output --partial "Usage: uninstall.sh"
}
