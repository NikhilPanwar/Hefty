#!/bin/sh
# Runs the engine tests. With full Xcode, plain `swift test` works; with only the
# Command Line Tools, Swift Testing needs these extra framework/library paths.
set -e
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  exec swift test -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
