#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "F07 real App acceptance requires macOS" >&2
  exit 2
fi

RUNTIME_ROOT="${DSH_F07_RUNTIME_ROOT:-/private/tmp/dsh-f07-alpha5-runtime}"
APP_ROOT="${DSH_F07_APP:-/private/tmp/dsh-f07-app-derived/Build/Products/Debug/DSH.app}"
DERIVED_DATA="${DSH_F07_DERIVED_DATA:-/private/tmp/dsh-f07-app-derived}"
RUNTIME_MANIFEST="${RUNTIME_ROOT}/node_modules/@deepseek-ai/dsh/package.json"
APP_EXECUTABLE="${APP_ROOT}/Contents/MacOS/DSH"

if [ ! -f "${RUNTIME_MANIFEST}" ]; then
  echo "official alpha.5 Runtime is missing: ${RUNTIME_MANIFEST}" >&2
  echo "install it with: npm install --prefix ${RUNTIME_ROOT} --ignore-scripts --no-audit --no-fund --cache /private/tmp/dsh-m1-runtime-contract-20260903/npm-cache @deepseek-ai/dsh@0.1.2-alpha.5" >&2
  exit 2
fi

if [ "${DSH_F07_SKIP_BUILD:-0}" != "1" ]; then
  xcodebuild \
    -project "${PROJECT_DIR}/DSH.xcodeproj" \
    -scheme DSH \
    -configuration Debug \
    -sdk macosx \
    -derivedDataPath "${DERIVED_DATA}" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=DSH_TESTING \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
elif [ ! -x "${APP_EXECUTABLE}" ]; then
  echo "DSH_F07_SKIP_BUILD=1 but app executable is missing: ${APP_EXECUTABLE}" >&2
  exit 2
fi

if [ "${DSH_F07_BUILD_ONLY:-0}" = "1" ]; then
  exit 0
fi

DSH_F07_RUNTIME_ROOT="${RUNTIME_ROOT}" \
DSH_F07_APP="${APP_ROOT}" \
TMPDIR="${TMPDIR:-/private/tmp}" \
node --test "${PROJECT_DIR}/test/f07-real-app.integration.test.js"
