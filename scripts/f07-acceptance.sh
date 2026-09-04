#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "F07 requires macOS for the WKWebView acceptance harness" >&2
	exit 2
fi

TASK_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-f07-acceptance.XXXXXX")"
cleanup() {
	rm -rf "${TASK_TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${TASK_TMP_DIR}/dsh-home" "${TASK_TMP_DIR}/application-support" "${TASK_TMP_DIR}/tmp"

# The real-app test used to fall back to a persistent /private/tmp build and
# could therefore validate stale Swift sources. Unless a caller explicitly
# supplies an app, compile this checkout into the isolated acceptance root and
# pass that exact artifact to the full test matrix.
if [ -z "${DSH_F07_APP:-}" ]; then
	export DSH_F07_DERIVED_DATA="${TASK_TMP_DIR}/app-derived"
	export DSH_F07_APP="${DSH_F07_DERIVED_DATA}/Build/Products/Debug/DSH.app"
	DSH_F07_BUILD_ONLY=1 bash "${PROJECT_DIR}/scripts/f07-real-app.sh"
fi

echo "F07 isolated root: ${TASK_TMP_DIR}"
echo "F07 DSH_HOME: ${TASK_TMP_DIR}/dsh-home"
echo "F07 DSH_TEST_APP_SUPPORT: ${TASK_TMP_DIR}/application-support"

DSH_HOME="${TASK_TMP_DIR}/dsh-home" \
DSH_TEST_APP_SUPPORT="${TASK_TMP_DIR}/application-support" \
TMPDIR="${TASK_TMP_DIR}/tmp" \
DSH_F07_WKWEBVIEW=1 \
DSH_F07_ACCEPTANCE=1 \
node --test "${PROJECT_DIR}/test/f07-acceptance.integration.test.js"

# Run the existing F00–F06 behavior suite with the same temporary roots. The
# full suite is intentional: F07 is a release gate, so a passing isolated
# WebKit run cannot hide a regression in an earlier milestone.
DSH_HOME="${TASK_TMP_DIR}/dsh-home" \
DSH_TEST_APP_SUPPORT="${TASK_TMP_DIR}/application-support" \
TMPDIR="${TASK_TMP_DIR}/tmp" \
DSH_F07_WKWEBVIEW=1 \
DSH_F07_ACCEPTANCE=1 \
npm --prefix "${PROJECT_DIR}" test

echo "F07 acceptance passed: isolated fixture matrix, real WKWebView harness, and F00–F06 regression suite"
