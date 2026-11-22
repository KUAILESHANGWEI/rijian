#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rijian-cloud-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library "$ROOT/native/shared/CloudSync.swift" "$ROOT/tests/CloudSyncTests.swift" -o "$TEST_DIR/cloud-tests" -framework CoreData -framework CloudKit -framework WebKit
"$TEST_DIR/cloud-tests"
