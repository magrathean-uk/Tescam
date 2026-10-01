#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"

resolve_build_env() {
  if [[ -n "${TESCAM_BUILD_ENV:-}" ]]; then
    if [[ -f "$TESCAM_BUILD_ENV" ]]; then
      printf '%s\n' "$TESCAM_BUILD_ENV"
      return 0
    fi
    echo "TESCAM_BUILD_ENV is set but does not exist: $TESCAM_BUILD_ENV" >&2
    return 1
  fi

  local default_env="${BOLYKI_SOURCE_ROOT:-$HOME/dev/source}/build-env.sh"
  if [[ -f "$default_env" ]]; then
    printf '%s\n' "$default_env"
    return 0
  fi

  cat >&2 <<EOM
Missing build environment script.
Set TESCAM_BUILD_ENV to a valid build-env.sh, or create $default_env.
EOM
  return 1
}

BUILD_ENV_SCRIPT="$(resolve_build_env)"
# shellcheck disable=SC1090
source "$BUILD_ENV_SCRIPT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild was not found. Run this script on macOS with Xcode command line tools installed." >&2
  exit 1
fi

if [[ -z "${TESCAM_DERIVED_DATA:-}" && -z "${XCODE_DERIVED_DATA_PATH:-}" ]]; then
  echo "XCODE_DERIVED_DATA_PATH is not set. Load the routed environment (source ~/dev/env.zsh) or point TESCAM_BUILD_ENV at a build-env.sh that sets it." >&2
  exit 1
fi

DERIVED_DATA="${TESCAM_DERIVED_DATA:-$XCODE_DERIVED_DATA_PATH/Tescam-tests}"

xcodebuild \
  -project Tescam.xcodeproj \
  -scheme Tescam \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  build-for-testing

xcodebuild \
  -project Tescam.xcodeproj \
  -scheme Tescam \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:TescamTests \
  test-without-building

xcodebuild \
  -project Tescam.xcodeproj \
  -scheme Tescam \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:TescamUITests \
  test-without-building
