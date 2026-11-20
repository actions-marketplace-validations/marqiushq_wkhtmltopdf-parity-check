#!/bin/sh
# Runs inside the wkhtmltopdf 0.12.6 container, started by parity.sh with the work folder at
# /parity and the repository at its own path (read-only, and the working folder). Each page goes
# through wkhtmltopdf, then through marqius-wkhtmltopdf started under the name wkhtmltopdf, as the
# libraries that run wkhtmltopdf start it: the same options, the same system, the same fonts.
#
#   /parity/pages     a line for each page: its name in the report, a tab, its path
#   /parity/options   the options, one to a line
#   /parity/bin       marqius-wkhtmltopdf, the build for this machine
#   /parity-fonts     fonts both programs get (when the action was given a fonts folder)
#
# Writes /parity/old and /parity/new (the PDFs), /parity/logs (what each program said),
# /parity/status (name, wkhtmltopdf's exit status, marqius-wkhtmltopdf's) and /parity/env.
set -u
P=/parity
LIMIT="${PARITY_TIMEOUT:-300}"
mkdir -p "$HOME" /tmp/parity/bin "$P/old" "$P/new" "$P/logs"

cp "$P/bin/marqius-wkhtmltopdf" /tmp/parity/bin/marqius-wkhtmltopdf
chmod 755 /tmp/parity/bin/marqius-wkhtmltopdf
ln -sf /tmp/parity/bin/marqius-wkhtmltopdf /tmp/parity/bin/wkhtmltopdf
WK="$(command -v wkhtmltopdf)"
MQ=/tmp/parity/bin/wkhtmltopdf

added=0
if [ -d /parity-fonts ]; then
    mkdir -p "$HOME/.local/share/fonts/parity"
    find /parity-fonts -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' -o -iname '*.otc' \) \
        -exec cp {} "$HOME/.local/share/fonts/parity/" \;
    fc-cache -f > /dev/null 2>&1
    added="$(find "$HOME/.local/share/fonts/parity" -type f | wc -l | tr -d ' ')"
fi

{
    echo "wkhtmltopdf	$("$WK" -V 2> /dev/null | head -1)"
    echo "marqius-wkhtmltopdf	$("$MQ" -V 2> /dev/null | head -1)"
    echo "system	Alpine $(cat /etc/alpine-release 2> /dev/null), $(uname -m)"
    echo "fonts	$(fc-list : family | sort -u | wc -l | tr -d ' ') families, with $added font files from the fonts folder"
} > "$P/env"

# the options, one argument to a line
set --
while IFS= read -r a || [ -n "$a" ]; do set -- "$@" "$a"; done < "$P/options"

up() { cut -d' ' -f1 /proc/uptime; }

# convert PROGRAM FOLDER LABEL OPTIONS...: every page, one after another, its messages in
# logs/NAME.LABEL.txt; the time it took in FOLDER.time
convert() {
    prog="$1"
    dir="$2"
    label="$3"
    shift 3
    # once untimed, so that neither program is timed reading its files from disk the first time
    first="$(head -1 "$P/pages" | cut -f2)"
    timeout "$LIMIT" "$prog" -q "$@" "$first" /tmp/parity/warm.pdf < /dev/null > /dev/null 2>&1
    start="$(up)"
    while IFS='	' read -r name page; do
        mkdir -p "$(dirname "$P/$dir/$name.pdf")" "$(dirname "$P/logs/$name")"
        timeout "$LIMIT" "$prog" -q "$@" "$page" "$P/$dir/$name.pdf" < /dev/null > "$P/logs/$name.$label.txt" 2>&1
        echo "$name	$?" >> "$P/$dir.status"
    done < "$P/pages"
    awk -v a="$start" -v b="$(up)" 'BEGIN { printf "%.2f\n", b - a }' > "$P/$dir.time"
}

: > "$P/old.status"
: > "$P/new.status"
convert "$WK" old wkhtmltopdf "$@"
convert "$MQ" new marqius-wkhtmltopdf "$@"
