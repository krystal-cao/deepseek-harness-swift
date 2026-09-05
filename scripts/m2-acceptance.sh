#!/usr/bin/env bash
set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH= cd -- "$script_directory/.." && pwd)

acceptance_tests=(
  # P01/P02: transaction, real fake-pnpm product chain, UI contract and gates.
  test/swift-plugin-operation.integration.test.js
  test/swift-plugin-product-chain.integration.test.js
  test/swift-plugin-manager-safety.test.js
  test/swift-plugin-ui-progress.test.js

  # P03: resolver attribution and recovery UI/manager evidence.
  test/swift-plugin-failure-resolver.integration.test.js
  test/swift-recovery.integration.test.js
  test/swift-recovery-profile.integration.test.js

  # B01/D01: native bridge identity boundaries and diagnostic product entry.
  test/swift-bridge-diagnostic.integration.test.js
  test/swift-bridge-wiring.test.js
  test/swift-diagnostic-export-product.integration.test.js
  test/swift-diagnostic-store.integration.test.js

  # Runtime/Profile regressions that protect the M2 transaction boundary.
  test/swift-launch-context.integration.test.js
  test/swift-runtime-transaction.integration.test.js
  test/swift-runtime-update.test.js
  test/swift-web-profile-snapshot.integration.test.js
)

if [[ ${1:-} == "--list" || ${1:-} == "--dry-run" ]]; then
  printf '%s\n' "M2 acceptance test plan (isolated, no personal Profile):"
  printf '  %s\n' "${acceptance_tests[@]}"
  printf '%s\n' "Real GUI/WKWebView automation: NOT RUN by default (set DSH_M2_RUN_GUI=1 explicitly)."
  exit 0
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/dsh-m2-acceptance.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM

# Every DSH_TESTING harness receives an explicit isolated root. The product
# chain also installs fake pnpm beside its temporary harness executable, so
# no real pnpm store, registry or user Profile is consulted.
export DSH_HOME="$temporary_root/dsh-home"
export DSH_TEST_APP_SUPPORT="$temporary_root/app-support"
export DSH_M2_ACCEPTANCE_ROOT="$temporary_root"

printf '%s\n' "M2 acceptance: isolated root $temporary_root"
if [[ ${DSH_M2_RUN_GUI:-0} == "1" ]]; then
  printf '%s\n' "M2 acceptance: real WKWebView suites are enabled"
else
  printf '%s\n' "M2 acceptance: real GUI/WKWebView automation is not run"
fi

cd "$repository_directory"
node --test "${acceptance_tests[@]}"

if [[ ${DSH_M2_RUN_GUI:-0} == "1" ]]; then
  printf '%s\n' "M2 acceptance: running real AppKit/WKWebView navigation and recovery."
  DSH_F07_WKWEBVIEW=1 node --test test/f07-acceptance.integration.test.js
  printf '%s\n' "M2 acceptance: running the real B01 WKWebView bridge harness."
  DSH_B01_WKWEBVIEW=1 node --test test/swift-real-bridge-acceptance.integration.test.js
else
  printf '%s\n' "M2 acceptance: GUI/WKWebView coverage remains explicitly untested."
fi
