#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	echo "Usage: $0 <exam-number> <setup|score>"
	echo
	echo "Available exams:"
	local found=0
	for dir in "$REPO_ROOT"/exams/cks-simulation*/; do
		[ -d "$dir" ] || continue
		found=1
		name="$(basename "$dir")"
		num="${name#cks-simulation}"
		echo "  $num  ($name)"
	done
	[ "$found" -eq 0 ] && echo "  (none found under exams/)"
	return 0
}

if [ "$#" -lt 2 ]; then
	usage
	exit 1
fi

NUM="$1"
ACTION="$2"
EXAM_DIR="$REPO_ROOT/exams/cks-simulation${NUM}"

if [ ! -d "$EXAM_DIR" ]; then
	echo "Error: no exam found for number '$NUM' (expected $EXAM_DIR)" >&2
	usage
	exit 1
fi

case "$ACTION" in
setup)
	exec "$EXAM_DIR/setup.sh"
	;;
score)
	exec "$EXAM_DIR/run-scoring.sh"
	;;
*)
	echo "Error: unknown action '$ACTION' (expected 'setup' or 'score')" >&2
	usage
	exit 1
	;;
esac
