#!/bin/sh
set -eu
RIJIAN_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$RIJIAN_ROOT/native/android"
: "${JAVA_HOME:=$HOME/.local/android-build/temurin-jdk}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export JAVA_HOME ANDROID_HOME
"${RIJIAN_GRADLE:-$HOME/.local/android-build/gradle-9.3.1/bin/gradle}" --no-daemon :app:assembleDebug "$@"
mkdir -p "$RIJIAN_ROOT/exports"
cp app/build/outputs/apk/debug/app-debug.apk "$RIJIAN_ROOT/exports/日缄-1.0-Android测试版.apk"
