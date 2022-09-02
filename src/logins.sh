#!/bin/sh
# Logins Manager
# Dependencies: gnupg, git, openssl, jq, fzf, wl-clipboard, lua

{ umask_default="$(umask)" && umask 077; } || exit

readonly fname="${0##*/}"
readonly logins_dir="${XDG_DATA_HOME}/logins"
readonly id_file="${logins_dir}/gpg-id"
readonly logins_file="${logins_dir}/logins.json.gpg"
readonly help_msg="\
Usage: $fname set-id <GPG-ID>
       $fname init <git-remote-URL>
       $fname [get|assign|show|copy|move|remove|reset]
       $fname git <command...>
" cmd_get_help_msg="\
Commands:
  <int>[.<int>][t] := print the value (append 't' to get the TOTP code)
  c := toggle the clipboard mode
  l := print the list of selected paths (with format '[n] lines path')
  q := quit
" newline='
' umask_default

print_help() { printf '%s' "$help_msg" 1>&2; }

command_exist() (
	for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || \
		error_msg="${error_msg}Command '${cmd}' not found!\n"
	done; [ -z "$error_msg" ] || { printf '%b' "$error_msg" 1>&2; return 1; }
)

check_init() { { [ -d "$logins_dir" ] && [ -f "$logins_file" ] && [ -f "$id_file" ]; } || { printf "Try 'init' or 'set-id' command!\n" 1>&2; return 1; }; }

create_dir() { ( umask "$umask_default" && mkdir -p "${logins_dir%/*}" ) && mkdir -p "$logins_dir"; }

decrypt() { gpg --quiet --decrypt "$logins_file"; }

encrypt() { id="${2:-"$(cat "$id_file")"}" && printf '%s' "$1" | gpg --quiet --yes --armor --output "$logins_file" --recipient "$id" --encrypt -; }

json_string() ( # json_string <string>
	unset output char; special_chars='\"'; str="$1"
	while [ -n "${char:="${str%"${str#?}"}"}" ]; do
		[ -z "${special_chars##*"${char}"*}" ] && char="\\${char}"
		output="${output}${char}"; str="${str#?}"; char=
	done; printf '"%s"' "$output"
)

json_key() ( # json_key <absolute-path>
	key_path="${1%/}/"; output='.'
	while [ -n "$key_path" ]; do
		key="${key_path%%/*}"; key_path="${key_path#*/}"
		[ -n "$key" ] && output="${output}[$(json_string "$key")]"
	done; printf '%s?' "$output"
)

choose() ( input="$(cat -)" && [ -n "$input" ] && printf '%s' "$input" | fzf "$@" )

cmd_init() {
	command_exist git || return
	[ -d "$logins_dir" ] && { printf "Try 'reset' commmad!\n" 1>&2; return 1; }
	create_dir && git clone "$1" "$logins_dir"
}

cmd_set_id() (
	command_exist gpg || return
	if [ -f "$logins_file" ]; then data="$(decrypt)" && encrypt "$data" "$1"
	else create_dir && encrypt '{}' "$1"; fi || return
	printf '%s' "$1" > "$id_file"
)

get_paths() ( # get_paths <json-string> [true [false]|false [false]]
	exp='([paths(strings, arrays) | select(.[-1] | type == "string")] | map("/" + join("/"))[])'
	[ -n "$2" ] && { "$2" || exp=; exp='(paths(objects) | "/" + join("/") + "/"),'"${exp}" && "${3-true}" && exp='"/",'"${exp}"; }
	jq -rnc --argjson data "$1" '$data | ('"${exp%,})" | sort
)

search_path() (
	paths="${newline}${1}${newline}"
	[ -z "${paths##*"${newline}${2}${newline}"*}" ] || [ "${paths#*"${newline}${2}/"*"${newline}"}" != "$paths" ]
)

cmd_assign() (
	{ check_init && command_exist gpg jq fzf lua5.4 gen-random; } || return
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
	{ check_init && command_exist gpg jq fzf; } || return
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
	{ check_init && command_exist gpg jq fzf; } || return
	unset key_path; data="$(decrypt)" || return
	chosen_path="$(get_paths "$data" true | choose --multi --header='Show?')${newline}" || return
	while [ -n "${key_path:="${chosen_path%%"${newline}"*}"}" ]; do
		printf '\033[1;38;5;8m%s\033[0m ' "$key_path"
		jq -n --argjson data "$data" '$data | '"$(json_key "$key_path")"
		chosen_path="${chosen_path#*"${newline}"}"; key_path=
	done
)

cmd_remove() (
	{ check_init && command_exist gpg jq fzf; } || return
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

field() ( # field <delimiter> <number> <string>
	unset output; str="${3}${1}"; count="$2"
	while [ -n "$str" ] && [ "$count" -gt 0 ]; do count="$((count - 1))"
		output="${str%%"${1}"*}"; str="${str#*"${1}"}"
	done; [ "$count" -gt 0 ] && output=
	printf '%s' "$output"
)

to_binary() ( # to_binary <number>
	i=0; num="$1"; bin=
	while [ "$i" -lt 8 ]; do
		bin="$(printf '\\%03o' "$(((num >> (8 * i)) & 255))")${bin}"
		i="$((i + 1))"
	done; printf '%b' "$bin"
)

is_base32() ( # is_base32 <string>
	[ "$((${#1} % 8))" -eq 0 ] && [ -n "${1##*[!A-Z2-7=]*}" ] && pad="${1#"${1%%=*}"}" && \
	{ [ -z "${pad#=}" ] || [ -z "${pad#===}" ] || [ -z "${pad#====}" ] || [ -z "${pad#======}" ]; }
)

is_integer() ( n="${1#[+-]}" && [ -n "$n" ] && [ -n "${n##*[!0-9]*}" ] && [ -n "${n##0?*}" ] )

# clip <string>
clip() { command_exist wl-copy timeout && timeout 30 wl-copy --foreground --trim-newline "$1" & }

# See 'RFC 6238' and 'RFC 4226'
totp() ( # totp <base32-key>[:digest[:digits[:interval[:offset]]]]
	command_exist openssl || return
	{ [ -n "${1##*"${newline}"*}" ] && key="$(field : 1 "$1" | tr -d '[:space:]' | tr '0189[:lower:]' 'OLBG[:upper:]')" && is_base32 "$key"; } \
	|| { printf "TOTP: value must be in format '<base32-key>[:digest[:digits[:interval[:offset]]]]' without newlines\n" 1>&2; return 1; }
	time="$(date +%s)"; key="$(printf '%s' "$key" | base32 --decode - | od --output-duplicates --address-radix=n --format=x1 | tr -d '[:space:]')"
	digest="$(field : 2 "$1" | tr '[:upper:]' '[:lower:]')"; digits="$(field : 3 "$1")"; interval="$(field : 4 "$1")"; offset="$(field : 5 "$1")"
	case "${digest:=sha1}" in sha1|sha256|sha512) ;; *) printf "TOTP: digest must be sha1, sha256 or sha512 (default='sha1')\n" 1>&2; return 1 ;; esac
	{ is_integer "${digits:=6}" && [ "$digits" -ge 6 ] && [ "$digits" -le 8 ]; } || { printf 'TOTP: digits must be 6, 7 or 8 (default=6)\n' 1>&2; return 1; }
	{ is_integer "${interval:=30}" && [ "$interval" -gt 0 ]; } || { printf 'TOTP: interval must be greater than 0 (default=30)\n' 1>&2; return 1; }
	{ is_integer "${offset:=0}" && [ "$offset" -le "$time" ]; } || { printf 'TOTP: offset must be less than or equal to the current time (default=0)\n' 1>&2; return 1; }
	hmac="$(to_binary "$(((time - offset) / interval))" | openssl dgst "-${digest}" -mac HMAC -macopt "hexkey:${key}")" || return
	hmac="0x${hmac##*[[:space:]]}"; i="$((3 + (hmac & 0xf) * 2))"; m="$(printf "1%0${digits}d" 0)"
	h="0x$(printf '%s' "$hmac" | cut -c "${i}-$((i + 7))" -)"
	printf "%0${digits}d\n" "$(((h & 0x7fffffff) % m))"
)

list() ( # list <data> <chosen-path>
	unset key_path; count=0; chosen_path="${2}${newline}"
	while [ -n "${key_path:="${chosen_path%%"${newline}"*}"}" ]; do
		length="$(jq -rnc --argjson data "$1" '$data | '"$(json_key "$key_path")"' | if type == "array" then length else 1 end')" \
		&& printf '[%d] %d %s\n' "$count" "$length" "$key_path"
		chosen_path="${chosen_path#*"${newline}"}"; count="$((count + 1))"; key_path=
	done
)

get_path_value() ( # get_path_value <data> <paths> <command>
	unset index nkey key; id="${3%t}"
	[ -n "${id##*.*.*}" ] && is_integer "${nkey="${id%%.*}"}" && [ "$nkey" -ge 0 ] \
	&& { [ -n "${id##*.*}" ] || { is_integer "${index="${id##*.}"}" && [ "$index" -ge 0 ]; }; } \
	&& [ -n "${key="$(field "$newline" "$((nkey + 1))" "$2")"}" ] && key="$(json_key "$key")" && if [ -n "$index" ]
	then value="$(jq -rnc --argjson data "$1" --argjson i "$((index))" '$data | '"${key}"' | if type == "array" then .[$i]? // "" elif $i == 0 then . else "" end')"
	else value="$(jq -rnc --argjson data "$1" '$data | '"${key}"' | if type == "array" then join("\n") else . end')"; fi \
	&& { { [ -z "${3#"${id}"}" ] && printf '%s\n' "$value"; } || totp "$value"; }
)

cmd_get() (
	{ check_init && command_exist gpg jq fzf; } || return
	unset key_path input; clip_mode=0
	data="$(decrypt)" && chosen_path="$(get_paths "$data" | choose --multi)" \
	&& printf "Enter 'h' for more information.\n" \
	&& while [ "${input=l}" != 'q' ]; do case "$input" in
		c) clip_mode="$((clip_mode ^ 1))"; printf '%d\n' "$clip_mode" ;;
		l) list "$data" "$chosen_path" ;;
		h) printf '%s' "$cmd_get_help_msg" ;;
		*) [ -n "$input" ] && if ! value="$(get_path_value "$data" "$chosen_path" "$input")"; then printf 'invalid input!\n'
			elif [ "$clip_mode" -eq 1 ]; then clip "$value"; else printf '%s\n' "$value" ; fi
	esac; printf '> '; read -r input; done
)

case "$1" in
	reset) [ "$#" -eq 1 ] || { print_help; exit 1; }; rm -rf "$logins_dir" ;;
	assign) [ "$#" -eq 1 ] || { print_help; exit 1; }; cmd_assign ;;
	show) [ "$#" -eq 1 ] || { print_help; exit 1; }; cmd_show ;;
	copy) [ "$#" -eq 1 ] || { print_help; exit 1; }; cmd_copy ;;
	move) [ "$#" -eq 1 ] || { print_help; exit 1; }; cmd_copy true ;;
	remove) [ "$#" -eq 1 ] || { print_help; exit 1; }; cmd_remove ;;
	get) [ "$#" -eq 1 ] || { print_help; exit 1; }; cmd_get ;;
	set-id) [ "$#" -eq 2 ] || { print_help; exit 1; }; cmd_set_id "$2" ;;
	init) [ "$#" -eq 2 ] || { print_help; exit 1; }; cmd_init "$2" ;;
	git) shift; command_exist git && create_dir && git -C "$logins_dir" "$@" ;;
	*) print_help; exit 1 ;;
esac
