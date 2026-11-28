#!/usr/bin/env bash
# Run every host-side test for the Vita port (no console, no VitaSDK needed).
#
#   platform/vita/tools/run_tests.sh
#
# Tests that need inputs which are not in the repository are skipped with a
# note instead of failing:
#   VITA_RUNTIME_SO  libgodot.so for test_verify_runtime.py
#                    (default: extracted from examples/vita_export/Exemplo.vpk)
#   VITAGL_SRC       VitaGL source checkout for test_vitagl_ubo_binding.py
#   _build/trophy-tests  output of test_trophy_export.py (needs the Windows
#                    editor) plus Pillow, for test_trophy_trp.py
#
# Exit status is non-zero if any test that ran failed.
set -u

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="$TOOLS/tests"
ROOT="$(cd "$TOOLS/../../.." && pwd)"
PYTHON="${PYTHON:-python3}"
CC="${CC:-cc}"
CXX="${CXX:-c++}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=() failed=() skipped=()

run() {
	local name="$1"
	shift
	printf '\n=== %s\n' "$name"
	if "$@"; then
		passed+=("$name")
	else
		failed+=("$name")
	fi
}

skip() {
	printf '\n=== %s\nSKIP: %s\n' "$1" "$2"
	skipped+=("$1 ($2)")
}

compile_and_run() {
	local compiler="$1" source="$2" exe="$WORK/$(basename "${2%.*}")"
	shift 2
	"$compiler" "$@" "$TESTS/$source" -o "$exe" && "$exe"
}

# --- Python, self-contained -------------------------------------------------
run test_package_editor_distribution "$PYTHON" -m unittest discover -q -s "$TESTS" -p test_package_editor_distribution.py
for t in test_gxm_bridge test_gxm_bridge_vgl test_gxm_shader_translator test_vita_qualifiers; do
	run "$t" "$PYTHON" "$TESTS/$t.py"
done

# --- C / C++ ----------------------------------------------------------------
run test_texture_format compile_and_run "$CC" test_texture_format.c -std=c99 -Wall
run test_audio_pcm_vita compile_and_run "$CXX" test_audio_pcm_vita.cpp -std=c++17 -Wall
run test_gxm_camera_lod compile_and_run "$CXX" test_gxm_camera_lod.cpp -std=c++17 -Wall

# --- Tests that use the bundled example export --------------------------------
EXAMPLE_VPK="$ROOT/examples/vita_export/Exemplo.vpk"
if [ -f "$EXAMPLE_VPK" ]; then
	run test_editor_vpk "$PYTHON" "$TESTS/test_editor_vpk.py" "$EXAMPLE_VPK" "$WORK/editor_vpk"
else
	skip test_editor_vpk "examples/vita_export/Exemplo.vpk not found"
fi

RUNTIME_SO="${VITA_RUNTIME_SO:-}"
if [ -z "$RUNTIME_SO" ] && [ -f "$EXAMPLE_VPK" ]; then
	"$PYTHON" - "$EXAMPLE_VPK" "$WORK/libgodot.so" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as vpk, open(sys.argv[2], 'wb') as out:
    out.write(vpk.read('libgodot.so'))
EOF
	RUNTIME_SO="$WORK/libgodot.so"
fi
if [ -n "$RUNTIME_SO" ] && [ -f "$RUNTIME_SO" ]; then
	run test_verify_runtime "$PYTHON" "$TESTS/test_verify_runtime.py" "$RUNTIME_SO"
else
	skip test_verify_runtime "set VITA_RUNTIME_SO to a libgodot.so"
fi

# --- Tests that need external inputs ------------------------------------------
if [ -n "${VITAGL_SRC:-}" ]; then
	run test_vitagl_ubo_binding "$PYTHON" "$TESTS/test_vitagl_ubo_binding.py" "$VITAGL_SRC"
else
	skip test_vitagl_ubo_binding "set VITAGL_SRC to a patched VitaGL checkout"
fi

if [ ! -d "$ROOT/_build/trophy-tests" ]; then
	skip test_trophy_trp "run tools/test_trophy_export.py first (needs the Windows editor)"
elif ! "$PYTHON" -c 'import PIL' 2>/dev/null; then
	skip test_trophy_trp "Pillow is not installed"
else
	run test_trophy_trp bash -c 'cd "$1" && "$2" "$3"' _ "$ROOT" "$PYTHON" "$TESTS/test_trophy_trp.py"
fi

# --- Summary --------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'passed: %d  failed: %d  skipped: %d\n' "${#passed[@]}" "${#failed[@]}" "${#skipped[@]}"
for name in "${skipped[@]}"; do printf '  skipped %s\n' "$name"; done
for name in "${failed[@]}"; do printf '  FAILED  %s\n' "$name"; done
[ "${#failed[@]}" -eq 0 ]
