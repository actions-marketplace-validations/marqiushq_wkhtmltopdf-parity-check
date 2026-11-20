#!/usr/bin/env bash
# Checks for .github/workflows/test.yml, one to a step. The action's outputs come in as VERDICT,
# DECISION and REPORT, its outcome as OUTCOME.
#
#   check.sh passed                    the check passed, with GO, and a report in REPORT
#   check.sh failed                    the check failed (and the step with it), with NO-GO
#   check.sh pdfs NAME...              both programs' PDFs of each page NAME are in the report
#   check.sh only NAME...              and those are all the pages the report holds
#   check.sh system TEXT               the report's system.txt says TEXT
#   check.sh fonts FOLDER              a fonts folder with one of the runner's own fonts in it
#   check.sh comment REPORT            one comment on the pull request for REPORT, saying what failed
#   check.sh refused TEXT              the step before failed and parity.sh says TEXT, given the
#                                      same inputs in PARITY_*
set -euo pipefail

fail() {
    echo "::error::$*"
    exit 1
}

is_pdf() { [ -s "$1" ] && [ "$(head -c 5 "$1")" = "%PDF-" ]; }

case "${1:-}" in
    passed)
        [ "$VERDICT" = pass ] || fail "the verdict is '$VERDICT', not pass"
        case "$DECISION" in GO:*) ;; *) fail "the decision is '$DECISION', not GO" ;; esac
        [ -f "$REPORT/summary.json" ] || fail "no summary.json in $REPORT"
        echo "Passed: $DECISION"
        ;;
    failed)
        [ "$OUTCOME" = failure ] || fail "the step's outcome is '$OUTCOME', not failure"
        [ "$VERDICT" = fail ] || fail "the verdict is '$VERDICT', not fail"
        case "$DECISION" in NO-GO:*) ;; *) fail "the decision is '$DECISION', not NO-GO" ;; esac
        echo "Failed, as it should: $DECISION"
        ;;
    pdfs | only)
        what="$1"
        shift
        other=wkhtmltopdf
        [ -d "$REPORT/$other" ] || other=baseline
        for name in "$@"; do
            is_pdf "$REPORT/marqius-wkhtmltopdf/$name.pdf" || fail "no PDF of $name from marqius-wkhtmltopdf in $REPORT"
            is_pdf "$REPORT/$other/$name.pdf" || fail "no PDF of $name under $other in $REPORT"
        done
        if [ "$what" = only ]; then
            count="$(find "$REPORT/marqius-wkhtmltopdf" -name '*.pdf' | wc -l | tr -d ' ')"
            [ "$count" = "$#" ] || fail "the report holds $count pages, not $#: $(cd "$REPORT/marqius-wkhtmltopdf" && find . -name '*.pdf' | sort | tr '\n' ' ')"
        fi
        echo "Both PDFs of: $*"
        ;;
    system)
        grep -q -- "$2" "$REPORT/system.txt" || fail "system.txt does not say '$2': $(cat "$REPORT/system.txt")"
        grep -- "$2" "$REPORT/system.txt"
        ;;
    fonts)
        mkdir -p "$2"
        font="$(fc-list --format '%{file}\n' 2> /dev/null | grep -i -m1 -E '\.(ttf|otf)$' || true)"
        [ -n "$font" ] || fail "this runner has no font file to copy"
        cp "$font" "$2/"
        echo "Fonts folder $2: $(basename "$font")"
        ;;
    comment)
        # one comment for the report, from the two runs, with the result and its pages
        [ "$FIRST" = fail ] && [ "$SECOND" = fail ] || fail "the verdicts were '$FIRST' and '$SECOND', not fail twice"
        marker="<!-- wkhtmltopdf-parity-check: $2 -->"
        gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$NUMBER/comments" --jq ".[] | select(.body | contains(\"$marker\")) | .body" > comments.txt
        count="$(grep -c -F -- "$marker" comments.txt || true)"
        [ "$count" = 1 ] || fail "$count comments for the report $2, not one"
        for text in "### wkhtmltopdf parity: fail" "NO-GO" "test/no-charset/no-charset.html" "[The run]("; do
            grep -q -F -- "$text" comments.txt || fail "the comment does not say '$text'"
        done
        if gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$NUMBER/files" --jq '.[].filename' | grep -q -x test/no-charset/no-charset.html; then
            # shellcheck disable=SC2016 # the backticks are the comment's own
            grep -q -F -- '`test/no-charset/no-charset.html` (changed here)' comments.txt || fail "the page this pull request changes is not marked"
            echo "The page this pull request changes is marked"
        fi
        echo "One comment for $2, updated by the second run"
        ;;
    refused)
        [ "$OUTCOME" = failure ] || fail "the action did not refuse (its outcome: $OUTCOME)"
        export GITHUB_ACTION_PATH="$PWD"
        said="$(PARITY_PROGRAM="${PARITY_PROGRAM:-$(command -v marqius-wkhtmltopdf || echo marqius-wkhtmltopdf)}" GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null bash ./parity.sh 2>&1 || true)"
        case "$said" in *"$2"*) ;; *) fail "the message does not say '$2': $said" ;; esac
        echo "Refused, saying: $(printf '%s\n' "$said" | grep -m1 '::error' | sed 's/^::error[^:]*:://')"
        ;;
    *)
        echo "usage: check.sh passed|failed|pdfs NAME...|only NAME...|system TEXT|fonts FOLDER|refused TEXT" >&2
        exit 2
        ;;
esac
