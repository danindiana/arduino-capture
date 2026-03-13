#!/usr/bin/env bash
# analyze.sh — Analyze a captured arduino-capture log file
# Usage: ./analyze.sh entropy.log

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <logfile>"
    echo "  The log file should be in the format produced by arduino-capture:"
    echo "  <unix_timestamp> <string>"
    echo "  one entry per line."
    exit 1
fi

FILE="$1"
SEP="────────────────────────────────────────────────────"

if [[ ! -f "$FILE" ]]; then
    echo "File not found: $FILE"
    exit 1
fi

echo "$SEP"
echo "  arduino-capture log analysis: $FILE"
echo "$SEP"

TOTAL=$(wc -l < "$FILE")
CLEAN=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$FILE" || echo 0)
NOISE=$(( TOTAL - CLEAN ))

echo "  Total records  : $TOTAL"
echo "  Clean (16-char): $CLEAN"
echo "  Noise/merged   : $NOISE"

if [[ "$CLEAN" -eq 0 ]]; then
    echo ""
    echo "  No clean 16-char strings found. Check device and sketch."
    exit 0
fi

# Timestamps
FIRST_TS=$(grep -E '^[0-9]+ [0-9A-Za-z]{16}$' "$FILE" | head -1 | awk '{print $1}')
LAST_TS=$(grep -E '^[0-9]+ [0-9A-Za-z]{16}$' "$FILE" | tail -1 | awk '{print $1}')
ELAPSED=$(( LAST_TS - FIRST_TS ))
FIRST_DATE=$(date -d "@$FIRST_TS" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -r "$FIRST_TS" '+%Y-%m-%d %H:%M:%S UTC')
LAST_DATE=$(date -d "@$LAST_TS"  '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -r "$LAST_TS"  '+%Y-%m-%d %H:%M:%S UTC')

echo ""
echo "  Timespan"
echo "  ┌─ first : $FIRST_DATE  ($FIRST_TS)"
echo "  └─ last  : $LAST_DATE  ($LAST_TS)"
echo "  Elapsed  : ${ELAPSED}s  (~$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s)"

# Rate
if [[ "$ELAPSED" -gt 0 ]]; then
    RATE_INT=$(( CLEAN * 100 / ELAPSED ))
    echo "  Rate     : $(( RATE_INT / 100 )).$(printf '%02d' $(( RATE_INT % 100 ))) strings/sec"
fi

# Entropy
CHARS=$(( CLEAN * 16 ))
ENTROPY_INT=$(( CLEAN * 95 ))
echo ""
echo "  Entropy estimate"
echo "  Characters     : $CHARS"
echo "  Bits (est.)    : ~${ENTROPY_INT}  (assuming 95 bits/string, log2(62^16))"
if [[ "$ELAPSED" -gt 0 ]]; then
    BPS=$(( ENTROPY_INT / ELAPSED ))
    echo "  Bits/sec (est.): ~${BPS}"
fi

# String length distribution
echo ""
echo "  String length distribution:"
awk '{print length($2)}' "$FILE" | sort -n | uniq -c \
    | awk '{printf "    length %3d: %4d occurrences\n", $2, $1}'

# Character frequency
echo ""
echo "  Character frequency:"
grep -E '^[0-9]+ [0-9A-Za-z]{16}$' "$FILE" | awk '{print $2}' | fold -w1 | sort | uniq -c | sort -rn \
    | awk 'BEGIN{tot=0} {tot+=$1} END{} 1' \
    | awk '{print $1, $2}' > /tmp/_ac_freq.txt

TOTAL_CHARS=$(awk '{s+=$1}END{print s}' /tmp/_ac_freq.txt)

echo "  Total chars sampled: $TOTAL_CHARS  (expected uniform across 62)"
EXPECTED=$(( TOTAL_CHARS / 62 ))
echo "  Expected per char (uniform): ~$EXPECTED"
echo ""
echo "  Top 10 most frequent:"
head -10 /tmp/_ac_freq.txt | awk -v tot="$TOTAL_CHARS" \
    '{printf "    %s: %4d  (%.1f%%)\n", $2, $1, ($1/tot)*100}'
echo ""
echo "  Bottom 10 least frequent:"
tail -10 /tmp/_ac_freq.txt | sort -n | awk -v tot="$TOTAL_CHARS" \
    '{printf "    %s: %4d  (%.1f%%)\n", $2, $1, ($1/tot)*100}'

rm -f /tmp/_ac_freq.txt

# Sample output
echo ""
echo "  Sample strings (first 5 clean):"
grep -E '^[0-9]+ [0-9A-Za-z]{16}$' "$FILE" | head -5 \
    | awk '{printf "    %s  %s\n", $1, $2}'
echo ""
echo "  Sample strings (last 5 clean):"
grep -E '^[0-9]+ [0-9A-Za-z]{16}$' "$FILE" | tail -5 \
    | awk '{printf "    %s  %s\n", $1, $2}'

echo "$SEP"
