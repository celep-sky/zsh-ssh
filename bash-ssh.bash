#!/usr/bin/env bash

# Better completion for ssh in Bash.
# Bash port of zsh-ssh with reduced external dependencies.

SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-$HOME/.ssh/config}"
BASH_SSH_INCLUDE_KNOWN_HOSTS="${BASH_SSH_INCLUDE_KNOWN_HOSTS:-${ZSH_SSH_INCLUDE_KNOWN_HOSTS:-0}}"
BASH_SSH_KNOWN_HOSTS_FILE="${BASH_SSH_KNOWN_HOSTS_FILE:-${ZSH_SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}}"

declare -i _bash_ssh_parse_depth=0
declare -i _bash_ssh_has_assoc=0

if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then
  declare -A _bash_ssh_seen_config_files=()
  _bash_ssh_has_assoc=1
else
  _bash_ssh_seen_config_files_list=$'\n'
fi

_bash_ssh_seen_reset() {
  if ((_bash_ssh_has_assoc)); then
    _bash_ssh_seen_config_files=()
  else
    _bash_ssh_seen_config_files_list=$'\n'
  fi
}

_bash_ssh_seen_has() {
  local path="$1"
  if ((_bash_ssh_has_assoc)); then
    [[ -n "${_bash_ssh_seen_config_files[$path]}" ]]
    return
  fi
  [[ "$_bash_ssh_seen_config_files_list" == *$'\n'"$path"$'\n'* ]]
}

_bash_ssh_seen_add() {
  local path="$1"
  if ((_bash_ssh_has_assoc)); then
    _bash_ssh_seen_config_files[$path]=1
  else
    _bash_ssh_seen_config_files_list+="$path"$'\n'
  fi
}

_bash_ssh_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

_bash_ssh_normalize_path() {
  local input="$1" path part
  local -a parts stack

  if [[ $input == ~* ]]; then
    input="${input/#~/$HOME}"
  fi

  if [[ $input != /* ]]; then
    path="$PWD/$input"
  else
    path="$input"
  fi

  IFS='/' read -r -a parts <<< "$path"
  stack=()
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.)
        ;;
      ..)
        if ((${#stack[@]} > 0)); then
          unset "stack[${#stack[@]}-1]"
        fi
        ;;
      *)
        stack+=("$part")
        ;;
    esac
  done

  printf '/%s' "${stack[*]}" | tr ' ' '/'
}

# Parse config recursively and resolve Include directives.
_parse_config_file() {
  local input_path="$1"
  local logical_config_path config_file_path include_base_dir
  local line rest raw_path expanded include_file_path
  local -a include_paths

  logical_config_path="$input_path"
  if [[ $logical_config_path == ~* ]]; then
    logical_config_path="${logical_config_path/#~/$HOME}"
  fi
  if [[ $logical_config_path != /* ]]; then
    logical_config_path="$PWD/$logical_config_path"
  fi

  include_base_dir="${logical_config_path%/*}"
  if [[ "$include_base_dir" == "$logical_config_path" ]]; then
    include_base_dir='.'
  fi

  config_file_path="$(_bash_ssh_normalize_path "$logical_config_path")"
  [[ -r "$config_file_path" ]] || return 0

  if ((_bash_ssh_parse_depth <= 0)); then
    _bash_ssh_parse_depth=0
    _bash_ssh_seen_reset
  fi

  ((_bash_ssh_parse_depth++))
  {
    if _bash_ssh_seen_has "$config_file_path"; then
      return 0
    fi
    _bash_ssh_seen_add "$config_file_path"

    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ $line =~ ^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]=]+(.*)$ ]]; then
        rest="${BASH_REMATCH[1]}"
        include_paths=()
        # shellcheck disable=SC2206
        include_paths=($rest)

        for raw_path in "${include_paths[@]}"; do
          expanded="$(eval "printf '%s' $raw_path")"

          if [[ $expanded == ~* ]]; then
            expanded="${expanded/#~/$HOME}"
          fi
          if [[ $expanded != /* ]]; then
            expanded="$include_base_dir/$expanded"
          fi

          while IFS= read -r include_file_path; do
            [[ -f "$include_file_path" ]] || continue
            printf '\n'
            _parse_config_file "$include_file_path"
          done < <(compgen -G "$expanded" || true)
        done
      else
        printf '%s\n' "$line"
      fi
    done < "$config_file_path"
  }

  ((_bash_ssh_parse_depth--))
  if ((_bash_ssh_parse_depth <= 0)); then
    _bash_ssh_parse_depth=0
    _bash_ssh_seen_reset
  fi
}

_ssh_known_hosts_list() {
  local known_hosts_file="$BASH_SSH_KNOWN_HOSTS_FILE"

  [[ -f "$known_hosts_file" ]] || return 0

  command awk '
    function emit_host(host) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", host)

      if (!host || host ~ /^\|1\|/ || host ~ /[*?!]/) {
        return
      }

      if (host ~ /^\[[^]]+\]:[0-9]+$/) {
        host = substr(host, 2, index(host, "]") - 2)
      }

      if (host) {
        printf "%s|->|%s| | |[\\033[00;34mknown_hosts\\033[0m]\n", host, host
      }
    }

    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    $1 ~ /^@/ { next }

    {
      split($1, hosts, ",")
      for (i in hosts) {
        emit_host(hosts[i])
      }
    }
  ' "$known_hosts_file"
}

_ssh_host_list() {
  local ssh_config host_list tag_query
  local -a passthrough_args
  local arg

  ssh_config="$(_parse_config_file "$SSH_CONFIG_FILE")"

  if command -v grep >/dev/null 2>&1; then
    ssh_config="$(printf '%s\n' "$ssh_config" | command grep -v -E '^\s*#[^_]')"
  else
    ssh_config="$(printf '%s\n' "$ssh_config" | command awk '!/^[[:space:]]*#[^_]/')"
  fi

  ssh_config="$(printf '%s\n' "$ssh_config" | command awk '/^[[:space:]]*[Hh]ost[[:space:]]|^[[:space:]]*[Mm]atch[[:space:]]/{print ""} {print}')"

  host_list="$(printf '%s\n' "$ssh_config" | command awk '
    function join(array, start, end, sep, result, i) {
      if (sep == "")
        sep = " "
      else if (sep == SUBSEP)
        sep = ""
      result = array[start]
      for (i = start + 1; i <= end; i++)
        result = result sep array[i]
      return result
    }

    function parse_line(line) {
      gsub(/^[[:space:]]+/, "", line)
      n = split(line, line_array, /[[:space:]]*=[[:space:]]*|[[:space:]]+/)

      key = line_array[1]
      value = join(line_array, 2, n)

      return key "#-#" value
    }

    function starts_or_ends_with_star(str) {
      start_char = substr(str, 1, 1)
      end_char = substr(str, length(str), 1)

      return start_char == "*" || end_char == "*" || start_char == "!"
    }

    BEGIN {
      IGNORECASE = 1
      FS="\n"
      RS=""
    }
    {
      match_directive = ""

      user = " "
      host_name = ""
      alias = ""
      aliases = ""
      tag = ""
      tag_formated = " "
      desc = ""
      desc_formated = " "

      for (line_num = 1; line_num <= NF; ++line_num) {
        line = parse_line($line_num)

        split(line, tmp, "#-#")

        key = tolower(tmp[1])
        value = tmp[2]

        if (key == "match") { match_directive = value }

        if (key == "host") { aliases = value }
        if (key == "user") { user = value }
        if (key == "hostname") { host_name = value }
        if (key == "tag" && !tag) { tag = value }
        if (key == "#_desc") { desc = value }
      }

      if (tag) {
        tag_formated = sprintf("[\\033[00;36m%s\\033[0m]", tag)
      }

      if (desc) {
        desc_formated = sprintf("[\\033[00;34m%s\\033[0m]", desc)
      }

      n_aliases = split(aliases, alias_list, " ")
      for (i = 1; i <= n_aliases; i++) {
        alias = alias_list[i]
        effective_hostname = host_name ? host_name : alias

        if (!(effective_hostname && !starts_or_ends_with_star(effective_hostname)) || !(alias && !starts_or_ends_with_star(alias)) || match_directive) {
          continue
        }

        if (!(alias in alias_hn)) {
          alias_hn[alias] = effective_hostname
          alias_user[alias] = user
          alias_tag[alias] = tag_formated
          alias_desc[alias] = desc_formated
          if (host_name) alias_explicit_hn[alias] = 1
        } else {
          if (host_name && !alias_explicit_hn[alias]) {
            alias_hn[alias] = host_name
            alias_explicit_hn[alias] = 1
          }
          if (user != " " && alias_user[alias] == " ") {
            alias_user[alias] = user
          }
          if (tag_formated != " " && alias_tag[alias] == " ") {
            alias_tag[alias] = tag_formated
          }
          if (desc_formated != " " && alias_desc[alias] == " ") {
            alias_desc[alias] = desc_formated
          }
        }
      }
    }
    END {
      for (a in alias_hn) {
        printf "%s|->|%s|%s|%s|%s\n", a, alias_hn[a], alias_user[a], alias_tag[a], alias_desc[a]
      }
    }
  ')"

  if [[ "$BASH_SSH_INCLUDE_KNOWN_HOSTS" == "1" ]]; then
    host_list+=$'\n'"$(_ssh_known_hosts_list)"
  fi

  passthrough_args=()
  for arg in "$@"; do
    [[ $arg == -* ]] && continue
    passthrough_args+=("$arg")
  done

  if [[ ${#passthrough_args[@]} -gt 0 ]]; then
    if [[ "${passthrough_args[0]}" == tag:* ]]; then
      tag_query="${passthrough_args[0]#tag:}"
      host_list="$(command awk -F '|' -v q="$tag_query" '
        function plain_tag(value) {
          gsub(/\033\[[0-9;]*m/, "", value)
          gsub(/^\[|\]$/, "", value)
          return value
        }

        BEGIN { q = tolower(q) }
        NF >= 6 && (q == "" || index(tolower(plain_tag($5)), q) > 0)
      ' <<< "$host_list")"
    else
      if command -v grep >/dev/null 2>&1; then
        host_list="$(command grep -i -- "${passthrough_args[0]}" <<< "$host_list")"
      else
        host_list="$(command awk -v q="${passthrough_args[0]}" 'BEGIN { q=tolower(q) } index(tolower($0), q) > 0' <<< "$host_list")"
      fi
    fi
  fi

  host_list="$(printf '%s\n' "$host_list" | command sort -u)"
  printf '%s\n' "$host_list"
}

_bash_ssh_columnize() {
  if command -v column >/dev/null 2>&1; then
    command column -t -s '|'
    return
  fi

  command awk -F '|' '{
    for (i = 1; i <= NF; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
    }

    output = $1
    for (i = 2; i <= NF; i++) {
      output = output "  " $i
    }
    print output
  }'
}

_fzf_list_generator() {
  local header host_list="$1"

  if [[ -z "$host_list" ]]; then
    host_list="$(_ssh_host_list)"
  fi

  if printf '%s\n' "$host_list" | command awk -F '|' 'NF >= 6 && $5 !~ /^[[:space:]]*$/ { found = 1 } END { exit !found }'; then
    header=$'\nAlias|->|Hostname|User|Tag|Desc\n─────|──|────────|────|───|────\n'
  else
    host_list="$(printf '%s\n' "$host_list" | command awk -F '|' '
      BEGIN { OFS = "|" }
      NF >= 6 { print $1, $2, $3, $4, $6; next }
      { print }
    ')"
    header=$'\nAlias|->|Hostname|User|Desc\n─────|──|────────|────|────\n'
  fi

  printf '%s\n' "${header}${host_list}" | _bash_ssh_columnize
}

_bash_ssh_extract_alias() {
  local row="$1"
  row="$(_bash_ssh_trim "$row")"
  printf '%s\n' "${row%% *}"
}

_bash_complete_ssh() {
  local cur selection key selected_line selected_alias
  local -a args aliases
  local host_list

  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  if [[ "${COMP_WORDS[0]}" != "ssh" ]]; then
    return 0
  fi

  args=("${COMP_WORDS[@]:1}")
  host_list="$(_ssh_host_list "${args[@]}")"
  [[ -n "$host_list" ]] || return 0

  mapfile -t aliases < <(printf '%s\n' "$host_list" | command awk -F '|' 'NF >= 1 && $1 !~ /^[[:space:]]*$/ { print $1 }')

  if ((${#aliases[@]} == 1)); then
    COMPREPLY=("${aliases[0]}")
    compopt -o nospace 2>/dev/null || true
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    selection="$(_fzf_list_generator "$host_list" | fzf \
      --height 40% \
      --ansi \
      --border \
      --cycle \
      --info=inline \
      --header-lines=2 \
      --reverse \
      --prompt='SSH Remote > ' \
      --query="$cur" \
      --bind 'shift-tab:up,tab:down,bspace:backward-delete-char/eof' \
      --preview 'ssh -T -G $(printf "%s" {} | command awk "{print \$1}") | command awk "BEGIN{IGNORECASE=1} /^User |^HostName |^Port |^ControlMaster |^ForwardAgent |^LocalForward |^IdentityFile |^RemoteForward |^ProxyCommand |^ProxyJump /" | (command -v column >/dev/null 2>&1 && column -t || cat)' \
      --preview-window=right:40% \
      --expect=alt-enter,enter
    )"

    if [[ -n "$selection" ]]; then
      key="${selection%%$'\n'*}"
      if [[ "$key" == "$selection" ]]; then
        selected_line="$selection"
        key=''
      else
        selected_line="${selection#*$'\n'}"
      fi

      selected_alias="$(_bash_ssh_extract_alias "$selected_line")"
      if [[ -n "$selected_alias" ]]; then
        COMPREPLY=("$selected_alias")
        compopt -o nospace 2>/dev/null || true
      fi
      return 0
    fi
  fi

  COMPREPLY=( $(compgen -W "${aliases[*]}" -- "$cur") )
}

complete -o default -o bashdefault -F _bash_complete_ssh ssh
