#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == */CommandLineTools ]]; then
    # CLT 6.3 ships Testing.framework but SwiftPM omits its search paths.
    test_frameworks="$developer_dir/Library/Developer/Frameworks"
    test_libraries="$developer_dir/Library/Developer/usr/lib"
    exec swift test --disable-xctest --enable-swift-testing \
        -Xswiftc "-F$test_frameworks" \
        -Xlinker -rpath -Xlinker "$test_frameworks" \
        -Xlinker -rpath -Xlinker "$test_libraries" "$@"
else
    exec swift test "$@"
fi
