#!/usr/bin/env bash
#
# mayhem/build.sh — build tesseract's libFuzzer harnesses (sanitized) AND the functional-test CLI
# (normal flags). Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline: every
# dependency (Leptonica, libtiff, the eng model) is an apt package baked into the image.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# CC/CXX come from the environment: passing -DCMAKE_C_COMPILER=clang makes a re-run wipe the cache
# (cmake caches the resolved /usr/bin/clang), so the build would not be idempotent.
CMAKE_COMMON=(-G Ninja
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF
  -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON -DGRAPHICS_DISABLED=ON
  -DENABLE_CCACHE=OFF -DENABLE_PRECOMPILED_HEADERS=OFF -DOPENMP_BUILD=OFF)

# The harness loads <binary dir>/tessdata (upstream's configs + the eng model); take the model from
# the apt package so nothing is downloaded.
cp /usr/share/tesseract-ocr/5/tessdata/eng.traineddata "$SRC/tessdata/eng.traineddata"

# 1) Sanitized libtesseract (OSS-Fuzz also builds it with -D_GLIBCXX_DEBUG).
FUZZ_CXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -D_GLIBCXX_DEBUG"
cmake -S . -B build-fuzz "${CMAKE_COMMON[@]}" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$FUZZ_CXXFLAGS" \
  -DCMAKE_C_FLAGS_RELEASE="" -DCMAKE_CXX_FLAGS_RELEASE=""
cmake --build build-fuzz --target libtesseract -j"$MAYHEM_JOBS"
LIBTESS="$(find build-fuzz -maxdepth 1 -name 'libtesseract*.a' | head -n1)"
[ -n "$LIBTESS" ] || { echo "libtesseract static lib not found" >&2; exit 1; }

LEPT_CFLAGS="$(pkg-config --cflags lept)"
LEPT_LIBS="$(pkg-config --libs lept)"

# 2) Harnesses: fuzzer + standalone reproducer, both with the LSan hook.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

build_harness() {  # name [extra -D flags...]
  local name="$1"; shift
  $CXX -std=c++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -D_GLIBCXX_DEBUG "$@" \
    -I include -I build-fuzz/include $LEPT_CFLAGS \
    unittest/fuzzers/fuzzer-api.cpp /tmp/lsan_off.o $LIBTESS $LEPT_LIBS \
    $LIB_FUZZING_ENGINE -o "/mayhem/$name"
  $CXX -std=c++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -D_GLIBCXX_DEBUG "$@" \
    -I include -I build-fuzz/include $LEPT_CFLAGS \
    unittest/fuzzers/fuzzer-api.cpp /tmp/standalone_main.o /tmp/lsan_off.o $LIBTESS $LEPT_LIBS \
    -o "/mayhem/$name-standalone"
}
build_harness fuzzer-api
build_harness fuzzer-api-512x256 -DTESSERACT_FUZZER_WIDTH=512 -DTESSERACT_FUZZER_HEIGHT=256

# 3) The `tesseract` CLI with the project's NORMAL flags, for mayhem/test.sh.
cmake -S . -B build-tests "${CMAKE_COMMON[@]}" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests --target tesseract -j"$MAYHEM_JOBS"
