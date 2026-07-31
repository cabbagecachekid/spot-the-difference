#!/usr/bin/env bash
#
# spot.sh — find what differs between two or more sets of documents.
#
#   spot.sh compare --source LABEL=PATH --source LABEL=PATH [...] [--truth LABEL]
#                   [--watch "Term One,Term Two"]
#   spot.sh trace   --source LABEL=PATH [...] --term "STRING" [--loose]
#
# A source may be a single file or a directory. Supported formats:
#   .md .markdown .txt .html .htm   always
#   .pdf                            if pdftotext is installed
#   .docx                           if pandoc is installed
#
# Everything runs locally. Nothing is uploaded anywhere.
#
# Targets bash 3.2 and BSD userland so it runs on a stock Mac. That means no
# associative arrays, no `mapfile`, no GNU-only flags — intermediate state goes
# through a temp directory instead.

set -uo pipefail

PROG="$(basename "$0")"

# ---------- optional dependencies ----------

HAVE_PDFTOTEXT=0; command -v pdftotext >/dev/null 2>&1 && HAVE_PDFTOTEXT=1
HAVE_PANDOC=0;    command -v pandoc    >/dev/null 2>&1 && HAVE_PANDOC=1

SKIPPED_PDF=0
SKIPPED_DOCX=0

# ---------- temp workspace ----------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spot.XXXXXX")" || { echo "$PROG: cannot create temp dir" >&2; exit 1; }
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------- small helpers ----------

die() { echo "$PROG: $*" >&2; exit 1; }

lower() { tr '[:upper:]' '[:lower:]'; }

ext_of() {
  # lowercase extension, no dot
  local b="${1##*/}"
  case "$b" in
    *.*) printf '%s' "${b##*.}" | lower ;;
    *)   printf '' ;;
  esac
}

mtime() {
  # BSD stat. Falls back to "?" rather than failing the run.
  stat -f "%Sm" -t "%Y-%m-%d" "$1" 2>/dev/null || echo "?"
}

norm_text() {
  # Shared normalizer: lowercase, every non-alphanumeric run becomes a single
  # dash, edges trimmed. Punctuation has to go or "Education & Certifications"
  # never matches a file called education-certifications.md.
  printf '%s' "$1" \
    | lower \
    | tr -cs 'a-z0-9' '-' \
    | sed -e 's/^-//' -e 's/-$//'
}

norm_key() {
  # Alignment key for a FILE PATH: basename, extension stripped, then normalized.
  #
  # Keep this away from heading text. `${b##*/}` and `${b%.*}` are path
  # operations — fed a heading like "Billing / Invoices" they keep only the
  # last slash-segment, and a heading like "Jane Q. Public" loses its last
  # word to the extension strip. Headings go through norm_text instead.
  local b="${1##*/}"
  b="${b%.*}"
  norm_text "$b"
}

safe_name() {
  # A key made safe for use as a filename.
  printf '%s' "$1" | sed -e 's|[^A-Za-z0-9._-]|_|g'
}

# ---------- format readers ----------

html_to_text() {
  # Drop script/style blocks, strip tags, decode the common entities.
  awk '
    BEGIN { skip = 0 }
    { line = $0 }
    tolower(line) ~ /<(script|style)[ >]/ { skip = 1 }
    skip == 0 { print line }
    tolower(line) ~ /<\/(script|style)>/  { skip = 0 }
  ' "$1" 2>/dev/null \
    | sed -e 's|<[^>]*>| |g' \
    | sed -e 's|&amp;|\&|g; s|&lt;|<|g; s|&gt;|>|g; s|&quot;|"|g; s|&#39;|'"'"'|g; s|&nbsp;| |g' \
    | sed -e 's/[[:space:]]\{1,\}/ /g' \
    | grep -v '^ *$'
}

html_headers() {
  # H1-H3 text, one per line, as "H<n><TAB><text>".
  #
  # The level and text are split by awk rather than sed: a `$'\t'` spliced into
  # a sed replacement does not reliably survive as a real tab, and when it
  # silently arrives as a space every downstream `cut -f2-` returns the whole
  # line — headings then normalize as "h2-skills" instead of "skills" and
  # nothing ever matches across sources.
  #
  # BSD sed does not honour a backreference in the pattern, only in the
  # replacement, so the closing tag is matched with [1-3] rather than \1.
  grep -hoE '<h[1-3][^>]*>[^<]+</h[1-3]>' "$1" 2>/dev/null \
    | awk '{
        if (match($0, /<h[1-3]/)) {
          lvl = substr($0, RSTART + 2, 1)
          txt = $0
          sub(/^<h[1-3][^>]*>/, "", txt)
          sub(/<\/h[1-3]>[[:space:]]*$/, "", txt)
          printf "H%s\t%s\n", lvl, txt
        }
      }' \
    | sed -e 's|&amp;|\&|g; s|&lt;|<|g; s|&gt;|>|g; s|&quot;|"|g; s|&#39;|'"'"'|g' \
    | sed -e 's/ \{1,\}/ /g' -e 's/[[:space:]]*$//'
}
# NOTE: the squeeze above collapses SPACES only, deliberately. Using
# [[:space:]] there eats the level/text tab this function just produced.

md_headers() {
  awk '
    /^### / { sub(/^### /,""); print "H3\t" $0; next }
    /^## /  { sub(/^## /,"");  print "H2\t" $0; next }
    /^# /   { sub(/^# /,"");   print "H1\t" $0; next }
  ' "$1" 2>/dev/null | sed -e 's/[[:space:]]*$//'
}

read_text() {
  # $1 = path, $2 = ext. Prints plain text, or nothing if unsupported.
  case "$2" in
    md|markdown|txt|text) cat "$1" 2>/dev/null ;;
    html|htm)             html_to_text "$1" ;;
    pdf)
      if [ "$HAVE_PDFTOTEXT" -eq 1 ]; then pdftotext -layout "$1" - 2>/dev/null
      else SKIPPED_PDF=$((SKIPPED_PDF+1)); fi ;;
    docx)
      if [ "$HAVE_PANDOC" -eq 1 ]; then pandoc -t plain "$1" 2>/dev/null
      else SKIPPED_DOCX=$((SKIPPED_DOCX+1)); fi ;;
    *) : ;;
  esac
}

read_headings() {
  # $1 = path, $2 = ext. Prints "H<n>\t<text>" lines, or nothing.
  case "$2" in
    md|markdown) md_headers "$1" ;;
    html|htm)    html_headers "$1" ;;
    docx)
      if [ "$HAVE_PANDOC" -eq 1 ]; then
        pandoc -t markdown "$1" 2>/dev/null > "$WORK/.docx.md"
        md_headers "$WORK/.docx.md"
        rm -f "$WORK/.docx.md"
      fi ;;
    *) : ;;   # txt and pdf carry no reliable heading structure
  esac
}

is_supported() {
  case "$1" in
    md|markdown|txt|text|html|htm) return 0 ;;
    pdf)  [ "$HAVE_PDFTOTEXT" -eq 1 ] && return 0; SKIPPED_PDF=$((SKIPPED_PDF+1));  return 1 ;;
    docx) [ "$HAVE_PANDOC"    -eq 1 ] && return 0; SKIPPED_DOCX=$((SKIPPED_DOCX+1)); return 1 ;;
    *) return 1 ;;
  esac
}

# ---------- value extraction ----------

extract_values() {
  # stdin = plain text; stdout = sorted unique "CLASS\tVALUE" lines.
  #
  # Each class is pulled off in turn and then MASKED OUT of the working copy
  # before the next class runs. Without masking, the plain-number pass shreds
  # everything already matched — "$29" and "2026-03-01" come back as stray
  # 29, 2026, 03, 01 — and a values section full of fragments is one nobody
  # trusts enough to read.
  local t="$WORK/.vals.$$"
  local m="$WORK/.mask.$$"
  cat > "$t"
  cp "$t" "$m"

  grep -oE '\$[0-9][0-9,]*(\.[0-9]+)?' "$m" 2>/dev/null | sed -e 's/^/MONEY'$'\t''/'
  sed -E -i '' -e 's/\$[0-9][0-9,]*(\.[0-9]+)?/ /g' "$m" 2>/dev/null

  grep -oE '[0-9]+(\.[0-9]+)?%' "$m" 2>/dev/null | sed -e 's/^/PERCENT'$'\t''/'
  sed -E -i '' -e 's/[0-9]+(\.[0-9]+)?%/ /g' "$m" 2>/dev/null

  grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$m" 2>/dev/null | sed -e 's/^/DATE'$'\t''/'
  sed -E -i '' -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/ /g' "$m" 2>/dev/null

  grep -oE '(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?[ ][0-9]{4}' "$m" 2>/dev/null \
    | sed -e 's/^/DATE'$'\t''/'
  sed -E -i '' -e 's/(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?[ ][0-9]{4}/ /g' "$m" 2>/dev/null

  grep -oE '(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)' "$m" 2>/dev/null \
    | grep -oE '(19|20)[0-9]{2}' | sed -e 's/^/YEAR'$'\t''/'
  sed -E -i '' -e 's/(19|20)[0-9]{2}/ /g' "$m" 2>/dev/null

  grep -oE '[0-9][0-9,]*(\.[0-9]+)?' "$m" 2>/dev/null | sed -e 's/^/NUMBER'$'\t''/'

  rm -f "$t" "$m"
}

extract_watch() {
  # stdin = plain text; stdout = "TERM\t<term>" for each watchlist term present.
  local text_file="$WORK/.watch.$$"
  cat > "$text_file"
  if [ -n "$WATCHLIST" ]; then
    printf '%s' "$WATCHLIST" | tr ',' '\n' | while IFS= read -r term; do
      term="$(printf '%s' "$term" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -z "$term" ] && continue
      if grep -qiF -- "$term" "$text_file" 2>/dev/null; then
        printf 'TERM\t%s\n' "$term"
      fi
    done
  fi
  rm -f "$text_file"
}

# ---------- flatten ----------

flatten_source() {
  # $1 = source index, $2 = path
  local idx="$1" root="$2"
  local dir="$WORK/src$idx"
  mkdir -p "$dir/items"
  : > "$dir/keys"

  local files_list="$dir/.files"
  if [ -d "$root" ]; then
    find "$root" -type f -not -path '*/.git/*' -not -name '.*' 2>/dev/null | sort > "$files_list"
  elif [ -f "$root" ]; then
    printf '%s\n' "$root" > "$files_list"
  else
    die "source not found: $root"
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local e; e="$(ext_of "$f")"
    is_supported "$e" || continue

    local key; key="$(norm_key "$f")"
    [ -n "$key" ] || continue
    local sk; sk="$(safe_name "$key")"

    # First file wins a key collision; the loser is recorded so it can be
    # reported rather than silently dropped.
    if [ -f "$dir/items/$sk.meta" ]; then
      printf '%s\n' "$f" >> "$dir/collisions"
      continue
    fi

    read_text     "$f" "$e" > "$dir/items/$sk.text"
    read_headings "$f" "$e" > "$dir/items/$sk.headings"
    # Both writers append, then the file is sorted as a whole — `comm` in the
    # compare step requires sorted input and will misreport without this.
    {
      extract_values < "$dir/items/$sk.text"
      extract_watch  < "$dir/items/$sk.text"
    } | sort -u > "$dir/items/$sk.values"

    local title
    title="$(head -1 "$dir/items/$sk.headings" 2>/dev/null | cut -f2-)"
    [ -n "$title" ] || title="$(basename "$f")"

    local words
    words="$(wc -w < "$dir/items/$sk.text" 2>/dev/null | tr -d ' ')"

    {
      printf 'path\t%s\n'  "$f"
      printf 'mtime\t%s\n' "$(mtime "$f")"
      printf 'title\t%s\n' "$title"
      printf 'words\t%s\n' "${words:-0}"
    } > "$dir/items/$sk.meta"

    printf '%s\n' "$key" >> "$dir/keys"

    # Register every heading as a section key too.
    #
    # Sources routinely disagree about granularity: one keeps a section per
    # file, another keeps the whole thing in one document with headings. Without
    # this, every section-file in the split source looks "missing" from the
    # combined one, and the handful of real findings drown in false ones.
    cut -f2- "$dir/items/$sk.headings" 2>/dev/null | while IFS= read -r h; do
      [ -n "$h" ] || continue
      printf '%s\n' "$(norm_text "$h")" >> "$dir/sections"
    done
  done < "$files_list"

  sort -u -o "$dir/keys" "$dir/keys" 2>/dev/null || true
  [ -f "$dir/sections" ] && sort -u -o "$dir/sections" "$dir/sections" 2>/dev/null
  touch "$dir/sections"
}

key_in_source() {
  # $1 = source index, $2 = key.
  # Echoes how the key is present in that source: file | section | prefix | no
  local idx="$1" key="$2" sk
  sk="$(safe_name "$key")"
  if [ -f "$WORK/src$idx/items/$sk.meta" ]; then echo "file"; return; fi
  if grep -qxF -- "$key" "$WORK/src$idx/sections" 2>/dev/null; then echo "section"; return; fi
  # Prefix match, both directions, guarded by a length floor so short keys
  # like "a" or "id" don't match half the corpus.
  if [ "${#key}" -ge 4 ]; then
    if grep -qE "^$(printf '%s' "$key" | sed -e 's/[^A-Za-z0-9-]/./g')(-|$)" \
         "$WORK/src$idx/sections" "$WORK/src$idx/keys" 2>/dev/null; then
      echo "prefix"; return
    fi
  fi
  echo "no"
}

meta_get() { # $1 = meta file, $2 = field
  grep -m1 "^$2	" "$1" 2>/dev/null | cut -f2-
}

# ---------- argument parsing ----------

usage() {
  cat <<EOF
$PROG — find what differs between two or more sets of documents.

  $PROG compare --source LABEL=PATH --source LABEL=PATH [...]
                [--truth LABEL] [--watch "Term One,Term Two"]

      What is different across these sources? Reports values that disagree
      (numbers, dates, money, percentages) first and separately, then headings,
      then what is missing where.

      --truth LABEL   name the authoritative source; output becomes a to-do
                      list for the others. Omit it and the output stays neutral.
      --watch LIST    comma-separated terms to track alongside the values.

  $PROG trace   --source LABEL=PATH [...] --term "STRING" [--loose]

      Where does this value or phrase still appear? Use after a change to check
      it propagated, or after retiring wording to find the stragglers.

      --loose         tolerate different spacing and punctuation between words.

A source may be a file or a directory. Formats: .md .txt .html always;
.pdf needs pdftotext; .docx needs pandoc. Missing tools are reported and
skipped, never dropped silently. Everything runs locally.
EOF
}

# Help and the no-argument case are handled BEFORE the subcommand is claimed.
# Otherwise "$PROG --help" assigns --help to SUBCMD, falls through the option
# loop untouched, and dies on the missing --source check instead of helping.
case "${1:-}" in
  -h|--help|help|"") usage; [ -n "${1:-}" ] && exit 0; exit 2 ;;
esac

SUBCMD="$1"
shift

N_SRC=0
SRC_LABEL=()
SRC_PATH=()
TRUTH=""
TERM_ARG=""
LOOSE=0
WATCHLIST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      [ $# -ge 2 ] || die "--source needs LABEL=PATH"
      case "$2" in
        *=*) : ;;
        *) die "--source expects LABEL=PATH, got: $2" ;;
      esac
      SRC_LABEL[$N_SRC]="${2%%=*}"
      SRC_PATH[$N_SRC]="${2#*=}"
      N_SRC=$((N_SRC+1)); shift 2 ;;
    --truth) [ $# -ge 2 ] || die "--truth needs a LABEL"; TRUTH="$2"; shift 2 ;;
    --term)  [ $# -ge 2 ] || die "--term needs a STRING";  TERM_ARG="$2"; shift 2 ;;
    --watch) [ $# -ge 2 ] || die "--watch needs a list";   WATCHLIST="$2"; shift 2 ;;
    --loose) LOOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$N_SRC" -ge 1 ] || die "give at least one --source LABEL=PATH"

if [ -n "$TRUTH" ]; then
  found=0; i=0
  while [ $i -lt $N_SRC ]; do
    [ "${SRC_LABEL[$i]}" = "$TRUTH" ] && found=1
    i=$((i+1))
  done
  [ "$found" -eq 1 ] || die "--truth '$TRUTH' does not match any --source label"
fi

# Flatten every source once; both subcommands need it.
i=0
while [ $i -lt $N_SRC ]; do
  flatten_source "$i" "${SRC_PATH[$i]}"
  i=$((i+1))
done

report_skips() {
  if [ "$SKIPPED_PDF" -gt 0 ]; then
    echo "> Skipped $SKIPPED_PDF PDF file(s): \`pdftotext\` is not installed."
  fi
  if [ "$SKIPPED_DOCX" -gt 0 ]; then
    echo "> Skipped $SKIPPED_DOCX .docx file(s): \`pandoc\` is not installed."
  fi
  if [ "$SKIPPED_PDF" -gt 0 ] || [ "$SKIPPED_DOCX" -gt 0 ]; then echo; fi
}

# ---------- compare ----------

cmd_compare() {
  [ "$N_SRC" -ge 2 ] || die "compare needs at least two --source arguments"

  echo "# Difference report"
  echo
  echo "Generated $(date '+%Y-%m-%d %H:%M')"
  echo
  i=0
  while [ $i -lt $N_SRC ]; do
    local marker=""
    [ "${SRC_LABEL[$i]}" = "$TRUTH" ] && marker="  **(source of truth)**"
    echo "- \`${SRC_LABEL[$i]}\` — ${SRC_PATH[$i]}$marker"
    i=$((i+1))
  done
  echo
  if [ -z "$TRUTH" ]; then
    echo "No source of truth was named, so nothing below says who is right."
  else
    echo "Differences are stated as work to bring the other sources in line with \`$TRUTH\`."
  fi
  echo
  report_skips

  # Union of every key across sources.
  cat "$WORK"/src*/keys 2>/dev/null | sort -u > "$WORK/allkeys"

  # --- coverage: which items exist where ---
  : > "$WORK/only"
  : > "$WORK/shared"
  : > "$WORK/softmatch"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    local sk present absent soft filecount
    sk="$(safe_name "$key")"
    present=""; absent=""; soft=""; filecount=0
    i=0
    while [ $i -lt $N_SRC ]; do
      case "$(key_in_source "$i" "$key")" in
        file)    present="$present ${SRC_LABEL[$i]}"; filecount=$((filecount+1)) ;;
        section) soft="$soft ${SRC_LABEL[$i]}(as a section)" ;;
        prefix)  soft="$soft ${SRC_LABEL[$i]}(similar name)" ;;
        no)      absent="$absent ${SRC_LABEL[$i]}" ;;
      esac
      i=$((i+1))
    done
    # Only a genuine absence counts as a coverage finding. A key that turns up
    # as a heading elsewhere is present, just stored at a different grain.
    if [ -n "$absent" ]; then
      printf '%s\t%s\t%s\n' "$key" "${present# }" "${absent# }" >> "$WORK/only"
    elif [ -n "$soft" ]; then
      printf '%s\t%s\t%s\n' "$key" "${present# }" "${soft# }" >> "$WORK/softmatch"
    fi
    [ "$filecount" -ge 2 ] && printf '%s\n' "$key" >> "$WORK/shared"
  done < "$WORK/allkeys"

  # --- section 1: values (the loud one, first) ---
  echo "## Values that disagree"
  echo
  echo "Numbers, dates, money, and percentages found in one source but not another."
  echo "Prose gets reworded all the time; a number changing usually is not on purpose."
  echo
  local found_vals=0
  if [ -s "$WORK/shared" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      local sk; sk="$(safe_name "$key")"
      local blockf="$WORK/.vblock"
      : > "$blockf"
      i=0
      while [ $i -lt $N_SRC ]; do
        if [ -f "$WORK/src$i/items/$sk.values" ]; then
          j=0
          while [ $j -lt $N_SRC ]; do
            if [ $j -ne $i ] && [ -f "$WORK/src$j/items/$sk.values" ]; then
              local diff_out
              diff_out="$(comm -23 "$WORK/src$i/items/$sk.values" "$WORK/src$j/items/$sk.values" 2>/dev/null \
                          | cut -f2- | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
              if [ -n "$diff_out" ]; then
                printf -- '- in `%s` but not `%s`: %s\n' \
                  "${SRC_LABEL[$i]}" "${SRC_LABEL[$j]}" "$diff_out" >> "$blockf"
              fi
            fi
            j=$((j+1))
          done
        fi
        i=$((i+1))
      done
      if [ -s "$blockf" ]; then
        found_vals=1
        echo "**$key**"
        echo
        cat "$blockf"
        echo
      fi
    done < "$WORK/shared"
  fi
  [ "$found_vals" -eq 0 ] && echo "_No value conflicts found._" && echo

  # --- section 2: structure ---
  echo "## Structure"
  echo
  local found_struct=0
  if [ -s "$WORK/shared" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      local sk; sk="$(safe_name "$key")"
      local blockf="$WORK/.sblock"
      : > "$blockf"
      i=0
      while [ $i -lt $N_SRC ]; do
        if [ -f "$WORK/src$i/items/$sk.headings" ]; then
          j=$((i+1))
          while [ $j -lt $N_SRC ]; do
            if [ -f "$WORK/src$j/items/$sk.headings" ]; then
              local a b onlya onlyb
              a="$WORK/.ha"; b="$WORK/.hb"
              cut -f2- "$WORK/src$i/items/$sk.headings" | sort -u > "$a"
              cut -f2- "$WORK/src$j/items/$sk.headings" | sort -u > "$b"
              onlya="$(comm -23 "$a" "$b" 2>/dev/null | tr '\n' '|' | sed -e 's/|/, /g' -e 's/, $//')"
              onlyb="$(comm -13 "$a" "$b" 2>/dev/null | tr '\n' '|' | sed -e 's/|/, /g' -e 's/, $//')"
              [ -n "$onlya" ] && printf -- '- missing from `%s`, present in `%s`: %s\n' \
                "${SRC_LABEL[$j]}" "${SRC_LABEL[$i]}" "$onlya" >> "$blockf"
              [ -n "$onlyb" ] && printf -- '- missing from `%s`, present in `%s`: %s\n' \
                "${SRC_LABEL[$i]}" "${SRC_LABEL[$j]}" "$onlyb" >> "$blockf"
              rm -f "$a" "$b"
            fi
            j=$((j+1))
          done
        fi
        i=$((i+1))
      done
      if [ -s "$blockf" ]; then
        found_struct=1
        echo "**$key**"
        i=0
        while [ $i -lt $N_SRC ]; do
          if [ -f "$WORK/src$i/items/$sk.meta" ]; then
            printf '  - `%s` last modified %s, %s words\n' \
              "${SRC_LABEL[$i]}" \
              "$(meta_get "$WORK/src$i/items/$sk.meta" mtime)" \
              "$(meta_get "$WORK/src$i/items/$sk.meta" words)"
          fi
          i=$((i+1))
        done
        echo
        cat "$blockf"
        echo
      fi
    done < "$WORK/shared"
  fi
  [ "$found_struct" -eq 0 ] && echo "_No heading differences found among matched items._" && echo

  # --- section 3: coverage ---
  echo "## Missing entirely"
  echo
  echo "Not found in these sources at any level — not as a file, not as a heading."
  echo
  if [ -s "$WORK/only" ]; then
    while IFS=$'\t' read -r key present absent; do
      [ -n "$key" ] || continue
      printf -- '- **%s** — in: %s · **not in: %s**\n' "$key" "${present:-none}" "$absent"
    done < "$WORK/only"
  else
    echo "_Nothing is missing outright._"
  fi
  echo

  if [ -s "$WORK/softmatch" ]; then
    echo "## Stored at a different grain"
    echo
    echo "Present everywhere, but as a file in one source and a heading in another."
    echo "Usually fine — listed so a real gap does not hide among them."
    echo
    while IFS=$'\t' read -r key present soft; do
      [ -n "$key" ] || continue
      printf -- '- **%s** — file in: %s · elsewhere: %s\n' "$key" "${present:-none}" "$soft"
    done < "$WORK/softmatch"
    echo
  fi

  # --- section 4: things needing a human ---
  echo "## Needs your eye"
  echo
  local need=0
  i=0
  while [ $i -lt $N_SRC ]; do
    if [ -s "$WORK/src$i/collisions" ]; then
      need=1
      echo "- \`${SRC_LABEL[$i]}\` has files that normalize to a name already taken; only the first was compared:"
      sed -e 's/^/  - /' "$WORK/src$i/collisions"
    fi
    i=$((i+1))
  done
  # Items present everywhere whose titles disagree — a likely mis-pairing.
  if [ -s "$WORK/shared" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      local sk; sk="$(safe_name "$key")"
      local first="" mismatch=0
      i=0
      while [ $i -lt $N_SRC ]; do
        if [ -f "$WORK/src$i/items/$sk.meta" ]; then
          local t; t="$(meta_get "$WORK/src$i/items/$sk.meta" title)"
          if [ -z "$first" ]; then first="$t"
          elif [ "$t" != "$first" ]; then mismatch=1; fi
        fi
        i=$((i+1))
      done
      if [ "$mismatch" -eq 1 ]; then
        need=1
        echo "- **$key** was matched by filename, but the titles differ across sources — confirm these are the same document."
      fi
    done < "$WORK/shared"
  fi
  [ "$need" -eq 0 ] && echo "_Nothing ambiguous._"
  echo

  echo "---"
  echo
  echo "_Last-modified times are filesystem facts, not verdicts. A file that was"
  echo "touched but not edited will look newer than it is._"
}

# ---------- trace ----------

cmd_trace() {
  [ -n "$TERM_ARG" ] || die "trace needs --term \"STRING\""

  echo "# Trace: \`$TERM_ARG\`"
  echo
  echo "Generated $(date '+%Y-%m-%d %H:%M')"
  echo
  report_skips

  local pattern="$TERM_ARG" total=0
  if [ "$LOOSE" -eq 1 ]; then
    # Loose: tolerate different spacing and punctuation between words.
    pattern="$(printf '%s' "$TERM_ARG" | sed -e 's/[^A-Za-z0-9]\{1,\}/[^A-Za-z0-9]*/g')"
  fi

  i=0
  while [ $i -lt $N_SRC ]; do
    echo "## \`${SRC_LABEL[$i]}\` — ${SRC_PATH[$i]}"
    echo
    local hits_here=0
    if [ -s "$WORK/src$i/keys" ]; then
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        local sk; sk="$(safe_name "$key")"
        local f="$WORK/src$i/items/$sk.text"
        [ -f "$f" ] || continue
        local hits
        if [ "$LOOSE" -eq 1 ]; then
          hits="$(grep -inE -- "$pattern" "$f" 2>/dev/null)"
        else
          hits="$(grep -inF -- "$pattern" "$f" 2>/dev/null)"
        fi
        if [ -n "$hits" ]; then
          local n; n="$(printf '%s\n' "$hits" | grep -c . )"
          hits_here=$((hits_here + n))
          total=$((total + n))
          printf -- '- **%s** (%s hit(s)) — `%s`\n' \
            "$key" "$n" "$(meta_get "$WORK/src$i/items/$sk.meta" path)"
          printf '%s\n' "$hits" | head -5 | sed -e 's/^/    - line /'
          [ "$n" -gt 5 ] && echo "    - _(showing first 5 of $n)_"
        fi
      done < "$WORK/src$i/keys"
    fi
    [ "$hits_here" -eq 0 ] && echo "_No hits._"
    echo
    i=$((i+1))
  done

  echo "---"
  echo
  echo "**$total hit(s) across $N_SRC source(s).**"
  if [ "$total" -gt 0 ]; then
    echo
    echo "_Every hit is a place this still appears. If it should be gone, each one is a to-do._"
  fi
}

case "$SUBCMD" in
  compare) cmd_compare ;;
  trace)   cmd_trace ;;
  *) die "unknown subcommand '$SUBCMD' (expected: compare, trace)" ;;
esac
