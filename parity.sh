#!/usr/bin/env bash
# wkhtmltopdf parity check: a team's own HTML pages through wkhtmltopdf 0.12.6 and through
# marqius-wkhtmltopdf, then every pair of PDFs compared by marqius-wkhtmltopdf compare.
#
# Without a baseline, both programs run in one container of the image the public parity suite
# measures in (https://github.com/marqiushq/wkhtmltopdf-parity): wkhtmltopdf 0.12.6 with patched
# Qt on Alpine, pinned by digest, so that both see the same system and the same fonts, with no
# network unless it is asked for (convert.sh). With a baseline, the team's own PDFs stand for
# wkhtmltopdf's, and marqius-wkhtmltopdf runs on the runner itself.
#
# Its settings come from action.yml as PARITY_*. WKHTMLTOPDF_IMAGE names another image to make
# wkhtmltopdf's PDFs in: one with wkhtmltopdf on its PATH, a POSIX shell and fontconfig.
set -euo pipefail

IMAGE="${WKHTMLTOPDF_IMAGE:-surnet/alpine-wkhtmltopdf:3.24.3-0.12.6-full@sha256:ce8cbcdfd11a8f73ba0bb5a86301e17325c93a39485cf4165e3e99a08503dca9}"
LEFTOVERS=()
trap 'rm -rf ${LEFTOVERS[@]+"${LEFTOVERS[@]}"}' EXIT

# A mistake in the inputs, or something that stops the check itself: status 2, not a verdict
fail() {
    echo "::error title=wkhtmltopdf parity check::$*"
    exit 2
}

output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; else echo "$1=$2"; fi
}

on_windows() { [ "${RUNNER_OS:-}" = Windows ] || [ "${OS:-}" = Windows_NT ]; }
as_unix() { if on_windows && command -v cygpath > /dev/null; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }

# For GitHub's annotations: the message, and the properties (file=..., title=...), escaped
esc() { local s="${1//'%'/%25}"; s="${s//$'\r'/%0D}"; printf '%s' "${s//$'\n'/%0A}"; }
esc_prop() { local s; s="$(esc "$1")"; s="${s//:/%3A}"; printf '%s' "${s//,/%2C}"; }

lower_trim() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

# split TEXT NAME: options written as on a command line, split as a shell splits them (quotes
# keep words together; nothing in them is run), into WORDS
split() {
    WORDS=()
    local word tmp
    [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || return 0
    tmp="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/parity-words.XXXXXX")"
    LEFTOVERS+=("$tmp")
    LEFTOVERS+=("$tmp.err")
    printf '%s\n' "$1" | xargs printf '%s\0' > "$tmp" 2> "$tmp.err" || fail "$2: a quote is not closed (quote a value that has spaces, and close every quote)"
    while IFS= read -r -d '' word; do WORDS+=("$word"); done < "$tmp"
}

level_rank() { case "$1" in blocking) echo 3 ;; review) echo 2 ;; cosmetic) echo 1 ;; *) echo 0 ;; esac; }

# glob PATTERN: the files a pattern matches, into MATCHED (spaces in names are kept)
glob() {
    local IFS=$'\n'
    # shellcheck disable=SC2206 # the pattern is meant to be expanded, and split only at line breaks
    MATCHED=($1)
}

# status_of FOLDER NAME: the exit status convert.sh or this script noted for a page
status_of() { awk -F'\t' -v n="$2" '$1 == n { print $2; exit }' "$WORK/$1.status" 2> /dev/null || true; }

main() {
    local program version fail_on network baseline fonts report artifact workspace
    program="$(as_unix "${PARITY_PROGRAM:?the program path comes from setup-marqius-wkhtmltopdf}")"
    version="${PARITY_VERSION:-}"
    workspace="$(as_unix "${GITHUB_WORKSPACE:-$PWD}")"
    cd "$workspace"
    workspace="$(pwd -P)"

    fail_on="$(lower_trim "${PARITY_FAIL_ON:-blocking}")"
    case "$fail_on" in blocking | review | cosmetic) ;; *) fail "fail-on is blocking, review or cosmetic, not '${PARITY_FAIL_ON}'" ;; esac
    network="$(lower_trim "${PARITY_NETWORK:-false}")"
    case "$network" in true | false) ;; *) fail "network is true or false, not '${PARITY_NETWORK}'" ;; esac
    case "$(lower_trim "${PARITY_COMMENT:-true}")" in true | false) ;; *) fail "comment is true or false, not '${PARITY_COMMENT}'" ;; esac

    report="${PARITY_REPORT:-wkhtmltopdf-parity}"
    report="${report#./}"
    report="${report%/}"
    case "/$report/" in
        // | /./ | /../* | */../* | //*) fail "report is a folder inside the repository's folder for the report to go in, such as wkhtmltopdf-parity, not '${PARITY_REPORT}'" ;;
    esac
    artifact="$(basename "$report")"

    baseline=""
    if [ -n "${PARITY_BASELINE:-}" ]; then
        baseline="${PARITY_BASELINE%/}"
        [ -d "$baseline" ] || fail "baseline: there is no folder '$baseline'"
    fi
    fonts=""
    if [ -n "${PARITY_FONTS:-}" ]; then
        fonts="${PARITY_FONTS%/}"
        [ -d "$fonts" ] || fail "fonts: there is no folder '$fonts'"
        fonts="$(cd "$fonts" && pwd -P)"
    fi

    split "${PARITY_OPTIONS:-}" options
    local options=(${WORDS[@]+"${WORDS[@]}"})
    split "${PARITY_COMPARE_OPTIONS:-}" compare-options
    local compare_options=(${WORDS[@]+"${WORDS[@]}"})
    local o
    for o in ${options[@]+"${options[@]}"}; do
        case "$o" in *$'\n'* | *$'\t'*) fail "options: an option holds a line break or a tab" ;; esac
    done

    # ---- the pages: one path or pattern to a line; files the options name (a header or footer)
    # are not pages of their own
    local pages=() line found f rel named seen
    shopt -s nullglob
    shopt -s globstar 2> /dev/null || true
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]*}"}"
        [ -n "$line" ] || continue
        found=0
        glob "$line"
        for f in ${MATCHED[@]+"${MATCHED[@]}"}; do
            [ -f "$f" ] || continue
            rel="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
            case "$rel" in "$workspace"/*) rel="${rel#"$workspace"/}" ;; *) fail "pages: $f is outside the repository's folder" ;; esac
            named=0
            for o in ${options[@]+"${options[@]}"}; do
                [ "${o#./}" = "$rel" ] && named=1
            done
            [ "$named" = 1 ] && { found=1; continue; }
            seen=0
            for o in ${pages[@]+"${pages[@]}"}; do [ "$o" = "$rel" ] && seen=1; done
            [ "$seen" = 1 ] || pages+=("$rel")
            found=1
        done
        [ "$found" = 1 ] || fail "pages: no file matches '$line'"
    done <<< "${PARITY_PAGES:-}"
    [ ${#pages[@]} -gt 0 ] || fail "pages names no HTML file to convert"

    # ---- each page's name in the report: its path from the folder all the pages share, without
    # its extension (templates/pdf/invoice.html gives invoice)
    local common names=() name p
    common="$(dirname "${pages[0]}")"
    for p in "${pages[@]}"; do
        while [ "$common" != . ] && [[ "$p" != "$common"/* ]]; do common="$(dirname "$common")"; done
    done
    for p in "${pages[@]}"; do
        name="$p"
        [ "$common" = . ] || name="${p#"$common"/}"
        name="${name%.*}"
        for o in ${names[@]+"${names[@]}"}; do
            [ "$o" = "$name" ] && fail "pages: two pages would both be called '$name' in the report (rename one, or leave one out)"
        done
        names+=("$name")
    done

    local work="$WORK" i
    rm -rf "$work"
    mkdir -p "$work/bin" "$work/old" "$work/new" "$work/logs"
    LEFTOVERS+=("$work")
    : > "$work/pages"
    for i in "${!pages[@]}"; do printf '%s\t%s\n' "${names[$i]}" "${pages[$i]}" >> "$work/pages"; done

    local count=${#pages[@]} wk_time="" mq_time="" against status
    echo "marqius-wkhtmltopdf ${version} against $([ -n "$baseline" ] && echo "the PDFs in $baseline" || echo "wkhtmltopdf 0.12.6"): $count page$([ "$count" = 1 ] || echo s)"

    if [ -z "$baseline" ]; then
        # ---- both programs in the reference container
        [ "$(uname -s)" = Linux ] || fail "Without a baseline, the check makes wkhtmltopdf's PDFs in Docker, which needs a Linux runner: use runs-on: ubuntu-latest (or ubuntu-24.04-arm), or give a baseline folder of PDFs"
        command -v docker > /dev/null || fail "Without a baseline, the check makes wkhtmltopdf's PDFs in Docker, and this runner has no docker command"
        cp "$program" "$work/bin/marqius-wkhtmltopdf"
        cp "$GITHUB_ACTION_PATH/convert.sh" "$work/convert.sh"
        printf '%s\n' ${options[@]+"${options[@]}"} > "$work/options"
        [ ${#options[@]} -gt 0 ] || : > "$work/options"
        if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
            echo "Downloading wkhtmltopdf 0.12.6 ($IMAGE)"
            docker pull -q "$IMAGE" > /dev/null || { sleep 10; docker pull -q "$IMAGE" > /dev/null; } || fail "could not download $IMAGE"
        fi
        local run=(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/home -e "PARITY_TIMEOUT=${PARITY_TIMEOUT:-300}"
            -v "$workspace:$workspace:ro" -w "$workspace" -v "$work:/parity")
        [ "$network" = true ] || run+=(--network none)
        [ -z "$fonts" ] || run+=(-v "$fonts:/parity-fonts:ro")
        "${run[@]}" --entrypoint /bin/sh "$IMAGE" /parity/convert.sh || fail "the container that converts the pages stopped (status $?)"
        wk_time="$(cat "$work/old.time" 2> /dev/null || true)"
        mq_time="$(cat "$work/new.time" 2> /dev/null || true)"
        against="$(sed -n 's/^wkhtmltopdf\t//p' "$work/env")"
    else
        # ---- the team's PDFs against marqius-wkhtmltopdf on this runner
        local missing=()
        for i in "${!pages[@]}"; do
            [ -f "$baseline/${names[$i]}.pdf" ] || missing+=("$baseline/${names[$i]}.pdf")
        done
        [ ${#missing[@]} = 0 ] || fail "baseline: no PDF for ${#missing[@]} of the pages: ${missing[*]}"
        for i in "${!pages[@]}"; do
            name="${names[$i]}"
            mkdir -p "$(dirname "$work/old/$name.pdf")" "$(dirname "$work/new/$name.pdf")" "$(dirname "$work/logs/$name")"
            cp "$baseline/$name.pdf" "$work/old/$name.pdf"
            status=0
            MARQIUS_FONTS="${fonts:-${MARQIUS_FONTS:-}}" "$program" -q ${options[@]+"${options[@]}"} "${pages[$i]}" "$work/new/$name.pdf" \
                < /dev/null > "$work/logs/$name.marqius-wkhtmltopdf.txt" 2>&1 || status=$?
            printf '%s\t%s\n' "$name" "$status" >> "$work/new.status"
        done
        against="the PDFs in $baseline"
    fi

    # ---- a page either program made no PDF of stops the check: there is nothing to compare
    local which program_name said
    for i in "${!pages[@]}"; do
        name="${names[$i]}"
        for which in old new; do
            [ "$which" = old ] && [ -n "$baseline" ] && continue
            if [ ! -s "$work/$which/$name.pdf" ]; then
                program_name=$([ "$which" = old ] && echo wkhtmltopdf || echo marqius-wkhtmltopdf)
                said="$(status_of "$which" "$name")"
                echo "--- what $program_name said about ${pages[$i]}"
                cat "$work/logs/$name.$program_name.txt" 2> /dev/null || true
                fail "$program_name made no PDF of ${pages[$i]} (status ${said:-unknown}${said:+, }$([ "$said" = 124 ] && echo "stopped after ${PARITY_TIMEOUT:-300} seconds" || echo "its messages are above"))"
            fi
        done
    done

    # ---- every pair compared
    rm -rf "$report"
    mkdir -p "$(dirname "$report")"
    status=0
    "$program" compare "$work/old" "$work/new" -o "$report" --quiet ${compare_options[@]+"${compare_options[@]}"} --fail-on "$fail_on" > "$work/compare.txt" 2>&1 || status=$?
    if [ "$status" -gt 1 ]; then
        cat "$work/compare.txt"
        fail "marqius-wkhtmltopdf compare could not compare the PDFs (status $status)"
    fi
    cp -R "$work/old" "$report/$([ -n "$baseline" ] && echo baseline || echo wkhtmltopdf)"
    cp -R "$work/new" "$report/marqius-wkhtmltopdf"
    cp -R "$work/logs" "$report/messages"
    [ ! -f "$work/env" ] || cp "$work/env" "$report/system.txt"

    local verdict decision
    verdict=$([ "$status" = 0 ] && echo pass || echo fail)
    decision="$(grep -E '^ *(GO|REVIEW|NO-GO)' "$report/summary.txt" | head -1 | sed 's/^ *//')"
    [ ! -f "$report/summary.txt" ] || sed -e '1d' -e '/^In /,$d' "$report/summary.txt"

    summarise "$report" "$fail_on" "$verdict" "$decision" "$against" "$count" "$wk_time" "$mq_time" "$artifact" "$baseline" ||
        echo "::warning title=wkhtmltopdf parity check::The job summary could not be written in full; the report is complete"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$report/summary.md" >> "$GITHUB_STEP_SUMMARY"
    output verdict "$verdict"
    output decision "$decision"
    output report "$report"
    output artifact "$artifact"
    # the build fails in the action's last step, once the report is kept and the comment posted
    echo "Verdict: $verdict (the check fails on differences at the $fail_on level$([ "$fail_on" = cosmetic ] || echo " or above"))"
}

# summarise REPORT FAIL_ON VERDICT DECISION AGAINST COUNT WK_TIME MQ_TIME ARTIFACT BASELINE: an
# annotation on each page that differs; REPORT/summary.md, for the job summary and the comment on
# a pull request; REPORT/pages.tsv, a line for each page (path, verdict, level, the most serious
# difference)
summarise() {
    local report="$1" fail_on="$2" verdict="$3" decision="$4" against="$5" count="$6" wk_time="$7" mq_time="$8" artifact="$9" baseline="${10}"
    local threshold rows name page verdict_of level note kind md
    threshold="$(level_rank "$fail_on")"
    md="$report/summary.md"
    : > "$md"
    : > "$report/pages.tsv"
    if ! command -v jq > /dev/null; then
        echo "(jq is not on this runner, so the job summary holds compare's own text)"
        { echo "### wkhtmltopdf parity: $verdict"; echo; echo '```'; sed -e '1d' -e '/^In /,$d' "$report/summary.txt"; echo '```'; } >> "$md"
        return 0
    fi

    # each pair: its name, verdict, level, and its most serious difference
    rows="$(jq -r '
        def rank: {"blocking": 3, "review": 2, "cosmetic": 1}[.] // 0;
        ([.differences[]? | select(.level != "ignore")] | sort_by(-(.level | rank)) | first) as $w
        | [ (.old | gsub("\\\\"; "/") | sub("^.*/wkhtmltopdf-parity/old/"; "") | sub("\\.pdf$"; "")), .verdict, (.level // ""),
            (($w.note // "") | if . == "" then ($w.cause // "") else . end) ] | @tsv' "$report"/pairs/*.json 2> /dev/null || true)"

    {
        echo "### wkhtmltopdf parity: ${verdict}"
        echo
        echo "marqius-wkhtmltopdf ${PARITY_VERSION:-} against ${against}, ${count} page$([ "$count" = 1 ] || echo s): $([ "$verdict" = pass ] && echo "no difference" || echo "differences") at the level that fails this check (${fail_on}$([ "$fail_on" = cosmetic ] || echo " or above"))."
        echo
        [ -z "$decision" ] || { echo "**${decision}**"; echo; }
        echo "| Verdict | Pages |"
        echo "|---|---:|"
        jq -r '.verdicts as $v | ["same", "appearance only", "content differs", "file differs", "cannot tell", "no partner", "not compared"]
            | . as $order | ($order + (($v | keys) - $order)) | .[] | select(($v[.] // 0) > 0) | "| \(.[:1] | ascii_upcase)\(.[1:]) | \($v[.]) |"' "$report/summary.json"
        echo
        echo "By level: $(jq -r '.levels | "blocking \(.blocking // 0), review \(.review // 0), cosmetic \(.cosmetic // 0)"' "$report/summary.json")."
    } >> "$md"

    # every page, by its path in the repository (fields are read split at \037, as read would run
    # empty fields between tabs together)
    [ -z "$rows" ] || while IFS=$'\037' read -r name verdict_of level note; do
        page="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$WORK/pages" 2> /dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "${page:-$name}" "$verdict_of" "$level" "$note" >> "$report/pages.tsv"
    done < <(printf '%s\n' "$rows" | tr '\t' '\037')

    # the pages that differ: a line of the table, and an annotation on the file
    if awk -F'\t' '$2 != "same" { found = 1 } END { exit !found }' "$report/pages.tsv"; then
        {
            echo
            echo "| Page | Verdict | Level | The most serious difference |"
            echo "|---|---|---|---|"
        } >> "$md"
        while IFS=$'\037' read -r page verdict_of level note; do
            [ "$verdict_of" = same ] && continue
            echo "| \`${page}\` | ${verdict_of} | ${level:-none} | ${note//|/\\|} |" >> "$md"
            kind=notice
            [ "$(level_rank "$level")" -ge "$threshold" ] && [ "$threshold" -gt 0 ] && kind=error
            echo "::${kind} file=$(esc_prop "$page"),title=$(esc_prop "wkhtmltopdf parity: ${verdict_of}${level:+ ($level)}")::$(esc "${note:-$verdict_of}")"
        done < <(tr '\t' '\037' < "$report/pages.tsv")
    fi

    {
        if jq -e '.causes | length > 0' "$report/summary.json" > /dev/null 2>&1; then
            echo
            echo "<details><summary>Every kind of difference found, by how many pages show it</summary>"
            echo
            echo "| Level | Pages | Difference | Example |"
            echo "|---|---:|---|---|"
            jq -r '.causes[:20][] | "| \(.level) | \(.documents) | \(.cause | gsub("\\|"; "\\|")) | \(.example // "" | gsub("\\|"; "\\|")) |"' "$report/summary.json"
            echo
            echo "</details>"
        fi
        if [ -n "$wk_time" ] && [ -n "$mq_time" ]; then
            echo
            echo "Time to convert $([ "$count" = 1 ] && echo "the page" || echo "the ${count} pages, one after another,") on this runner: wkhtmltopdf ${wk_time} s, marqius-wkhtmltopdf ${mq_time} s (one run each)."
        fi
        echo
        echo "The artifact **${artifact}** holds both PDFs of every page$([ -z "$baseline" ] || echo " (yours under baseline)"), marked-up copies of those that differ, with a frame and a note at each difference, and pictures of the pages that differ. \`marqius-wkhtmltopdf compare kinds\` lists every kind of difference and its level. The [wkhtmltopdf parity suite](https://github.com/marqiushq/wkhtmltopdf-parity) runs the same comparison on every release of marqius-wkhtmltopdf, misses included."
    } >> "$md"
}

WORK="$(as_unix "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")/wkhtmltopdf-parity"
main "$@"
