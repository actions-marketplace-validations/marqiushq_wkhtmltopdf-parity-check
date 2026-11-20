#!/usr/bin/env bash
# The result of the parity check as a comment on the pull request: one comment for each report
# (each `report` folder), updated by every later run rather than added again. Pages that differ and
# that the pull request changes are marked. It needs a token that may write to pull requests
# (permissions: pull-requests: write); without one, it says so and the check goes on.
#
# Settings from action.yml: COMMENT (true or false), TOKEN, REPORT, ARTIFACT, ARTIFACT_URL.
set -euo pipefail

note() {
    echo "::warning title=wkhtmltopdf parity check::$*"
    exit 0
}

case "$(printf '%s' "${COMMENT:-true}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
    true) ;;
    false)
        echo "No comment on the pull request, as asked"
        exit 0
        ;;
    *)
        echo "::error title=wkhtmltopdf parity check::comment is true or false, not '${COMMENT}'"
        exit 2
        ;;
esac
case "${GITHUB_EVENT_NAME:-}" in
    pull_request | pull_request_target) ;;
    *)
        echo "Not a pull request: no comment"
        exit 0
        ;;
esac
command -v jq > /dev/null || note "No comment on the pull request: this runner has no jq"
number="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null || true)"
[ -n "$number" ] || note "No comment: the event names no pull request"
[ -n "${TOKEN:-}" ] || note "No comment on the pull request: no token was given"
[ -f "$REPORT/summary.md" ] || note "No comment on the pull request: the report has no summary"

api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
marker="<!-- wkhtmltopdf-parity-check: $ARTIFACT -->"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/parity-comment.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# call METHOD URL [FILE]: the status (000 when GitHub could not be reached), the answer in $tmp/answer
call() {
    local data=() code
    [ -z "${3:-}" ] || data=(--data-binary "@$3")
    code="$(curl --silent --show-error --location --retry 3 --output "$tmp/answer" --write-out '%{http_code}' -X "$1" \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        ${data[@]+"${data[@]}"} "$2")" || true
    printf '%s' "${code:-000}"
}

# the files the pull request changes (GitHub lists up to 3,000)
: > "$tmp/changed"
for page in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(call GET "$api/pulls/$number/files?per_page=100&page=$page")" = 200 ] || break
    jq -r '.[].filename' "$tmp/answer" >> "$tmp/changed"
    [ "$(jq 'length' "$tmp/answer")" = 100 ] || break
done

# the summary, with the changed pages marked and the report and the run linked
cp "$REPORT/summary.md" "$tmp/body.md"
while IFS= read -r file; do
    [ -n "$file" ] || continue
    awk -v f="| \`$file\` |" -v g="| \`$file\` (changed here) |" '{ i = index($0, f); if (i == 1) $0 = g substr($0, length(f) + 1); print }' \
        "$tmp/body.md" > "$tmp/body.new" && mv "$tmp/body.new" "$tmp/body.md"
done < "$tmp/changed"
run="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-}"
if [ -n "${ARTIFACT_URL:-}" ]; then
    awk -v a="The artifact **$ARTIFACT**" -v b="The artifact [$ARTIFACT]($ARTIFACT_URL)" '{ i = index($0, a); if (i) $0 = substr($0, 1, i - 1) b substr($0, i + length(a)); print }' \
        "$tmp/body.md" > "$tmp/body.new" && mv "$tmp/body.new" "$tmp/body.md"
fi
{
    echo
    echo "[The run]($run), $(date -u '+%e %B %Y, %H:%M UTC' | sed 's/^ //'), for $(jq -r '.pull_request.head.sha // "" | .[:7]' "$GITHUB_EVENT_PATH")"
    echo
    echo "$marker"
} >> "$tmp/body.md"
# GitHub takes comments of up to 65,536 characters: a long list is cut, and the report has it all
if [ "$(wc -c < "$tmp/body.md")" -gt 60000 ]; then
    head -c 58000 "$tmp/body.md" | sed '$d' > "$tmp/body.new"
    printf '\n\n(The list goes on in the report.)\n\n[The run](%s)\n\n%s\n' "$run" "$marker" >> "$tmp/body.new"
    mv "$tmp/body.new" "$tmp/body.md"
fi
jq -Rs '{body: .}' < "$tmp/body.md" > "$tmp/body.json"

# this report's comment from an earlier run, if there is one
id=""
for page in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(call GET "$api/issues/$number/comments?per_page=100&page=$page")" = 200 ] || break
    id="$(jq -r --arg m "$marker" '[.[] | select(.body | contains($m))] | last | .id // empty' "$tmp/answer")"
    [ -z "$id" ] || break
    [ "$(jq 'length' "$tmp/answer")" = 100 ] || break
done

if [ -n "$id" ]; then
    status="$(call PATCH "$api/issues/comments/$id" "$tmp/body.json")"
else
    status="$(call POST "$api/issues/$number/comments" "$tmp/body.json")"
fi
case "$status" in
    200 | 201) echo "The result is on the pull request: $(jq -r '.html_url' "$tmp/answer")" ;;
    403 | 404) note "No comment on the pull request: the workflow's token may not write to it. Give the workflow permissions: pull-requests: write (a pull request from a fork gets a token that can only read)" ;;
    000) note "No comment on the pull request: GitHub's API could not be reached" ;;
    *) note "No comment on the pull request: GitHub answered $status" ;;
esac
