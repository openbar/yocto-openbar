#!/bin/sh
# shellcheck shell=sh enable=all

# Enable exit on error
set -e

OPENBAR_GITHUB_NWO="openbar/openbar"
YOCTO_POKY_GITHUB_NWO="yoctoproject/poky"

OPENBAR_GIT_URL="https://github.com/${OPENBAR_GITHUB_NWO}.git"
YOCTO_POKY_GIT_URL="https://github.com/${YOCTO_POKY_GITHUB_NWO}.git"

OPENBAR_URL="https://openbar.github.io/openbar"
WIZARD_URL="${OPENBAR_URL}/wizard"

GIT_REVNAME="${1:-main}"

# Colorize the output
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# Create the temporary directory
TMPDIR=$(mktemp -d)

# Cleanup handler
cleanup() {
	# Remove the temporary directory
	rm -rf "${TMPDIR}"

	# Print a status line
	if [ "$1" -eq 0 ]; then
		echo
		green "Openbar project generation done"
	else
		printf >&2 "\n\n"
		red >&2 "Openbar project generation aborted"
	fi
}

# Ensure the cleanup handler is always called
# https://unix.stackexchange.com/a/240736/117394
on_exit() {
	EXIT_STATUS=${1:-$?}

	cleanup "${EXIT_STATUS}"

	exit "${EXIT_STATUS}"
}

on_sigint() {
	trap - INT EXIT
	cleanup 1
	kill -s INT $$
}

trap on_sigint INT
trap on_exit EXIT

# Duplicate stdout to distinguish between a return value and a print.
exec 3>&1

## ask <question> [prompt]
ask() {
	QUESTION=$(yellow "$1")
	printf >&3 "%s%s " "${QUESTION}" "${2:+ $2}"
}

## ask_yesno <question> [default=yes]
ask_yesno() {
	DEFAULT="${2:-yes}"

	[ "${DEFAULT}" = yes ] && PROMPT="[Y/n]" || PROMPT="[y/N]"

	while true; do
		echo >&3
		ask "$1" "${PROMPT}"

		read -r YESNO

		case "${YESNO}" in
		"") [ "${DEFAULT}" = yes ] && return 0 || return 1 ;;
		[yY] | [yY][eE][sS]) return 0 ;;
		[nN] | [nN][oO]) return 1 ;;
		*) red >&2 "Invalid response: ${YESNO}" ;;
		esac
	done
}

## ask_value <question> [default]
ask_value() {
	DEFAULT="$2"

	[ -n "${DEFAULT}" ] && PROMPT=" [${DEFAULT}]" || PROMPT=""

	while true; do
		echo >&3
		ask "$1" "${PROMPT}"

		read -r VALUE

		if [ -z "${VALUE:-${DEFAULT}}" ]; then
			red >&2 "Invalid empty response"
		else
			echo "${VALUE:-${DEFAULT}}"
			return 0
		fi
	done
}

## ask_select <question> <colon-list> [default=1]
ask_select() {
	## print_list <colon-list>
	print_list() {
		echo "$1" | awk >&3 -F: '{
			for (i = 1; i <= NF; i++) {
				printf("%2s) %s\n", i, $i);
			}
		}'
	}

	## check_value <colon-list> <value> [default=1]
	check_value() {
		echo "$1" | awk -F: -v VALUE="${2:-${3:-1}}" '{
			LCVALUE = tolower(VALUE);
			for (i = 1; i <= NF; i++) {
				if (LCVALUE == i || LCVALUE == $i) {
					printf("%s", $i);
					exit;
				}
			}
		}'
	}

	DEFAULT=$(check_value "$2" "${3:-1}")

	while true; do
		echo >&3
		print_list "$2"
		ask "$1" "[${DEFAULT}]"

		read -r VALUE

		SAFE_VALUE=$(check_value "$2" "${VALUE}" "${DEFAULT}")

		if [ -z "${SAFE_VALUE}" ]; then
			red >&2 "Invalid response: ${VALUE}"
		else
			echo "${SAFE_VALUE}"
			return 0
		fi
	done
}

## sanitize <option>...
sanitize() {
	VALUE="$(cat)"

	# Protect against CTRL-D
	if [ -z "${VALUE}" ]; then
		red >&2 "Invalid empty value"
		exit 1
	fi

	for OPTION in "$@"; do
		unset PROMPT_NEQ
		unset PROMPT

		OLD_VALUE="${VALUE}"

		case ${OPTION} in

		onlyprint)
			PROMPT_NEQ="Only printable character allowed"
			VALUE=$(echo "${VALUE}" | sed -e "s/[^[[:print:]]]//g")
			;;

		noslash)
			PROMPT_NEQ="Slash character not allowed"
			VALUE=$(echo "${VALUE}" | sed -e "s:/::g")
			;;

		noleadingslash)
			PROMPT_NEQ="Leading slash character not allowed"
			VALUE=$(echo "${VALUE}" | sed -e "s:^/::")
			;;

		notrailingslash)
			PROMPT_NEQ="Trailing slash character not allowed"
			VALUE=$(echo "${VALUE}" | sed -e "s:/$::")
			;;

		nospace)
			PROMPT_NEQ="Space character not allowed"
			VALUE=$(echo "${VALUE}" | sed -e "s/[[:space:]]//g")
			;;

		trailingdefconfig)
			PROMPT_NEQ="Trailing '_defconfig' is mandatory"
			VALUE=$(echo "${VALUE}" | sed -e "s/_defconfig$//" -e "s/$/_defconfig/")
			;;

		preferedlower)
			echo "${VALUE}" | grep -q "[[:upper:]]" &&
				PROMPT="Using lowercase characters is recommended"
			;;

		*)
			PROMPT="Invalid option ${OPTION}"
			;;
		esac

		if [ -n "${PROMPT_NEQ}" ] && [ "${OLD_VALUE}" != "${VALUE}" ]; then
			PROMPT=$(red "${PROMPT_NEQ}:")
			echo >&2 "${PROMPT} '${OLD_VALUE}' -> '${VALUE}'"

		elif [ -n "${PROMPT}" ]; then
			red >&2 "${PROMPT}"
		fi
	done

	echo "${VALUE}"
}

## info <comment> <value>
info() {
	printf "%-32s%s\n" "${1}:" "$2"
}

## get_revision
get_revision() {
	git ls-remote --refs "${OPENBAR_GIT_URL}" | awk \
		-v commit="^${GIT_REVNAME}" \
		-v reference="refs/(heads|tags)/${GIT_REVNAME}$" \
		'$0~commit {print $1} $0~reference {print $1}'
}

## init_git <directory>
init_git() {
	info "Initializing git repository" "$1"
	mkdir -p "${TMPDIR}/${1}"
	git -C "${TMPDIR}/${1}" init --quiet
}

## add_git_submodule <directory> <url> <output> [revision]
add_git_submodule() {
	info "Adding git submodule" "${1}/${3}"
	git -C "${TMPDIR}/${1}" submodule --quiet add "$2" "$3"
	[ -z "$4" ] || git -C "${TMPDIR}/${1}/${3}" checkout --quiet "$4"
}

## create_file <path> (content is in stdin)
create_file() {
	info "Creating file" "$1"
	mkdir -p "${TMPDIR}/${1%/*}"
	cat >"${TMPDIR}/${1}"
}

## download <url>
download() {
	curl --fail --show-error --silent "$1"
}

## download_file <path> <url>
download_file() {
	info "Downloading file" "$2"
	CONTENT=$(download "$2")
	echo "${CONTENT}" | create_file "$1"
}

## create_dockerfile <directory>
create_dockerfile() {
	download_file "${1}/container/default/Dockerfile" \
		"${WIZARD_URL}/container/${PROJECT_TYPE}/${CONTAINER_TEMPLATE}/Dockerfile"
}

## create_defconfig <directory>
create_defconfig() {
	download_file "${1}/${DEFCONFIG_FILENAME}" \
		"${WIZARD_URL}/defconfig/${PROJECT_TYPE}.mk"
}

## create_root <directory>
create_root() {
	(
		cat <<-EOF
			### DO NOT EDIT THIS FILE ###
			export OB_TYPE           := ${PROJECT_TYPE}
			export OB_DEFCONFIG_DIR  := \${CURDIR}/${CONFIG_DIR}
			export OB_CONTAINER_DIR  := \${CURDIR}/${CONFIG_DIR}/container
		EOF

		if [ "${PROJECT_TYPE}" = "yocto" ]; then
			cat <<-EOF
				export OB_INITENV_SCRIPT := \${CURDIR}/${YOCTO_POKY_DIR}/oe-init-build-env
			EOF
		elif [ "${PROJECT_TYPE}" = "initenv" ]; then
			cat <<-EOF
				export OB_INITENV_SCRIPT := \${CURDIR}/${CONFIG_DIR}/${INITENV_SCRIPT}
			EOF
		fi

		cat <<-EOF

			include ${OPENBAR_DIR}/core/main.mk
			### DO NOT EDIT THIS FILE ###
		EOF
	) | create_file "${1}/${ROOT_FILENAME}"
}

## create_initenv <directory>
create_initenv() {
	download_file "${1}/${INITENV_SCRIPT}" \
		"${WIZARD_URL}/initenv/init.env"
}

## create_gitignore <directory>
create_gitignore() {
	download_file "${1}/.gitignore" \
		"${WIZARD_URL}/submodule/gitignore"
}

## create_manifest <directory>
create_manifest() {
	PARENT=$(dirname "$1")
	ORIGIN_FETCH=$(realpath -m --relative-to="${PARENT:-.}" .)

	(
		cat <<-EOF
			<?xml version="1.0" encoding="UTF-8"?>
			<manifest>
			  <remote name="origin" fetch="${ORIGIN_FETCH}" />
			  <remote name="github" fetch="https://github.com" />

			  <default remote="origin" revision="main" sync-j="4" />

			  <project path="${CONFIG_DIR}" name="${GIT_MAIN_PATH}" >
			    <copyfile src="${ROOT_FILENAME}" dest="Makefile" />
			  </project>

			  <project path="${OPENBAR_DIR}" remote="github" revision="${GIT_REVISION}" upstream="${GIT_REVNAME}" name="${OPENBAR_GITHUB_NWO}" />
		EOF

		if [ "${PROJECT_TYPE}" = "yocto" ]; then
			cat <<-EOF
				  <project path="${YOCTO_POKY_DIR}" remote="github" revision="master" name="${YOCTO_POKY_GITHUB_NWO}" />
			EOF
		fi

		cat <<-EOF
			</manifest>
		EOF
	) | create_file "${1}/default.xml"
}

## create_project
create_project() {
	echo
	init_git "${GIT_MAIN_PATH}"

	if [ "${GIT_TYPE}" = "submodule" ]; then
		LOCAL_CONFIG_DIR="${GIT_MAIN_PATH}/${CONFIG_DIR}"

		add_git_submodule "${GIT_MAIN_PATH}" "${OPENBAR_GIT_URL}" "${OPENBAR_DIR}" "${GIT_REVISION}"

		if [ "${PROJECT_TYPE}" = "yocto" ]; then
			add_git_submodule "${GIT_MAIN_PATH}" "${YOCTO_POKY_GIT_URL}" "${YOCTO_POKY_DIR}"
		fi

		create_gitignore "${GIT_MAIN_PATH}"

	elif [ "${GIT_TYPE}" = "repo" ]; then
		LOCAL_CONFIG_DIR="${GIT_MAIN_PATH}"

		if [ "${REPO_TYPE}" = "split" ]; then
			init_git "${GIT_MANIFEST_PATH}"
			LOCAL_MANIFEST_DIR="${GIT_MANIFEST_PATH}"
		else
			LOCAL_MANIFEST_DIR="${GIT_MAIN_PATH}"
		fi

		create_manifest "${LOCAL_MANIFEST_DIR}"
	fi

	create_dockerfile "${LOCAL_CONFIG_DIR}"
	create_defconfig "${LOCAL_CONFIG_DIR}"
	create_root "${GIT_MAIN_PATH}"

	if [ "${PROJECT_TYPE}" = "initenv" ]; then
		create_initenv "${LOCAL_CONFIG_DIR}"
	fi

	for REPO in ${GIT_MAIN_PATH} ${GIT_MANIFEST_PATH}; do
		git -C "${TMPDIR}/${REPO}" add -A
		git -C "${TMPDIR}/${REPO}" commit --quiet -m "initial commit"
		git -C "${TMPDIR}/${REPO}" branch --quiet -M "main"

		if [ "${GIT_REMOTE}" = yes ]; then
			git -C "${TMPDIR}/${REPO}" remote add origin "${GIT_BASE_URL}/${REPO}"
		fi
	done
}

ask_project_name() {
	cat >&3 <<-EOF

		This script will guide you through the process of creating
		your project. A number of questions will be asked, first
		general, then more specific.

		For more information about the OpenBar project, please visit
		the project documentation:

		  https://openbar.readthedocs.io

		Once completed, one or more pre-initialized git repositories
		will be created locally. The only thing left to do is to push
		them onto a server.
	EOF

	ask_value "What is the name of your project?" |
		sanitize onlyprint noslash nospace preferedlower
}

ask_project_type() {
	cat >&3 <<-EOF

		The OpenBar project types are:

		  - simple:   all commands will be executed in a container.
		  - initenv:  a simple project whose environment can be
		              initialized with a script.
		  - yocto:    an initenv project that handles Yocto projects.
	EOF

	ask_select "What type of OpenBar project is it?" "simple:initenv:yocto" "simple"
}

ask_git_type() {
	if [ "${PROJECT_TYPE}" = "yocto" ]; then
		GIT_TYPE_DEFAULT="repo"
	else
		GIT_TYPE_DEFAULT="submodule"
	fi

	cat >&3 <<-EOF

		An OpenBar project is made up of several git repositories.
		They can be managed in several ways:

		  - submodule:  a solution provided by git, but which requires
		                a commit for each sub-project update.
		  - repo:       a more dynamic solution, but requiring
		                third-party software.
	EOF

	ask_select "How do you want to manage the git repositories?" "submodule:repo" "${GIT_TYPE_DEFAULT}"
}

ask_repo_type() {
	cat >&3 <<-EOF

		Repo requires a manifest file. This file can be stored in the
		same git repository as the OpenBar configuration files, or in
		a separate repository.

		The advantage of having a dedicated repository is that you can
		maintain two different git flows.
	EOF

	# shellcheck disable=SC2310
	if ask_yesno "Do you want the repo manifest to be stored in a dedicated repository?" "no"; then
		echo "split"
	fi
}

ask_config_dir() {
	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		Once the project sources will be fetched, all configuration
		files will be stored in a specific directory:

		  ${PROJECT_NAME}/
		  └── $(bold "<? configuration directory ?>")
	EOF

	ask_value "What is the path of the configuration directory?" "configs" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_defconfig_file() {
	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		OpenBar uses configuration files to define the actions
		available. The wizard will create a default configuration file.

		  ${PROJECT_NAME}/
		  └── ${CONFIG_DIR}/
		      └── $(bold "<? defconfig file ?>")
	EOF

	ask_value "What is the name of the default configuration file?" "${PROJECT_NAME}_defconfig" |
		sanitize onlyprint noslash nospace trailingdefconfig preferedlower
}

ask_openbar_dir() {
	if [ "${PROJECT_TYPE}" = "yocto" ]; then
		OPENBAR_DIR_DEFAULT="platform/openbar"
	else
		OPENBAR_DIR_DEFAULT="third-party/openbar"
	fi

	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		The OpenBar repository must be part of the project.

		  ${PROJECT_NAME}/
		  ├── ${CONFIG_DIR}/
		  └── $(bold "<? openbar directory ?>")
	EOF

	ask_value "What is the path of the openbar directory?" "${OPENBAR_DIR_DEFAULT}" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_root_file() {
	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		An OpenBar root file must be created in the configuration
		directory to be used as the root Makefile once the project
		has been fetched.

		  ${PROJECT_NAME}/
		  └── ${CONFIG_DIR}/
		      ├── ${DEFCONFIG_FILENAME}
		      └── $(bold "<? openbar root file ?>")
	EOF

	ask_value "What is the name of the openbar root file?" "openbar.mk" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_container_template() {
	cat >&3 <<-EOF

		OpenBar must have at least one container defined. The wizard
		will suggest predefined templates.
	EOF

	TO_BE_EVALUATED=$(download "${WIZARD_URL}/container/${PROJECT_TYPE}/containers.env")

	if [ -z "${TO_BE_EVALUATED}" ]; then
		red >&2 "Failed to download the available container templates"
		exit 1
	fi

	eval "${TO_BE_EVALUATED}"

	if [ -z "${CONTAINER_LIST}" ] || [ -z "${CONTAINER_DEFAULT}" ]; then
		red >&2 "Failed to evaluate the available container templates"
		exit 1
	fi

	ask_select "Which container template do you want to choose?" "${CONTAINER_LIST}" "${CONTAINER_DEFAULT}"
}

ask_initenv_script() {
	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		The wizard will create a sample initenv script that can be
		customized later.

		  ${PROJECT_NAME}/
		  └── ${CONFIG_DIR}/
		      ├── ${DEFCONFIG_FILENAME}
		      └── $(bold "<? initenv script ?>")
	EOF

	ask_value "What is the name of the initenv script?" "init.env" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_yocto_poky_dir() {
	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		The Yocto Poky repository must be part of the project.

		  ${PROJECT_NAME}/
		  ├── ${CONFIG_DIR}/
		  ├── ${OPENBAR_DIR}/
		  └── $(bold "<? yocto poky directory ?>")
	EOF

	ask_value "What is the path of the poky directory?" "platform/poky" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_git_remote() {
	cat >&3 <<-EOF

		The git repositories generated by the wizard may have a
		pre-configured remote URL. If this is the case, all that's
		left to do will be to perform the git push.
	EOF

	# shellcheck disable=SC2310
	if ask_yesno "Do you want the wizard to configure the git remote?" "no"; then
		echo "yes"
	fi
}

ask_git_base_url() {
	cat >&3 <<-EOF

		The git base URL is the first part of the git remote URL.
		It may look something like:

		  - https://github.com
		  - ssh://git@github.com
		  - git@github.com:
	EOF

	ask_value "What is the git base url?" "git@github.com:"
}

ask_git_main_path() {
	if [ "${GIT_REMOTE}" = "yes" ]; then
		# shellcheck disable=SC2312
		cat >&3 <<-EOF

			The git main path is the last part of the git remote URL.

			  ${GIT_BASE_URL}/$(bold "<? git main path ?>")
		EOF
	else
		# shellcheck disable=SC2312
		cat >&3 <<-EOF

			The repo manifest needs to know the git path of the main
			repository on the git server.

			  <manifest>
			    <remote name="origin" ... />

			    <project path="${CONFIG_DIR}" remote="origin" name="$(bold "<? git main path ?>")" />
			  </manifest>
		EOF
	fi

	if [ "${GIT_TYPE}" = "repo" ]; then
		GIT_MAIN_PATH_DEFAULT="${PROJECT_NAME}/${PROJECT_NAME}"
	else
		GIT_MAIN_PATH_DEFAULT="${PROJECT_NAME}"
	fi

	ask_value "What is the path of the main git repository?" "${GIT_MAIN_PATH_DEFAULT}" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_git_manifest_path() {
	# shellcheck disable=SC2312
	cat >&3 <<-EOF

		The git path of the manifest repository is also required.

		  ${GIT_BASE_URL:-<git base url>}/$(bold "<? git manifest path ?>")
	EOF

	ask_value "What is the path of the manifest git repository?" "${PROJECT_NAME}/manifest" |
		sanitize onlyprint noleadingslash notrailingslash nospace preferedlower
}

ask_output_dir() {
	cat >&3 <<-EOF

		Last but not least, the wizard needs to know where to generate
		these repositories locally.
	EOF

	ask_value "What is the output directory?" "." |
		sanitize onlyprint notrailingslash
}

main() {
	GIT_REVISION=$(get_revision)

	if [ -z "${GIT_REVISION}" ]; then
		red >&2 "The provided git revision is invalid: ${GIT_REVNAME}"
		exit 1
	fi

	bold "*** Welcome to the OpenBar wizard!"

	PROJECT_NAME=$(ask_project_name)
	PROJECT_TYPE=$(ask_project_type)

	GIT_TYPE=$(ask_git_type)

	if [ "${GIT_TYPE}" = "repo" ]; then
		REPO_TYPE=$(ask_repo_type)
	fi

	CONFIG_DIR=$(ask_config_dir)
	DEFCONFIG_FILENAME=$(ask_defconfig_file)
	OPENBAR_DIR=$(ask_openbar_dir)

	if [ "${GIT_TYPE}" = "repo" ]; then
		ROOT_FILENAME=$(ask_root_file)
	else
		ROOT_FILENAME="Makefile"
	fi

	CONTAINER_TEMPLATE=$(ask_container_template)

	if [ "${PROJECT_TYPE}" = "initenv" ]; then
		INITENV_SCRIPT=$(ask_initenv_script)

	elif [ "${PROJECT_TYPE}" = "yocto" ]; then
		YOCTO_POKY_DIR=$(ask_yocto_poky_dir)
	fi

	GIT_REMOTE=$(ask_git_remote)

	if [ "${GIT_REMOTE}" = "yes" ]; then
		GIT_BASE_URL=$(ask_git_base_url)
	fi

	if [ "${GIT_REMOTE}" = "yes" ] || [ "${GIT_TYPE}" = "repo" ]; then
		GIT_MAIN_PATH=$(ask_git_main_path)
	else
		GIT_MAIN_PATH="${PROJECT_NAME}"
	fi

	if [ "${REPO_TYPE}" = "split" ]; then
		GIT_MANIFEST_PATH=$(ask_git_manifest_path)
	fi

	OUTPUT_DIR=$(ask_output_dir)

	echo
	bold "*** OpenBar wizard configuration summary"
	cat <<-EOF

		PROJECT_NAME        = ${PROJECT_NAME}

		PROJECT_TYPE        = ${PROJECT_TYPE}

		GIT_TYPE            = ${GIT_TYPE}
		GIT_REVISION        = ${GIT_REVISION}
	EOF
	if [ "${GIT_TYPE}" = "repo" ]; then
		echo "REPO_TYPE           = ${REPO_TYPE:-combined}"
	fi

	cat <<-EOF

		CONFIG_DIR          = ${CONFIG_DIR}
		DEFCONFIG_FILENAME  = ${DEFCONFIG_FILENAME}
		OPENBAR_DIR         = ${OPENBAR_DIR}
		ROOT_FILENAME       = ${ROOT_FILENAME}
		CONTAINER_TEMPLATE  = ${CONTAINER_TEMPLATE}
	EOF
	if [ "${PROJECT_TYPE}" = "initenv" ]; then
		echo "INITENV_SCRIPT      = ${INITENV_SCRIPT}"

	elif [ "${PROJECT_TYPE}" = "yocto" ]; then
		echo "YOCTO_POKY_DIR      = ${YOCTO_POKY_DIR}"
	fi

	cat <<-EOF

		GIT_REMOTE          = ${GIT_REMOTE:-no}
	EOF
	if [ "${GIT_REMOTE}" = "yes" ]; then
		echo "GIT_BASE_URL        = ${GIT_BASE_URL}"
	fi
	if [ "${GIT_REMOTE}" = "yes" ] || [ "${GIT_TYPE}" = "repo" ]; then
		echo "GIT_MAIN_PATH       = ${GIT_MAIN_PATH}"
	fi
	if [ "${REPO_TYPE}" = "split" ]; then
		echo "GIT_MANIFEST_PATH   = ${GIT_MANIFEST_PATH}"
	fi

	cat <<-EOF

		OUTPUT_DIR          = ${OUTPUT_DIR}
	EOF

	# shellcheck disable=SC2310
	ask_yesno "Is this correct?" "yes" || exit 1

	# Generate the specified project
	create_project
	mkdir -p "${OUTPUT_DIR}"
	mv "${TMPDIR}/"* "${OUTPUT_DIR}"

	echo
	bold "*** OpenBar wizard summary"
	cat <<-EOF

		Generation is complete!

		You can check the resulting git repositories and push them
		to your server:
	EOF
	for REPO in ${GIT_MAIN_PATH} ${GIT_MANIFEST_PATH}; do
		REPO_PATH=$(realpath -m --relative-to=. "${OUTPUT_DIR}/${REPO}")
		echo
		if [ "${GIT_REMOTE}" != "yes" ]; then
			# shellcheck disable=SC2312
			echo "  git -C ${REPO_PATH} remote add origin $(bold "<? git url ?>")"
		fi
		echo "  git -C ${REPO_PATH} push origin main"
	done
	cat <<-EOF

		For the next step, don't forget to consult the documentation:

		  https://openbar.readthedocs.io
	EOF
}

# This script should be piped into `sh` and so the stdin will be lost.
# Reconnect it explicitly to /dev/tty.
(main) </dev/tty
