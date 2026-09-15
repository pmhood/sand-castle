#!/usr/bin/env bats
# The suite's own assertion style, which decides whether any of the rest of it means anything.
#
# macOS ships bash 3.2, which does not apply errexit to a bare `[[ ]]`. A `[[ ]]` assertion that
# is not the last command of its test body therefore fails the test under bash 5 and passes
# silently under 3.2, so `make test` on a developer machine reports safety it never checked.
# helpers.bash holds the assertion helpers; this is what keeps them being used.

bats_require_minimum_version 1.5.0

load helpers

@test "no assertion in this suite is a bare [[ ]], which bash 3.2 ignores" {
    run grep -nE '^[[:space:]]*\[\[.*\]\][[:space:]]*$' \
        "$BOOTSTRAP_DIR"/test/*.bats "$BOOTSTRAP_DIR"/test/*.bash
    # grep exits 1 having found nothing, which is the passing case. A `[[ ]]` that is part of an
    # `if`, a `while` or an `||` list is a condition rather than an assertion and does not match;
    # anything that does match is named in $output.
    [ "$status" -eq 1 ]
}
