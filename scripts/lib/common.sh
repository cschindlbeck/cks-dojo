#!/bin/bash
# Shared print/scoring helpers for cks-dojo exams.

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() { echo -e "\n${YELLOW}$1${NC}"; }
print_success() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
print_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

# check_criterion "description" "true"|"false"
# Prints pass/fail and returns 0 (pass) or 1 (fail), so callers can do:
#   check_criterion "..." "$cond" && ((score+=N))
check_criterion() {
	local description="$1"
	local condition="$2"

	if [ "$condition" = "true" ]; then
		print_success "$description"
		return 0
	else
		print_fail "$description"
		return 1
	fi
}
