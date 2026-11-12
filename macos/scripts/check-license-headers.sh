#!/bin/sh
#
#  check-license-headers.sh
#  Burnline
#
#  Copyright (C) 2026 Challapalli Harshavardhan Reddy
#  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Fails when a source file is missing the AGPL header. Every source file must
# carry the copyright line and name the license; the licensing section of the
# contracts document makes this an obligation, not a style preference.
#
# Runs as a build phase of the app target, and by hand from anywhere:
#   macos/scripts/check-license-headers.sh

set -eu

COPYRIGHT_HOLDER="Challapalli Harshavardhan Reddy"
LICENSE_NAME="GNU Affero General Public License"
# The header must appear near the top, not anywhere in the file.
HEADER_LINES=20

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
failures=$(
    find "$repo_root" \
        \( -name .git -o -name .build -o -name DerivedData -o -name '*.xcodeproj' -o -path "$repo_root/build" \) -prune -o \
        -type f \( -name '*.swift' -o -name '*.sql' -o -name '*.sh' -o -name '*.py' \) -print |
    while IFS= read -r file; do
        top=$(head -n "$HEADER_LINES" "$file")
        if ! printf '%s' "$top" | grep -Eq "Copyright \(C\) [0-9]{4}(-[0-9]{4})? $COPYRIGHT_HOLDER" \
            || ! printf '%s' "$top" | grep -q "$LICENSE_NAME"; then
            echo "error: ${file#"$repo_root"/} is missing the AGPL license header"
        fi
    done
)

if [ -n "$failures" ]; then
    echo "$failures"
    echo "error: $(echo "$failures" | wc -l | tr -d ' ') file(s) missing the license header. Copy it from any existing source file."
    exit 1
fi
