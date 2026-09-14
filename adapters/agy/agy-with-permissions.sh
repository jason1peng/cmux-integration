#!/usr/bin/env bash
# agy-with-permissions.sh - portable launcher template for the agy executor profile.
# Copy to the machine-local path `~/bin/agy-with-permissions` and review before use.
#
# This wrapper launches the agy interactive CLI in its explicit dangerous
# permission mode. That mode removes OS-level confirmation prompts for tools
# that target the approved workspace. It does NOT authorize content decisions:
# a job must still stop at `<!-- NEED_APPROVAL -->` before a consequential,
# irreversible, spending, destructive, ambiguous, or scope-expanding action.
#
# This is the same permission contract the profile declares
# (`launch.permission_mode: wrapper-declared-dangerous`, `dangerous: true`).
# It is the only place the dangerous flag appears; the supervisor never adds
# `--force` or `--yolo`, and the wrapper must not either.
set -euo pipefail

exec agy --dangerously-skip-permissions "$@"