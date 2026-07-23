#!/usr/bin/env bash
set -u

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for test_file in "$TESTS_DIR"/test_*.sh; do
    printf '\n==> %s\n' "$(basename "$test_file")"
    "$test_file" || exit $?
done

printf '\n全部测试通过。\n'
