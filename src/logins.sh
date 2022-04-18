#!/bin/sh

# Dependencies: gnupg, git, oath-toolkit, jq, fzf, wl-clipboard, lua

{ umask_default="$(umask)" && umask 077; } || exit

fname="${0##*/}"
logins_dir="${LOGINS_DIR:-"${XDG_DATA_HOME}/logins"}"
id_file="${logins_dir}/gpg-id"
logins_file="${logins_dir}/logins.json.gpg"
help_msg="\
Usage: $fname init <ID>
       $fname [assign|show|copy|move|remove|reset]
       $fname get [--clip[=n]]
       $fname get-totp [--clip[=n]] [--hex] [--mode=s] [--digits=n] [--time-step=n]
       $fname git <command...>

GET command options:
  --clip[=n]    := copy to clipboard (wayland only)

GET-TOTP command options (see 'oathtool' manual):
  --clip[=n]    := copy to clipboard (wayland only)
  --hex         := use hex encoding instead of base32
  --mode=s      := use mode 'SHA1', 'SHA256', or 'SHA512' (default='SHA1')
  --digits=n    := number of digits in one-time password (default=6)
  --time-step=n := time step duration (default=30)

Environment variables:
  LOGINS_DIR    := path to directory where the logins is stored (default=\"\${XDG_DATA_HOME}/logins\")
"
newline='
'

print_help() { printf '%s' "$help_msg" 1>&2; }

command_exist() (
	for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || \
		error_msg="${error_msg}Command '${cmd}' not found!\n"
	done; [ -z "$error_msg" ] || { printf '%b' "$error_msg" 1>&2; return 1; }
)

check_init() { { [ -d "$logins_dir" ] && [ -f "$logins_file" ] && [ -f "$id_file" ]; } || { printf "Try 'init' command first!\n" 1>&2; return 1; }; }

create_dir() { ( umask "$umask_default" && mkdir -p "${logins_dir%/*}" ) && mkdir -p "$logins_dir"; }

decrypt() { gpg --quiet --decrypt "$logins_file"; }

encrypt() { id="${2:-"$(cat "$id_file")"}" && printf '%s' "$1" | gpg --quiet --yes --armor --output "$logins_file" --recipient "$id" --encrypt -; }

json_string() (
	unset output char; special_chars='\"'; str="$1"
	while [ -n "${char:="${str%"${str#?}"}"}" ]; do
		[ -z "${special_chars##*"${char}"*}" ] && char="\\${char}"
		output="${output}${char}"; str="${str#?}"; char=
	done; printf '"%s"' "$output"
)

json_key() (
	unset output
	for key_path in "$@"; do output="${output}."
		[ -n "${key_path##*/}" ] && key_path="${key_path}/"
		while [ -n "$key_path" ]; do
			key="${key_path%%/*}"; key_path="${key_path#*/}"
			[ -n "$key" ] && output="${output}[$(json_string "$key")]"
		done; output="${output}?,"
	done; printf '%s' "${output%,}"
)

choose() ( input="$(cat -)" && [ -n "$input" ] && printf '%s' "$input" | fzf "$@" )

cmd_init() (
	command_exist gpg || return
	if [ -f "$logins_file" ]; then data="$(decrypt)" && encrypt "$data" "$1"
	else create_dir && encrypt '{}' "$1"; fi || return
	printf '%s' "$1" > "$id_file"
)

get_paths() (
	exp='([paths(strings, arrays) | select(.[-1] | type == "string")] | map("/" + join("/"))[])'
	[ -n "$2" ] && { "$2" || exp=; exp='(paths(objects) | "/" + join("/") + "/"),'"${exp}" && "${3-true}" && exp='"/",'"${exp}"; }
	jq -rnc --argjson data "$1" '$data | ('"${exp%,})" | sort
)

search_path() (
	paths="${newline}${1}${newline}"
	[ -z "${paths##*"${newline}${2}${newline}"*}" ] || [ "${paths#*"${newline}${2}/"*"${newline}"}" != "$paths" ]
)

cmd_assign() (
	command_exist gpg jq fzf lua5.4 gen-random || return
	unset value; data="$(decrypt)" || return
	paths="$(get_paths "$data" true)"
	chosen_path="$(printf '%s' "$paths" | choose --no-multi --header='Assign to?')" || return
	if [ -z "${chosen_path##*/}" ]; then
		printf '%s' "$chosen_path"; read -r input || return
		{ [ -z "${input##/*}" ] || [ -z "${input##*//*}" ] || [ "${chosen_path}${input}" = '/' ]; } && { printf 'Invalid path!\n' 1>&2; return 1; }
		[ -n "$input" ] && search_path "$paths" "${chosen_path}${input%%/*}" && printf "Path '%s' exist!\n" "${chosen_path}${input%%/*}" 1>&2 && return 1
		chosen_path="${chosen_path}${input}"
	else printf '%s\n' "$chosen_path"; fi
	printf 'Assign value [(C)ustom|(r)andom|(p)ath|(e)mpty]? '
	read -r input && case "${input:-c}" in
		C|c) printf 'Enter the value and press [CTRL-D] when finished:\n'
			while read -r input; do value="${value},$(json_string "$input")"
			done && [ -n "$value" ] && value="${value#,}" && { [ -n "${value##*[!\\]'","'*}" ] || value="[${value}]"; } ;;
		r) printf 'Length [32]: '; read -r input && value="$(gen-random "${input:-32}")" && value="$(json_string "$value")" ;;
		p) value="$(printf '%s' "$paths" | choose --no-multi)" && value="$(json_key "$value")" ;;
		e) value='{}' ;;
		*) false ;;
	esac && data="$(jq -nc --argjson data "$data" '$data | '"$(json_key "$chosen_path") = ${value}")" && encrypt "$data"
)

cmd_copy() (
	command_exist gpg jq fzf || return
	unset keys key_path move; data="$(decrypt)" || return
	{ "${move="${1-false}"}" && header='Move'; } || header='Copy'
	chosen_path="$(get_paths "$data" true false | choose --multi --header="${header}?")${newline}" || return
	target_path="${newline}$(get_paths "$data" false)${newline}"
	while [ -n "${key_path:="${chosen_path%%"${newline}"*}"}" ]; do
		"$move" && [ "$target_path" != "$newline" ] && while true; do mark="${key_path#"${key_path%/}"}"
			lside="${target_path%"${newline}${key_path%/*"${mark}"}/${newline}"*}"
			[ "$lside" = "$target_path" ] && [ -n "$mark" ] && lside="${target_path%"${newline}${key_path}"*"${newline}"*}"
			[ "$lside" = "$target_path" ] && break
			rside="${target_path#"${lside}"}"
			target_path="${lside}${newline}${rside#"${newline}"*"${newline}"}"
		done; keys="${keys},$(json_key "$key_path")"
		chosen_path="${chosen_path#*"${newline}"}"; key_path=
	done; target_path="${target_path#"${newline}"}"
	chosen_path="$(printf '%s' "${target_path%"${newline}"}" | choose --no-multi --header="$header to?")" || return
	target_key="$(json_key "$chosen_path")"
	data="$(jq -nc --argjson data "$data" '$data | '"${target_key} = reduce path(${keys#,}"') as $item ('"${target_key}"'; .[$item[-1]] = ($data | getpath($item)))')" || return
	"$move" && { data="$(jq -nc --argjson data "$data" '$data | del('"${keys#,})")" || return; }
	encrypt "$data"
)

cmd_show() (
	command_exist gpg jq fzf || return
	unset key_path; data="$(decrypt)" || return
	chosen_path="$(get_paths "$data" true | choose --multi --header='Show?')${newline}" || return
	while [ -n "${key_path:="${chosen_path%%"${newline}"*}"}" ]; do
		printf '\033[1;38;5;8m%s\033[0m ' "$key_path"
		jq -n --argjson data "$data" '$data | '"$(json_key "$key_path")"
		chosen_path="${chosen_path#*"${newline}"}"; key_path=
	done
)

cmd_remove() (
	command_exist gpg jq fzf || return
	unset keys key_path; data="$(decrypt)" || return
	chosen_path="$(get_paths "$data" true | choose --multi --header='Remove?')${newline}" || return
	while [ -n "${key_path:="${chosen_path%%"${newline}"*}"}" ]; do
		if [ "$key_path" = '/' ]; then printf 'Remove all entries [YES]? '
			{ read -r input && [ "$input" = 'YES' ]; } || return
			keys="$(json_key "$key_path")"; break
		fi; keys="${keys},$(json_key "$key_path")"
		chosen_path="${chosen_path#*"${newline}"}"; key_path=
	done; data="$(jq -nc --argjson data "$data" '$data | del('"${keys#,}) // {}")" && encrypt "$data"
)

cmd_get() (
	command_exist gpg jq fzf || return
	data="$(decrypt)" || return
	chosen_path="$(get_paths "$data" | choose --no-multi)" || return
	key="$(json_key "$chosen_path")"
	if jq -nce --argjson data "$data" "\$data | $key | type == \"array\"" >/dev/null; then
		jq -rnc --argjson data "$data" "\$data | $key | .[]" | choose --no-multi --header="$chosen_path"
	else jq -rnc --argjson data "$data" "\$data | $key"; fi
)

is_digit() (
	for n in "$@"; do
		{ [ -z "$n" ] || { [ "${#n}" -gt 1 ] && [ "${n#0}" != "$n" ]; }; } && return 1
		while [ -n "$n" ]; do [ "${n#[0-9]}" != "$n" ] || return 1; n="${n#[0-9]}"; done
	done
)

clip() {
	command_exist wl-copy || return
	is_digit "$1" || { print_help; return 1; }
	[ -z "$WAYLAND_DISPLAY" ] && { printf 'No wayland display!\n' 1>&2; return 1; }
	if [ "$1" -eq 0 ]; then wl-copy --trim-newline "$2"
	else timeout "$1" wl-copy --foreground --trim-newline "$2" & fi
}

totp() {
	command_exist oathtool || return
	is_digit "$3" "$4" || { print_help; return 1; }
	if "$1"; then oathtool --totp="$2" --digits="$3" --time-step-size="$4" "$5"
	else oathtool --base32 --totp="$2" --digits="$3" --time-step-size="$4" "$5"; fi
}

get_opts() (
	cmd='while true; do case "$1" in "") break'; count=1
	for opt in $1; do cmd="opt${count}=false; $cmd"
		if [ -z "${opt%%*|=}" ]; then opt="${opt%|=}"
			cmd="${cmd};; '${opt}'|'${opt}='*) \$opt${count} && { print_help; return 1; }; opt${count}=true; [ -z \"\${1##'${opt}='*}\" ] && opt${count}_arg=\"\${1#'${opt}='}\""
		elif [ -z "${opt%%*=}" ]; then
			cmd="${cmd};; '${opt}'*) \$opt${count} && { print_help; return 1; }; opt${count}=true; opt${count}_arg=\"\${1#'${opt}'}\""
		else cmd="${cmd};; '${opt}') \$opt${count} && { print_help; return 1; }; opt${count}=true"; fi
		count=$((count + 1))
	done; printf '%s;; *) print_help; return 1;; esac; shift; done' "$cmd"
)

case "$1" in
	reset) [ "$#" -eq 1 ] || { print_help; exit 1; }; rm -rf "$logins_dir" ;;
	init) [ "$#" -eq 2 ] || { print_help; exit 1; }; cmd_init "$2" ;;
	assign) [ "$#" -eq 1 ] || { print_help; exit 1; }; check_init && cmd_assign ;;
	show) [ "$#" -eq 1 ] || { print_help; exit 1; }; check_init && cmd_show ;;
	copy) [ "$#" -eq 1 ] || { print_help; exit 1; }; check_init && cmd_copy ;;
	move) [ "$#" -eq 1 ] || { print_help; exit 1; }; check_init && cmd_copy true ;;
	remove) [ "$#" -eq 1 ] || { print_help; exit 1; }; check_init && cmd_remove ;;
	get) shift; eval "$(get_opts '--clip|=')" && check_init && value="$(cmd_get)" && \
		if "$opt1"; then clip "${opt1_arg-30}" "$value"; else printf '%s\n' "$value"; fi ;;
	get-totp) shift; eval "$(get_opts '--clip|= --hex --mode= --digits= --time-step=')" && check_init && \
		value="$(cmd_get)" && value="$(totp "$opt2" "${opt3_arg-SHA1}" "${opt4_arg-6}" "${opt5_arg-30}" "$value")" && \
		if "$opt1"; then clip "${opt1_arg-30}" "$value"; else printf '%s\n' "$value"; fi ;;
	git) shift; command_exist git && create_dir && git -C "$logins_dir" "$@" ;;
	*) print_help; exit 1 ;;
esac
