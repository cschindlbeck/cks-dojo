#!/bin/bash
set -o pipefail

EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$EXAM_DIR/exam.conf"
source "$EXAM_DIR/scoring-functions.sh"

TOTAL_SCORE=0
for i in $(seq 1 "$TOTAL_QUESTIONS"); do
	fn="score_q${i}"
	if declare -f "$fn" >/dev/null; then
		"$fn"
		varname="Q${i}_SCORE"
		TOTAL_SCORE=$((TOTAL_SCORE + ${!varname:-0}))
	fi
done

PASS_THRESHOLD=$(((TOTAL_POINTS * PASSING_PERCENTAGE + 99) / 100))
echo
echo "===================================="
if [ "$TOTAL_SCORE" -ge "$PASS_THRESHOLD" ]; then
	echo "TOTAL: $TOTAL_SCORE / $TOTAL_POINTS -- PASS (threshold: $PASS_THRESHOLD)"
else
	echo "TOTAL: $TOTAL_SCORE / $TOTAL_POINTS -- FAIL (threshold: $PASS_THRESHOLD)"
fi
