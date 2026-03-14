#!/usr/bin/env bash
# test.sh — arduino-capture test suite
# Usage:
#   ./test.sh                              run all tests (requires live Arduino)
#   ./test.sh --offline                    skip live-device tests
#   ./test.sh --device /dev/ttyACM1        override device path
#   LIVE_TEST_SECS=90 ./test.sh            extend live capture window (default: 30)
#
# Prints PASS / FAIL / SKIP for each test case.
# Exits 0 if all run tests pass, 1 if any fail.

set -uo pipefail

# ── configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/zig-out/bin/arduino-capture"
ANALYZE="$SCRIPT_DIR/analyze.sh"
DEMO="$SCRIPT_DIR/demo.sh"
SAMPLE="$SCRIPT_DIR/sample_output.txt"
DEVICE="${ARDUINO_DEVICE:-/dev/ttyACM0}"
LIVE_TEST_SECS="${LIVE_TEST_SECS:-30}"
MIN_STRINGS="${MIN_STRINGS:-3}"
OFFLINE=0

for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        --device)  shift; DEVICE="$1" ;;
    esac
done

# ── helpers ───────────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "PASS: $*"; (( PASS_COUNT++ )) || true; }
fail() { echo "FAIL: $*"; (( FAIL_COUNT++ )) || true; }
skip() { echo "SKIP: $* (offline mode)"; (( SKIP_COUNT++ )) || true; }

require_live() {
    if [[ "$OFFLINE" -eq 1 ]]; then skip "$1"; return 1; fi
    return 0
}

SEP="────────────────────────────────────────────────────"

echo "$SEP"
echo "  arduino-capture test suite"
echo "  Binary : $BIN"
echo "  Device : $DEVICE"
echo "  Offline: $OFFLINE"
[[ "$OFFLINE" -eq 0 ]] && \
    echo "  NOTE: cold-start takes ~40s; live tests use ${LIVE_TEST_SECS}s window"
echo "$SEP"
echo ""

# ── 1. binary and scripts exist ───────────────────────────────────────────────

T="binary exists at zig-out/bin/arduino-capture"
[[ -f "$BIN" ]] && pass "$T" || fail "$T"

T="binary is executable"
[[ -x "$BIN" ]] && pass "$T" || fail "$T"

T="analyze.sh exists and is executable"
[[ -x "$ANALYZE" ]] && pass "$T" || fail "$T"

T="demo.sh exists and is executable"
[[ -x "$DEMO" ]] && pass "$T" || fail "$T"

T="sample_output.txt exists and is non-empty"
[[ -s "$SAMPLE" ]] && pass "$T" || fail "$T"

# ── 2. sample_output.txt format ───────────────────────────────────────────────

T="sample_output.txt: all lines match expected format"
if [[ -s "$SAMPLE" ]]; then
    TOTAL=$(wc -l < "$SAMPLE")
    CLEAN=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$SAMPLE" || echo 0)
    if [[ "$CLEAN" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
        pass "$T ($TOTAL lines)"
    else
        fail "$T — $CLEAN/$TOTAL matched; check sample_output.txt"
    fi
else
    fail "$T — file missing or empty"
fi

# ── 3. demo.sh preflight: missing binary ──────────────────────────────────────

T="demo.sh exits non-zero when binary is missing"
if [[ -x "$BIN" ]]; then
    TMPBIN="${BIN}.bak_$$"
    mv "$BIN" "$TMPBIN"
    set +e; bash "$DEMO" 1 >/dev/null 2>&1; RC=$?; set -e
    mv "$TMPBIN" "$BIN"
    [[ "$RC" -ne 0 ]] && pass "$T (rc=$RC)" || fail "$T — expected non-zero, got 0"
else
    skip "$T — binary absent, cannot test"
fi

# ── 4. demo.sh preflight: wrong device ────────────────────────────────────────

T="demo.sh exits non-zero when /dev/ttyACM0 is absent"
if [[ ! -c "/dev/ttyACM0" ]]; then
    set +e; bash "$DEMO" 1 >/dev/null 2>&1; RC=$?; set -e
    [[ "$RC" -ne 0 ]] && pass "$T (rc=$RC)" || fail "$T — expected non-zero"
else
    skip "$T — /dev/ttyACM0 present; preflight would pass"
fi

# ── 5. stderr / stdout separation ─────────────────────────────────────────────

T="status messages go to stderr, data to stdout"
if [[ ! -c "$DEVICE" ]]; then
    # Device absent: program should fail-open on stderr, nothing on stdout
    SO=$(mktemp /tmp/ac_so_XXXXXX); SE=$(mktemp /tmp/ac_se_XXXXXX)
    set +e; "$BIN" >"$SO" 2>"$SE"; RC=$?; set -e
    SO_BYTES=$(wc -c < "$SO")
    SE_MSG=$(grep -c "Failed to open" "$SE" 2>/dev/null || echo 0)
    rm -f "$SO" "$SE"
    if [[ "$RC" -ne 0 && "$SE_MSG" -gt 0 && "$SO_BYTES" -eq 0 ]]; then
        pass "$T (error on stderr, nothing on stdout)"
    else
        fail "$T — rc=$RC se_msg=$SE_MSG so_bytes=$SO_BYTES"
    fi
else
    # Device present: run briefly, verify startup banner is on stderr
    SO=$(mktemp /tmp/ac_so_XXXXXX); SE=$(mktemp /tmp/ac_se_XXXXXX)
    set +e; timeout 3 "$BIN" >"$SO" 2>"$SE" || true; set -e
    SE_OK=$(grep -c "Capturing from" "$SE" 2>/dev/null || echo 0)
    SO_LINES=$(wc -l < "$SO")
    rm -f "$SO" "$SE"
    [[ "$SE_OK" -gt 0 ]] \
        && pass "$T (startup on stderr; stdout had $SO_LINES lines)" \
        || fail "$T — startup message not found on stderr"
fi

# ── 6. file logging: append, not truncate ────────────────────────────────────

T="file logging appends (does not truncate existing content)"
if require_live "$T"; then
    if [[ -c "$DEVICE" && -x "$BIN" ]]; then
        LOGFILE=$(mktemp /tmp/ac_log_XXXXXX.txt)
        echo "SENTINEL_MUST_SURVIVE" > "$LOGFILE"
        PRE=$(wc -c < "$LOGFILE")
        set +e; timeout 5 "$BIN" "$LOGFILE" 2>/dev/null || true; set -e
        POST=$(wc -c < "$LOGFILE")
        SENTINEL=$(grep -c "SENTINEL_MUST_SURVIVE" "$LOGFILE" || echo 0)
        rm -f "$LOGFILE"
        if [[ "$SENTINEL" -gt 0 && "$POST" -ge "$PRE" ]]; then
            pass "$T (grew $PRE→$POST bytes, sentinel intact)"
        else
            fail "$T — sentinel=$SENTINEL pre=$PRE post=$POST"
        fi
    else
        fail "$T — device $DEVICE absent or binary not executable"
    fi
fi

# ── 7. live capture: program produces output ──────────────────────────────────

CAPTURE_TMP=""
T="live capture produces output in ${LIVE_TEST_SECS}s"
if require_live "$T"; then
    if [[ -c "$DEVICE" && -x "$BIN" ]]; then
        CAPTURE_TMP=$(mktemp /tmp/ac_live_XXXXXX.txt)
        echo "  (running ${LIVE_TEST_SECS}s capture; cold-start ~40s is normal)" >&2
        set +e; timeout "$LIVE_TEST_SECS" "$BIN" 2>/dev/null > "$CAPTURE_TMP" || true; set -e
        LINE_COUNT=$(wc -l < "$CAPTURE_TMP")
        [[ "$LINE_COUNT" -gt 0 ]] \
            && pass "$T ($LINE_COUNT lines)" \
            || fail "$T — no output; is Arduino running Generate_Alphanumeric?"
    else
        fail "$T — device $DEVICE absent or binary not executable"
    fi
fi

# ── 8. output format validation ───────────────────────────────────────────────

T="output format: clean lines match '^[0-9]+ [0-9A-Za-z]{16}$'"
if require_live "$T"; then
    if [[ -n "$CAPTURE_TMP" && -s "$CAPTURE_TMP" ]]; then
        TOTAL=$(wc -l < "$CAPTURE_TMP")
        CLEAN=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$CAPTURE_TMP" || echo 0)
        NOISE=$(( TOTAL - CLEAN ))
        if [[ "$CLEAN" -gt 0 ]]; then
            pass "$T ($CLEAN/$TOTAL clean; $NOISE noise from cold-start expected)"
        else
            fail "$T — 0/$TOTAL matched; check sketch and baud rate"
        fi
    else
        fail "$T — no capture data (live capture failed or skipped)"
    fi
fi

# ── 9. rate check ─────────────────────────────────────────────────────────────

T="rate: at least $MIN_STRINGS clean strings in ${LIVE_TEST_SECS}s"
if require_live "$T"; then
    if [[ -c "$DEVICE" && -x "$BIN" ]]; then
        RATE_TMP=$(mktemp /tmp/ac_rate_XXXXXX.txt)
        set +e; timeout "$LIVE_TEST_SECS" "$BIN" 2>/dev/null > "$RATE_TMP" || true; set -e
        CLEAN=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$RATE_TMP" || echo 0)
        TOTAL=$(wc -l < "$RATE_TMP")
        rm -f "$RATE_TMP"
        if [[ "$CLEAN" -ge "$MIN_STRINGS" ]]; then
            pass "$T ($CLEAN clean strings)"
        else
            fail "$T — $CLEAN/$MIN_STRINGS clean strings in ${LIVE_TEST_SECS}s" \
                "(hint: set LIVE_TEST_SECS=90 to clear cold-start)"
        fi
    else
        fail "$T — device $DEVICE absent or binary not executable"
    fi
fi

# ── 10. log file grows over consecutive runs ──────────────────────────────────

T="log file grows across consecutive program runs"
if require_live "$T"; then
    if [[ -c "$DEVICE" && -x "$BIN" ]]; then
        GROWFILE=$(mktemp /tmp/ac_grow_XXXXXX.txt)
        set +e
        timeout 4 "$BIN" "$GROWFILE" 2>/dev/null || true
        SIZE_A=$(wc -c < "$GROWFILE")
        timeout 4 "$BIN" "$GROWFILE" 2>/dev/null || true
        SIZE_B=$(wc -c < "$GROWFILE")
        set -e
        rm -f "$GROWFILE"
        if [[ "$SIZE_B" -gt "$SIZE_A" ]]; then
            pass "$T (grew $SIZE_A→$SIZE_B bytes)"
        elif [[ "$SIZE_A" -eq 0 ]]; then
            fail "$T — file still 0 bytes after 8s (still in cold-start?)"
        else
            fail "$T — no growth: before=$SIZE_A after=$SIZE_B"
        fi
    else
        fail "$T — device $DEVICE absent or binary not executable"
    fi
fi

# ── 11. stdout only contains data lines (no status mixed in) ─────────────────

T="live device: stdout contains only data lines (no status mixed in)"
if require_live "$T"; then
    if [[ -c "$DEVICE" && -x "$BIN" ]]; then
        SO=$(mktemp /tmp/ac_so2_XXXXXX); SE=$(mktemp /tmp/ac_se2_XXXXXX)
        set +e; timeout 5 "$BIN" >"$SO" 2>"$SE" || true; set -e
        SO_LINES=$(wc -l < "$SO")
        # Any line on stdout that is non-empty must match the data format
        BAD=$(grep -cvE '^([0-9]+ [0-9A-Za-z]+)?$' "$SO" 2>/dev/null || echo 0)
        SE_DATA=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$SE" 2>/dev/null || echo 0)
        rm -f "$SO" "$SE"
        if [[ "$BAD" -eq 0 && "$SE_DATA" -eq 0 ]]; then
            pass "$T (stdout=$SO_LINES lines, all valid; no data on stderr)"
        else
            fail "$T — bad_stdout=$BAD data_on_stderr=$SE_DATA"
        fi
    else
        fail "$T — device $DEVICE absent or binary not executable"
    fi
fi

# clean up live capture temp file
[[ -n "$CAPTURE_TMP" ]] && rm -f "$CAPTURE_TMP"

# ── 12. analyze.sh correctness ────────────────────────────────────────────────

T="analyze.sh exits 0 on sample_output.txt"
if [[ -x "$ANALYZE" && -s "$SAMPLE" ]]; then
    set +e; OUTPUT=$(bash "$ANALYZE" "$SAMPLE" 2>&1); RC=$?; set -e
    [[ "$RC" -eq 0 ]] && pass "$T" || { fail "$T (rc=$RC)"; echo "  $OUTPUT" >&2; }
else
    fail "$T — analyze.sh or sample_output.txt missing"
fi

T="analyze.sh reports correct clean count"
if [[ -x "$ANALYZE" && -s "$SAMPLE" ]]; then
    EXPECTED=$(grep -cE '^[0-9]+ [0-9A-Za-z]{16}$' "$SAMPLE" || echo 0)
    set +e; OUTPUT=$(bash "$ANALYZE" "$SAMPLE" 2>&1); set -e
    REPORTED=$(echo "$OUTPUT" | grep -oP 'Clean \(16-char\):\s*\K[0-9]+' || echo -1)
    [[ "$REPORTED" -eq "$EXPECTED" ]] \
        && pass "$T (reported $REPORTED)" \
        || fail "$T — reported $REPORTED, expected $EXPECTED"
else
    fail "$T — prerequisites missing"
fi

T="analyze.sh output contains entropy estimate"
if [[ -x "$ANALYZE" && -s "$SAMPLE" ]]; then
    set +e; OUTPUT=$(bash "$ANALYZE" "$SAMPLE" 2>&1); set -e
    echo "$OUTPUT" | grep -qE 'Bits \(est\.\).*[0-9]+' \
        && pass "$T" || fail "$T — entropy line not found in output"
else
    fail "$T — prerequisites missing"
fi

T="analyze.sh exits non-zero for missing file"
set +e; bash "$ANALYZE" /tmp/no_such_file_ac_$$ 2>/dev/null; RC=$?; set -e
[[ "$RC" -ne 0 ]] && pass "$T (rc=$RC)" || fail "$T — expected non-zero"

T="analyze.sh exits non-zero with no arguments"
set +e; bash "$ANALYZE" 2>/dev/null; RC=$?; set -e
[[ "$RC" -ne 0 ]] && pass "$T (rc=$RC)" || fail "$T — expected non-zero"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "$SEP"
TOTAL=$(( PASS_COUNT + FAIL_COUNT + SKIP_COUNT ))
echo "  $PASS_COUNT passed  |  $FAIL_COUNT failed  |  $SKIP_COUNT skipped  ($TOTAL total)"
[[ "$OFFLINE" -eq 1 ]] && echo "  (offline mode: live-device tests skipped)"
echo "$SEP"
echo ""

[[ "$FAIL_COUNT" -gt 0 ]] && exit 1 || exit 0
