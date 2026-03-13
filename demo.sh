#!/usr/bin/env bash
# demo.sh — Live demo of arduino-capture
# Usage:
#   ./demo.sh              capture for 60s, print to terminal
#   ./demo.sh 120          capture for 120s
#   ./demo.sh 60 out.log   capture for 60s, save to log, analyze at end

set -euo pipefail

DURATION="${1:-60}"
LOGFILE="${2:-}"
BIN="$(dirname "$0")/zig-out/bin/arduino-capture"
DEVICE="/dev/ttyACM0"
SEP="────────────────────────────────────────────────────"

# ── preflight ────────────────────────────────────────────────────────────────

if [[ ! -x "$BIN" ]]; then
    echo "Binary not found: $BIN"
    echo "Run 'zig build' first."
    exit 1
fi

if [[ ! -c "$DEVICE" ]]; then
    echo "Device not found: $DEVICE"
    echo "Check that the Arduino is plugged in."
    exit 1
fi

if ! groups | grep -qw dialout; then
    echo "WARNING: user $(whoami) is not in the dialout group."
    echo "  Run: sudo usermod -aG dialout \$USER  (then log out/in)"
fi

# ── header ───────────────────────────────────────────────────────────────────

echo "$SEP"
echo "  arduino-capture — hardware entropy demo"
echo "$SEP"
echo "  Device : $DEVICE"
echo "  Binary : $BIN"
echo "  Capture: ${DURATION}s"
[[ -n "$LOGFILE" ]] && echo "  Logfile: $LOGFILE"
echo "$SEP"
echo ""
echo "  NOTE: ~40s cold-start before clean output appears."
echo "        The Arduino entropy pool needs to fill before"
echo "        the sketch emits valid 16-char strings."
echo ""
echo "  Capturing — Ctrl+C to stop early..."
echo "$SEP"
echo ""

# ── capture ──────────────────────────────────────────────────────────────────

START_TS=$(date +%s)
TMPLOG=$(mktemp /tmp/arduino_capture_XXXXXX.txt)
trap 'rm -f "$TMPLOG"' EXIT

if [[ -n "$LOGFILE" ]]; then
    timeout "$DURATION" "$BIN" "$LOGFILE" 2>/dev/null | tee "$TMPLOG" || true
else
    timeout "$DURATION" "$BIN" 2>/dev/null | tee "$TMPLOG" || true
fi

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# ── analysis ─────────────────────────────────────────────────────────────────

echo ""
echo "$SEP"
echo "  SUMMARY  (${ELAPSED}s elapsed)"
echo "$SEP"

TOTAL=$(wc -l < "$TMPLOG" || echo 0)
CLEAN=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$TMPLOG" || echo 0)
NOISE=$(( TOTAL - CLEAN ))

echo "  Total records  : $TOTAL"
echo "  Clean (16-char): $CLEAN"
echo "  Noise/merged   : $NOISE  (cold-start artifacts)"

if [[ "$CLEAN" -gt 0 ]]; then
    CHARS=$(( CLEAN * 16 ))
    # entropy: log2(62^16) = 16 * log2(62) ≈ 16 * 5.954 = 95.27 bits
    ENTROPY_INT=$(( CLEAN * 95 ))
    RATE_INT=$(( CLEAN * 100 / ELAPSED ))

    echo "  Characters     : $CHARS"
    echo "  Entropy (est.) : ~${ENTROPY_INT} bits  (~95 bits/string)"
    echo "  Rate           : ${RATE_INT}  strings/100s  (~$(( RATE_INT / 100 )).$(( RATE_INT % 100 )) strings/sec)"

    echo ""
    echo "  Character frequency (top 10):"
    grep -oE '[0-9A-Za-z]{16}' "$TMPLOG" | fold -w1 | sort | uniq -c | sort -rn | head -10 \
        | awk '{printf "    %4d × %s\n", $1, $2}'

    echo ""
    echo "  Last 5 strings:"
    grep -E '^[0-9]+ [0-9A-Za-z]{16}$' "$TMPLOG" | tail -5 \
        | awk '{printf "    %s  %s\n", $1, $2}'
fi

echo "$SEP"
echo ""
