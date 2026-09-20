#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h:h}"
if [[ "${1:-}" != "--skip-build" ]]; then
    mkdir -p .build
    build_log="$PWD/.build/app-build.log"
    build_release() {
        swift build -c release --product MeetingAssistantApp 2>&1 | tee "$build_log"
    }
    if build_release; then
        :
    else
        build_exit=$?
        # Clang module caches embed absolute paths and cannot be reused after
        # moving the checkout. Recover only from that specific diagnostic.
        build_output=$(<"$build_log")
        if [[ "$build_output" != *"was compiled with module cache path"* ||
              "$build_output" != *"but the path is currently"* ]]; then
            exit "$build_exit"
        fi
        release_dir=$(swift build -c release --show-bin-path)
        if [[ "$release_dir" != "$PWD/.build/"* || "$release_dir" != */release || ! -d "$release_dir" ]]; then
            print -u2 -- "Cannot safely relocate the stale release cache: $release_dir"
            exit "$build_exit"
        fi
        # Keep downloaded dependencies, debug builds, validation output and the
        # existing .app. Retain the old release artifacts for manual inspection.
        backup_dir=$(mktemp -d "$PWD/.build/stale-release.XXXXXX")
        cp "$build_log" "$backup_dir/build.log"
        mv "$release_dir" "$backup_dir/release"
        print -r -- "Project location changed: saved stale release artifacts in $backup_dir"
        print -r -- "Rebuilding release with a fresh module cache (one retry)..."
        build_release
    fi
fi
app_dir="$PWD/.build/MeetingAssistant.app"
binary_dir="$PWD/.build/release"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/MeetingAssistantApp" "$app_dir/Contents/MacOS/MeetingAssistantApp"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# Include SwiftPM dependency resources if the resolved package supplies any.
for bundle in "$binary_dir/"*.bundle(N); do
    ditto "$bundle" "$app_dir/Contents/Resources/${bundle:t}"
done
codesign --force --sign - --identifier local.MeetingAssistant "$app_dir"
print -r -- "$app_dir"
