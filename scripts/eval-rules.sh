#!/bin/bash
# Rules-only regression gate: runs every eval set listed in Tests/Eval/rules-baseline.txt with --no-ai
# (no model needed) and fails when a set passes fewer cases than the minimum given there.
set -u
cd "$(dirname "$0")/.."
status=0
while read -r set min; do
    case "$set" in ''|'#'*) continue ;; esac
    line=$(swift run -c release SaywriteEval "Tests/Eval/$set" --no-ai | grep '^PASS ')
    if [ -z "$line" ]; then
        echo "::error::eval produced no PASS line for $set (build or launch failure)"
        status=1
        continue
    fi
    passed=$(echo "$line" | sed -E 's|^PASS ([0-9]+)/.*|\1|')
    echo "$set: $line (minimum $min)"
    if ! [ "$passed" -ge "$min" ] 2>/dev/null; then
        echo "::error::Rules-only eval regression in $set: $passed < $min"
        status=1
    fi
done < Tests/Eval/rules-baseline.txt
exit $status
