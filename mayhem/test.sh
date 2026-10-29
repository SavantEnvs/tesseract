#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer OCR tests against the `tesseract` CLI that mayhem/build.sh built
# with normal flags (build-tests/tesseract). Each case OCRs a committed image with a known text and
# asserts the recognized output, so a neutered/no-op program fails. Runs only; never compiles.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


TESS="$SRC/build-tests/bin/tesseract"
IMG="$SRC/mayhem/testdata"
export TESSDATA_PREFIX="$SRC/tessdata"
[ -x "$TESS" ] || { echo "missing $TESS (mayhem/build.sh should have built it)" >&2; emit_ctrf cli-ocr 0 1; exit 1; }
[ -f "$TESSDATA_PREFIX/eng.traineddata" ] || { echo "missing eng.traineddata" >&2; emit_ctrf cli-ocr 0 1; exit 1; }

passed=0; failed=0
check() {  # name expected actual
  if [ "$2" = "$3" ]; then passed=$((passed+1)); echo "PASS $1"
  else failed=$((failed+1)); echo "FAIL $1: expected [$2] got [$3]"; fi
}
norm() { tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }

check ocr-hello      "Hello World 2024"                       "$("$TESS" "$IMG/hello.png"  - 2>/dev/null | norm)"
check ocr-fox        "The quick brown fox jumps over the lazy dog" "$("$TESS" "$IMG/fox.png"    - 2>/dev/null | norm)"
check ocr-digits     "FUZZING 31337"                          "$("$TESS" "$IMG/digits.png" - 2>/dev/null | norm)"
check ocr-psm7-line  "Hello World 2024"                       "$("$TESS" "$IMG/hello.png" - --psm 7 2>/dev/null | norm)"
check ocr-oem-lstm   "FUZZING 31337"                          "$("$TESS" "$IMG/digits.png" - --oem 1 -l eng 2>/dev/null | norm)"
check ocr-stdin-in   "FUZZING 31337"                          "$("$TESS" stdin - < "$IMG/digits.png" 2>/dev/null | norm)"

# TSV: one row per word, text in column 12; the word-level rows must give the same words in order.
words="$("$TESS" "$IMG/fox.png" - tsv 2>/dev/null | awk -F'\t' '$1==5 && $12!="" {printf "%s ", $12}' | norm)"
check tsv-words      "The quick brown fox jumps over the lazy dog" "$words"
nlines="$("$TESS" "$IMG/fox.png" - tsv 2>/dev/null | awk -F'\t' '$1==4' | wc -l)"
check tsv-lines      "2" "$nlines"

# hOCR: word spans carry the words and bounding boxes.
hocr="$("$TESS" "$IMG/hello.png" - hocr 2>/dev/null)"
check hocr-words     "Hello World 2024" "$(printf '%s' "$hocr" | grep -o "class='ocrx_word'[^>]*>[^<]*" | sed 's/.*>//' | tr '\n' ' ' | norm)"
printf '%s' "$hocr" | grep -q "ocrx_word' id='word_1_3' title='bbox [0-9]* [0-9]* [0-9]* [0-9]*;" \
  && check hocr-bbox ok ok || check hocr-bbox ok missing

check list-langs     "eng" "$("$TESS" --list-langs 2>/dev/null | grep -x eng)"

emit_ctrf cli-ocr "$passed" "$failed" 0
