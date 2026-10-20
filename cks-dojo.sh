#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	echo "Usage: $0 [<exam-number> <setup [--reset]|score|recreate [--yes]>]"
	echo
	echo "Run without arguments to open the interactive menu."
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

BOLD='\033[1m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_logo() {
	clear
	echo -e "${CYAN}"
	cat <<'LOGO'
   ██████╗██╗  ██╗███████╗    ██████╗  ██████╗      ██╗ ██████╗
  ██╔════╝██║ ██╔╝██╔════╝    ██╔══██╗██╔═══██╗     ██║██╔═══██╗
  ██║     █████╔╝ ███████╗    ██║  ██║██║   ██║     ██║██║   ██║
  ██║     ██╔═██╗ ╚════██║    ██║  ██║██║   ██║██   ██║██║   ██║
  ╚██████╗██║  ██╗███████║    ██████╔╝╚██████╔╝╚█████╔╝╚██████╔╝
   ╚═════╝╚═╝  ╚═╝╚══════╝    ╚═════╝  ╚═════╝  ╚════╝  ╚═════╝
LOGO
	echo -e "${NC}       Local CKS exam simulator on minikube\n"
}

bye() {
	echo -e "\nBye."
	exit 0
}

# Ctrl-C ends the TUI at the menu. During an action it stops only the child
# process. Bash can run the INT trap late (after the child has returned), so
# IN_ACTION stays true until the tui loop is back at the main menu.
IN_ACTION=false
on_interrupt() {
	if [ "$IN_ACTION" = true ]; then
		return 0
	fi
	bye
}

# Reads one key into the named variable, without waiting for Enter.
# Ctrl-D (EOF) ends the TUI.
read_key() {
	local _key _rc
	while true; do
		_rc=0
		IFS= read -rsn1 _key || _rc=$?
		[ "$_rc" -eq 0 ] && break
		# Above 128, a trapped signal interrupted read: read again.
		# Otherwise it is EOF.
		[ "$_rc" -gt 128 ] || bye
	done
	# Drop escape sequences (arrow keys etc.) completely. Callers treat an
	# empty key (also Enter) as "no choice" and redraw without an error.
	if [ "$_key" = $'\e' ]; then
		read -rsn2 -t 1 _ || true
		_key=""
	fi
	printf -v "$1" '%s' "$_key"
}

# Prints a [y/N] prompt and returns 0 only for y/Y.
confirm() {
	local answer
	printf '%s [y/N] ' "$1"
	read_key answer
	echo "$answer"
	case "$answer" in
	[Yy]) return 0 ;;
	*) return 1 ;;
	esac
}

pause() {
	echo
	printf 'Press any key to return to the menu...'
	read_key _
}

invalid_choice() {
	echo -e "\n${RED}Invalid choice: '$1'${NC}"
	sleep 1
}

# Sets SELECTED_NUM and SELECTED_NAME to the chosen exam. With only one exam,
# selects it without a prompt. Returns 1 if the user goes back.
select_exam() {
	local title="$1"
	local nums=() names=() dir name choice i

	for dir in "$REPO_ROOT"/exams/cks-simulation*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		nums+=("${name#cks-simulation}")
		names+=("$(source "$dir/exam.conf" && echo "$EXAM_NAME")")
	done

	if [ "${#nums[@]}" -eq 1 ]; then
		SELECTED_NUM="${nums[0]}"
		SELECTED_NAME="${names[0]}"
		return 0
	fi

	while true; do
		print_logo
		echo -e "${BOLD}${title}${NC}\n"
		if [ "${#nums[@]}" -eq 0 ]; then
			echo "  (no exams found under exams/)"
			pause
			return 1
		fi
		for i in "${!nums[@]}"; do
			echo "  $((i + 1)). ${names[$i]}"
		done
		echo "  b. Back"
		echo
		printf 'Select an exam: '
		# One key is enough for up to 9 exams; with more, read a full line.
		if [ "${#nums[@]}" -le 9 ]; then
			read_key choice
		else
			IFS= read -r choice || bye
		fi
		case "$choice" in
		[Bb]) return 1 ;;
		"") continue ;;
		*[!0-9]*) ;;
		*)
			if [ "$choice" -ge 1 ] && [ "$choice" -le "${#nums[@]}" ]; then
				SELECTED_NUM="${nums[$((choice - 1))]}"
				SELECTED_NAME="${names[$((choice - 1))]}"
				return 0
			fi
			;;
		esac
		invalid_choice "$choice"
	done
}

# Clears the screen and prints the action and exam as a heading.
action_heading() {
	print_logo
	echo -e "${BOLD}$1: ${SELECTED_NAME}${NC}\n"
}

# Runs this script with arguments in a child process, so a failing or
# interrupted action returns to the menu instead of ending the TUI.
run_action() {
	local rc=0
	IN_ACTION=true
	"$REPO_ROOT/cks-dojo.sh" "$@" || rc=$?
	if [ "$rc" -eq 130 ]; then
		echo -e "\n${YELLOW}Action interrupted.${NC}"
	elif [ "$rc" -ne 0 ]; then
		echo -e "\n${RED}Action failed (exit code $rc).${NC}"
	fi
}

count_answer_files() {
	find "$REPO_ROOT/exam/course" -mindepth 2 -type f 2>/dev/null | wc -l | tr -d ' '
}

start_exam() {
	local files
	select_exam "Start a test exam" || return 0
	action_heading "Start a test exam"
	files="$(count_answer_files)"
	if [ "$files" -gt 0 ] && confirm "Found $files answer file(s) from a previous attempt in exam/course/. Delete them?"; then
		run_action "$SELECTED_NUM" setup --reset
	else
		run_action "$SELECTED_NUM" setup
	fi
	echo -e "\nQuestions: exams/cks-simulation${SELECTED_NUM}/questions.md"
	echo "Answers:   exam/course/<question-number>/"
	pause
}

score_exam() {
	select_exam "Score an exam" || return 0
	action_heading "Score an exam"
	run_action "$SELECTED_NUM" score
	pause
}

reset_cluster() {
	local profile
	select_exam "Reset the cluster" || return 0
	action_heading "Reset the cluster"
	profile="$(source "$REPO_ROOT/exams/cks-simulation${SELECTED_NUM}/exam.conf" && echo "$MINIKUBE_PROFILE")"
	echo -e "${YELLOW}This deletes minikube profile '$profile' with all cluster state,${NC}"
	echo -e "${YELLOW}creates it again, and runs setup --reset. It takes several minutes.${NC}\n"
	if confirm "Reset the cluster?"; then
		run_action "$SELECTED_NUM" recreate --yes
		pause
	else
		echo -e "\nReset cancelled."
		sleep 1
	fi
}

tui() {
	local choice
	trap on_interrupt INT
	while true; do
		IN_ACTION=false
		print_logo
		echo "  1. Start a test exam"
		echo "  2. Score an exam"
		echo "  3. Reset the cluster"
		echo "  4. Exit"
		echo
		printf 'Select an option: '
		read_key choice
		case "$choice" in
		1) start_exam ;;
		2) score_exam ;;
		3) reset_cluster ;;
		4 | [Qq]) bye ;;
		"") ;;
		*) invalid_choice "$choice" ;;
		esac
	done
}

if [ "$#" -eq 0 ] && [ -t 0 ]; then
	tui
fi

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
	exec "$EXAM_DIR/setup.sh" "${@:3}"
	;;
score)
	exec "$EXAM_DIR/run-scoring.sh"
	;;
recreate)
	source "$EXAM_DIR/exam.conf"
	if [ "${3:-}" != "--yes" ]; then
		read -r -p "Delete minikube profile '$MINIKUBE_PROFILE' and create it again? [y/N] " answer
		case "$answer" in
		[Yy]) ;;
		*)
			echo "Aborted."
			exit 1
			;;
		esac
	fi
	minikube delete -p "$MINIKUBE_PROFILE"
	minikube start -p "$MINIKUBE_PROFILE" "${MINIKUBE_START_ARGS[@]}"
	kubectl --context "$MINIKUBE_PROFILE" wait --for=condition=Ready nodes --all --timeout=300s
	exec "$EXAM_DIR/setup.sh" --reset
	;;
*)
	echo "Error: unknown action '$ACTION' (expected 'setup', 'score' or 'recreate')" >&2
	usage
	exit 1
	;;
esac
