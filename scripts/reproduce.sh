#!/usr/bin/env bash
# Rebuild from scratch and regenerate the committed outputs in docs/ into $OUT
# (default repro_out/), so a run on a busy machine never overwrites them by accident.
#
#   scripts/reproduce.sh              deterministic checks: tests, validator, risk, routing, publication
#   LIVE=1 scripts/reproduce.sh       also the live multicast sessions and timing benchmarks
#                                     (needs: sudo sysctl -w net.core.rmem_max=134217728)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=${OUT:-repro_out}
JOBS=${JOBS:-$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))}
PY=${PYTHON:-python3}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$JOBS"
B="$ROOT/build"
mkdir -p "$OUT/docs"
cd "$OUT"

# order_router_bench writes into ./docs/, so it runs from $OUT
"$B/correctness_test" | tail -3 | tee correctness_output.txt
"$B/ouch_session_test" | tee docs/ouch_session_test_output.txt
"$B/order_router_test" | tee docs/order_router_test_output.txt
"$B/validator_defect_test" | tee docs/validator_defect_output.txt
"$B/order_router_bench" risk
"$B/order_router_bench" route
"$B/order_router_bench" sor
$PY "$ROOT/python/validate_routing.py" docs/order_router_route_log.csv | tee docs/routing_validation_output.txt
$PY "$ROOT/python/validate_sor.py" docs/order_router_sor_log.csv | tee docs/sor_validation_output.txt

# three no-network sessions, one per trading date; the committed run used seeds 101, 102, 103
"$B/generate_session" 101 300000 "$TMP/session_2026-08-18.tcap" 16 >/dev/null
"$B/generate_session" 102 300000 "$TMP/session_2026-08-19.tcap" 16 >/dev/null
"$B/generate_session" 103 300000 "$TMP/session_2026-08-20.tcap" 16 >/dev/null
SESS=(2026-08-18="$TMP/session_2026-08-18.tcap" 2026-08-19="$TMP/session_2026-08-19.tcap" 2026-08-20="$TMP/session_2026-08-20.tcap")
$PY "$ROOT/python/publish_parquet.py" "$TMP/published" "${SESS[@]}" | tee docs/publish_output.txt
$PY "$ROOT/python/validate_publication.py" "$TMP/published" "${SESS[@]}" | tee docs/validate_publication_output.txt

if [[ "${LIVE:-0}" == 1 ]]; then
  "$B/live_capture" 2000000 "$TMP/session.tcap" 0 400000 | tee live_capture_output.txt
  "$B/replay_verify" "$TMP/session.tcap" | tee replay_verify_output.txt
  "$B/capture_bench" "$TMP/session.tcap" "$TMP/session.rows" | tee capture_bench_output.txt
  "$B/live_capture" 1000000 "$TMP/lossy.tcap" 20 400000 | tee live_capture_lossy_output.txt
  "$B/replay_verify" "$TMP/lossy.tcap" | tee -a live_capture_lossy_output.txt
  "$B/live_capture_ab" 2000000 "$TMP/session_ab.tcap" 5000 3000 3000 400000 | tee docs/live_capture_ab_output.txt
  taskset -c 0 "$B/replay_bench" "$TMP/session_ab.tcap" 5 | tee docs/replay_bench_output.txt
fi
echo "done: outputs in $OUT/"
