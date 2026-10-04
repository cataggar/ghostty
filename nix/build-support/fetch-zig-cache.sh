#!/bin/sh

# NOTE THIS IS A TEMPORARY SCRIPT TO SUPPORT PACKAGE MAINTAINERS.
#
# A future Zig version will hopefully fix the issue where
# `zig build --fetch` doesn't fetch transitive dependencies[1]. When that
# is resolved, we won't need any special machinery for the general use case
# at all and packagers can just use `zig build --fetch`.
#
# [1]: https://github.com/ziglang/zig/issues/20976

if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]
then
  echo "must set ZIG_GLOBAL_CACHE_DIR!"
  exit 1
fi

# Go through each line of our build.zig.zon.txt and fetch it.
SCRIPT_PATH="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ZON_TXT_FILE="$SCRIPT_PATH/../../build.zig.zon.txt"
while IFS= read -r url; do
  echo "Fetching: $url"
  hash=$(zig fetch "$url") || {
    echo "Failed to fetch: $url" >&2
    exit 1
  }
  case "$hash" in
    ""|*/*|.*)
      echo "Invalid package hash returned for: $url" >&2
      exit 1
      ;;
  esac
  package="$ZIG_GLOBAL_CACHE_DIR/p/$hash"
  archive="$ZIG_GLOBAL_CACHE_DIR/p/$hash.tar.gz"
  # Archive dependencies can retain their original single root directory.
  strip=$(tar -tzf "$archive" | awk -F/ '
    NF == 2 && $2 != "" { files = 1 }
    NF > 2 && $2 != "" && !($2 in roots) { roots[$2] = 1; count++ }
    END { print files || count != 1 ? 1 : 2 }
  ')
  mkdir -p "$package" || exit 1
  tar -xzf "$archive" \
    --directory "$package" --strip-components="$strip" || {
    echo "Failed to unpack: $url" >&2
    exit 1
  }
done < "$ZON_TXT_FILE"
