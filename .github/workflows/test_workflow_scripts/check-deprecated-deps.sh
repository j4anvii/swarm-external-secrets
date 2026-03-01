#!/bin/bash
set -euo pipefail

# Extract direct dependencies from go.mod
direct_deps=$(go mod edit -json | jq -r '.Require[] | select(.Indirect == null) | .Path')

# List all modules with their update / deprecation status
output=$(go list -m -u all)

found_deprecated=false

while IFS= read -r line; do
    mod_path=$(echo "$line" | awk '{print $1}')

    # Check only direct dependencies
    if echo "$direct_deps" | grep -qx "$mod_path"; then
        if [[ "$line" == *"deprecated"* || "$line" == *"retracted"* ]]; then
            echo "Deprecated/retracted direct dependency found: $line"
            found_deprecated=true
        fi
    fi
done <<< "$output"

if [ "$found_deprecated" = true ]; then
    echo "Exiting with failure due to deprecated direct dependencies."
    exit 1
fi

echo "✅ No disallowed deprecated direct dependencies found."