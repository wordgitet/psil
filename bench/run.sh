#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${1:-3}"

benchmarks=(
	"fib"
	"sum_loop"
	"closure_counter"
	"list_work"
)

run_bench() {
	local label="$1"
	shift

	local total_ms=0
	local run=1

	while [ "$run" -le "$RUNS" ]; do
		local seconds_kb
		local status=0
		set +e
		seconds_kb="$(
			{
				/usr/bin/time -f '%e\t%M' "$@" >/dev/null
			} 2>&1
		)"
		status=$?
		set -e

		if [ "$status" -ne 0 ]; then
			printf '%-18s run %d/%d     failed\n' "$label" "$run" "$RUNS"
			return 1
		fi
		local seconds
		local kb
		seconds="$(printf '%s' "$seconds_kb" | cut -f1)"
		kb="$(printf '%s' "$seconds_kb" | cut -f2)"

		local millis
		millis="$(awk "BEGIN { printf \"%d\", (${seconds} * 1000) }")"
		total_ms=$((total_ms + millis))

		printf '%-18s run %d/%d  %8sms  %8s KB\n' "$label" "$run" "$RUNS" "$millis" "$kb"
		run=$((run + 1))
	done

	local average_ms=$((total_ms / RUNS))
	printf '%-18s average   %8sms\n' "$label" "$average_ms"
}

for bench in "${benchmarks[@]}"; do
	printf '\n== %s ==\n' "$bench"
	run_bench "psil-auto" lua "$ROOT/bench/psil_bench.lua" scheme-auto "$ROOT/bench/psil/${bench}.psil" || true
	run_bench "psil-interp" lua "$ROOT/bench/psil_bench.lua" scheme-interp "$ROOT/bench/psil/${bench}.psil" || true
	run_bench "psil-cl" lua "$ROOT/bench/psil_bench.lua" cl-interp "$ROOT/bench/psil_cl/${bench}.lisp" || true
	run_bench "clisp" clisp -q -norc -i "$ROOT/bench/common_lisp/${bench}.lisp" -x '(ext:quit)' || true
	run_bench "gcl" gcl -load "$ROOT/bench/common_lisp/${bench}.lisp" -eval '(bye)' || true
done
