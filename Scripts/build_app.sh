#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build -c release --product MeetingAssistantApp
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
