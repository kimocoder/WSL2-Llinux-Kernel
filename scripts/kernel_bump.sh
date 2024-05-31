#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#

set -eu
if [ -n "${DEBUG_TRACE_SH:-}" ] && \
   [ "${DEBUG_TRACE_SH:-}" != "${DEBUG_TRACE_SH#*"$(basename "${0}")"*}" ] || \
   [ "${DEBUG_TRACE_SH:-}" = 'all' ]; then
	set -x
fi

REQUIRED_COMMANDS='
	[
	basename
	command
	echo
	exit
	git
	printf
	sed
	set
	shift
	sort
'

_msg()
{
	_level="${1:?Missing argument to function}"
	shift

	if [ "${#}" -le 0 ]; then
		echo "${_level}: No content for this message ..."
		return
	fi

	echo "${_level}: ${*}"
}

e_err()
{
	_msg 'err' "${*}" >&2
}

e_warn()
{
	_msg 'warning' "${*}"
}

e_notice()
{
	_msg 'notice' "${*}"
}

usage()
{
	echo "Usage: ${0}"
	echo 'Helper script to bump the target kernel version, whilst keeping history.'
	echo "    -s  Source version of kernel (e.g. 'v6.1.21' [SOURCE_VERSION])"
	echo "    -t  Target version of kernel (e.g. 'v6.1.26' [TARGET_VERSION]')"
	echo
	echo 'All options can also be passed in environment variables (listed between [BRACKETS]).'
	echo 'Note that this script must be run from within the Linux kernel git repository.'
	echo 'Example: scripts/kernel_bump.sh -s v6.1.21 -t v6.1.26'
}

cleanup()
{
	trap - EXIT HUP INT QUIT ABRT ALRM TERM

	if [ -n "${initial_branch:-}" ] && \
	   [ "$(git rev-parse --abbrev-ref HEAD)" != "${initial_branch:-}" ]; then
		git switch "${initial_branch}"
	fi
}

init()
{
	src_file="$(readlink -f "${0}")"
	src_dir="${src_file%%"${src_file##*'/'}"}"
	initial_branch="$(git rev-parse --abbrev-ref HEAD)"
	initial_commitish="$(git rev-parse HEAD)"

	if [ -n "$(git status --porcelain | grep -v '^?? .*')" ]; then
		echo 'Git repository not in a clean state, will not continue.'
		exit 1
	fi

	source_version="${source_version#v}"
	target_version="${target_version#v}"

	trap cleanup EXIT HUP INT QUIT ABRT ALRM TERM
}

setup_git_config()
{
	if ! git config --get-all rebase >/dev/null; then
		diff.colorMoved zebra
		git config pull.rebase true
	fi
}

add_stable_remote()
{
	if ! git remote | grep -q "stable"; then
		git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
	fi
	git fetch stable --tags
}

select_kernel_version()
{
	local version_type="${1}"
	local selected_version

	echo "Available kernel ${version_type} versions:"
	git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V

	read -p "Enter ${version_type} version (e.g., v6.1.21): " selected_version
	echo "${selected_version}"
}

compare_versions()
{
	if [ "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" ]; then
		return 1
	fi
}

bump_kernel()
{
	# Ensure we are in the root directory of the kernel source
	if [ ! -f "Makefile" ] || ! grep -q "VERSION = " Makefile; then
		e_err "This script must be run from the root of the kernel source directory."
		exit 1
	fi

	git switch --force-create '__kernel_files_mover'

	# Move all source files from old version to new version
	for _path in $(find . -type f -name "*-${source_version}*"); do
		_target_path="${_path//-${source_version}/-${target_version}}"
		if [ -e "${_target_path}" ]; then
			e_err "Target '${_target_path}' already exists!"
			exit 1
		fi

		git mv \
			"${_path}" \
			"${_target_path}"
	done

	# Update configuration files
	for _config in $(find . -type f -name "config-${source_version}*"); do
		_target_config="${_config//config-${source_version}/config-${target_version}}"
		git mv "${_config}" "${_target_config}"
	done

	git commit \
		--signoff \
		--message "kernel: Bump kernel files from ${source_version} to ${target_version}" \
		--message 'This is an automatically generated commit.' \
		--message 'When doing `git bisect`, consider `git bisect --skip`.'

	git checkout 'HEAD~' .
	git commit \
		--signoff \
		--message "kernel: Restore kernel files for ${source_version}" \
		--message "$(printf "This is an automatically generated commit which aids following Kernel patch\nhistory, as git will see the move and copy as a rename thus defeating the\npurpose.\n\nFor the original discussion see:\nhttps://lists.openwrt.org/pipermail/openwrt-devel/2023-October/041673.html")"
	git switch "${initial_branch:?Unable to switch back to original branch. Quitting.}"
	GIT_EDITOR=true git merge --no-ff '__kernel_files_mover'
	git branch --delete '__kernel_files_mover'
	echo "Deleting merge commit ($(git rev-parse HEAD))."
	git rebase HEAD~1

	echo "Original commitish was '${initial_commitish}'."
	echo 'Kernel bump complete. Remember to use `git log --follow`.'
}

check_requirements()
{
	for _cmd in ${REQUIRED_COMMANDS}; do
		if ! _test_result="$(command -V "${_cmd}")"; then
			_test_result_fail="${_test_result_fail:-}${_test_result}\n"
		else
			_test_result_pass="${_test_result_pass:-}${_test_result}\n"
		fi
	done

	echo 'Available commands:'
	# As the results contain \n, we expect these to be interpreted.
	# shellcheck disable=SC2059
	printf "${_test_result_pass:-none\n}"
	echo
	echo 'Missing commands:'
	# shellcheck disable=SC2059
	printf "${_test_result_fail:-none\n}"
	echo

	if [ -n "${_test_result_fail:-}" ]; then
		echo 'Command test failed, missing programs.'
		test_failed=1
	fi
}

main()
{
	# Check if it's the first run
	if [ ! -f ".git/first_run" ]; then
		setup_git_config
		add_stable_remote
		touch ".git/first_run"
	fi

	while getopts 'hs:t:' _options; do
		case "${_options}" in
		'h')
			usage
			exit 0
			;;
		's')
			source_version="${OPTARG}"
			;;
		't')
			target_version="${OPTARG}"
			;;
		':')
			e_err "Option -${OPTARG} requires an argument."
			exit 1
			;;
		*)
			e_err "Invalid option: -${OPTARG}"
			exit 1
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	source_version="${source_version:-${SOURCE_VERSION:-}}"
	target_version="${target_version:-${TARGET_VERSION:-}}"

	if [ -z "${source_version:-}" ] || [ -z "${target_version:-}" ]; then
		add_stable_remote
		source_version="$(select_kernel_version "source")"
		target_version="$(select_kernel_version "target")"
	fi

	check_requirements

	init
	bump_kernel
	cleanup
}

main "${@}"

exit 0

