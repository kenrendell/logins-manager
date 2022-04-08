#!/bin/sh

# Dependencies: gnupg, git, oath-toolkit, jq, fzf, wl-clipboard, lua

cd "${0%/*}" || exit 1

fname="${0##*/}"
data_dir='../data'
id_file="$data_dir/gpg-id"
logins_file="$data_dir/logins.json"
id="$(cat "$id_file" 2>/dev/null)"
help_msg="\
Usage: $fname init <ID>
       $fname show [key...]
       $fname assign <key> [value...]
       $fname assign-key <key> <key-value>
       $fname assign-passwd <key> [length]
       $fname copy <key> [key...] <destination-key>
       $fname remove <key> [key...]
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
"

print_help() { printf '%s' "$help_msg" 1>&2; }

command_exist() (
	for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || \
		error_msg="${error_msg}Command '${cmd}' not found!\n"
	done; [ -z "$error_msg" ] || { printf '%b' "$error_msg" 1>&2; return 1; }
)

check_init() { { [ -d "$data_dir" ] && [ -f "$logins_file" ] && [ -f "$id_file" ]; } || { printf "Try 'init' command first!\n" 1>&2; return 1; }; }

git_cmd() { git -C "$data_dir" "$@"; }

git_init() { [ "$(git_cmd rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || git_cmd init; }

git_save() { git_init && git_cmd add --all && git_cmd commit --message= --allow-empty-message; }

decrypt() { gpg --quiet --decrypt "$logins_file"; }

encrypt() { printf '%s' "$1" | gpg --quiet --yes --armor --output "$logins_file" --recipient "${2:-${id}}" --encrypt -; }

json_string() (
	unset output char; special_chars='\"'; str="$1"
	while [ -n "${char:="${str%"${str#?}"}"}" ]; do
		[ -z "${special_chars##*"${char}"*}" ] && char="\\${char}"
		output="${output}${char}"; str="${str#?}"; char=
	done; printf '%s' "$output"
)

json_key() (
	unset output
	for key_path in "$@"; do [ "${output=.}" = '.' ] || output="${output},."
		[ -n "${key_path##*/}" ] && key_path="${key_path}/"
		while [ -n "$key_path" ]; do
			key="${key_path%%/*}"; key_path="${key_path#*/}"
			[ -n "$key" ] && output="${output}[\"$(json_string "$key")\"]"
		done; output="${output}?"
	done; printf '%s' "$output"
)

json_value() (
	output="\"$(json_string "$1")\""
	if [ "$#" -gt 1 ]; then shift
		for value in "$@"; do output="${output},\"$(json_string "$value")\""; done
		output="[${output}]"
	fi; printf '%s' "$output"
)

choose() (
	input="$(cat -)"
	[ -z "$input" ] && return 1
	printf '%s' "$input" | fzf --no-multi
)

cmd_init() (
	command_exist gpg git || return
	if [ -f "$logins_file" ]; then data="$(decrypt)" && encrypt "$data" "$1"
	else mkdir -p "$data_dir" && encrypt '{}' "$1"; fi || return
	printf '%s\n' "$1" > "$id_file"; chmod 700 "$data_dir"
	chmod 600 "$id_file" "$logins_file"; git_save
)

cmd_show() (
	{ command_exist gpg jq && check_init; } || return
	data="$(decrypt)" && jq -n --argjson data "$data" "\$data | $(json_key "${@:-}")"
)

cmd_assign() (
	{ command_exist gpg git jq && check_init; } || return
	assign_key_value="$1"; shift
	key="$(json_key "$1")"; shift
	[ -z "${key#'.?'}" ] && { printf 'Empty key is not allowed!\n' 1>&2; return 1; }
	data="$(decrypt)" || return 1
	if "$assign_key_value"; then value="$(json_key "$1")"
		jq -nce --argjson data "$data" "\$data | $value" >/dev/null || return 1
	else { [ "$#" -gt 0 ] && value="$(json_value "$@")"; } || value='{}'; fi
	data="$(jq -nc --argjson data "$data" "\$data | $key = $value")" || return 1
	encrypt "$data" && git_save
)

cmd_copy() (
	{ command_exist gpg git jq && check_init; } || return
	unset keys; data="$(decrypt)" || return 1
	while [ "$#" -gt 1 ]; do key="$(json_key "$1")"; shift
		{ [ -n "${key#'.?'}" ] && jq -nce --argjson data "$data" "\$data | $key" >/dev/null; } || continue
		{ [ -n "$keys" ] && keys="${keys},${key}"; } || keys="$key"
	done; [ -z "$keys" ] && return 1
	data="$(jq -nc --argjson data "$data" "reduce path(${keys}) as \$item (\$data; ($(json_key "$1") | .[\$item[-1]]) = getpath(\$item))")" || return 1
	encrypt "$data" && git_save
)

cmd_remove() (
	{ command_exist gpg git jq && check_init; } || return
	unset keys; data="$(decrypt)" || return 1
	while [ "$#" -gt 0 ]; do key="$(json_key "$1")"; shift
		if [ -z "${key#'.?'}" ]; then keys='.?'
			printf 'Remove all entries [YES]? '; read -r ans
			[ "$ans" = 'YES' ] && break; return 1
		fi; { [ -n "$keys" ] && keys="${keys},${key}"; } || keys="$key"
	done; data="$(jq -nc --argjson data "$data" "\$data | del(${keys}) // {}")" || return 1
	encrypt "$data" && git_save
)

cmd_get() (
	{ command_exist gpg jq fzf && check_init; } || return
	data="$(decrypt)" || return 1
	chosen_path="$(jq -rnc --argjson data "$data" '$data | paths(scalars) | if (.[-1] | type == "number") then .[:-1] else . end | join("/")' | uniq | choose)" || return 1
	key="$(json_key "$chosen_path")"
	if jq -nce --argjson data "$data" "\$data | $key | type == \"array\"" >/dev/null; then
		jq -rnc --argjson data "$data" "\$data | $key | .[]" | choose
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
	init) [ "$#" -eq 2 ] || { print_help; exit 1; }; cmd_init "$2" ;;
	show) [ "$#" -ge 1 ] || { print_help; exit 1; }; shift; cmd_show "$@" ;;
	assign) [ "$#" -ge 2 ] || { print_help; exit 1; }; shift; cmd_assign false "$@" ;;
	assign-key) [ "$#" -eq 3 ] || { print_help; exit 1; }; cmd_assign true "$2" "$3" ;;
	assign-passwd) [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && is_digit "$3"; } || { print_help; exit 1; }
		cmd_assign false "$2" "$(./gen-passwd.lua "${3:-32}")" ;;
	copy) [ "$#" -ge 3 ] || { print_help; exit 1; }; shift; cmd_copy "$@" ;;
	remove) [ "$#" -ge 2 ] || { print_help; exit 1; }; shift; cmd_remove "$@" ;;
	get) shift; eval "$(get_opts '--clip|=')" && value="$(cmd_get)" && \
		if "$opt1"; then clip "${opt1_arg-30}" "$value"; else printf '%s\n' "$value"; fi ;;
	get-totp) shift; eval "$(get_opts '--clip|= --hex --mode= --digits= --time-step=')" && value="$(cmd_get)" && \
		value="$(totp "$opt2" "${opt3_arg-SHA1}" "${opt4_arg-6}" "${opt5_arg-30}" "$value")" && \
		if "$opt1"; then clip "${opt1_arg-30}" "$value"; else printf '%s\n' "$value"; fi ;;
	git) shift; check_init && git_init && git_cmd "$@" ;;
	*) print_help; exit 1 ;;
esac
