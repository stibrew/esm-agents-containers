#!/bin/bash
# resolve custom rules file from the project rules directory
# usage: resolve-rules.sh <filename>
# e.g.: resolve-rules.sh planning-rules.md
# e.g.: resolve-rules.sh brainstorm-rules.md
#
# checks (first-found-wins, not merged):
#   1. .opencode/rules/<filename> (project rules)
#   2. .claude/<filename> (legacy cc-thingz location, kept for teams migrating)
#
# outputs file content to stdout if found, empty output if not
# always exits 0

filename="$1"
if [ -z "$filename" ]; then
    exit 0
fi

if [ -f ".opencode/rules/$filename" ] && [ -s ".opencode/rules/$filename" ]; then
    cat ".opencode/rules/$filename"
elif [ -f ".claude/$filename" ] && [ -s ".claude/$filename" ]; then
    cat ".claude/$filename"
fi

exit 0
