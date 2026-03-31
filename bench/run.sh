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
		seconds_kb="$(
			{
				/usr/bin/time -f '%e\t%M' "$@" >/dev/null
			} 2>&1
		)"
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
	run_bench "psil" lua "$ROOT/host/main.lua" "$ROOT/bench/psil/${bench}.psil"
	run_bench "clisp" clisp -q -norc -i "$ROOT/bench/common_lisp/${bench}.lisp" -x '(ext:quit)'
	run_bench "gcl" gcl -load "$ROOT/bench/common_lisp/${bench}.lisp" -eval '(bye)'
done
