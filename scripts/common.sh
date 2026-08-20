#!/data/data/com.termux/files/usr/bin/bash
# common.sh — shared helpers for the dsh-termux install scripts.
# Sourced by scripts/00-04. No shebang execution.

# --- Prompt helpers -------------------------------------------------------

# Ask a yes/no question. Default is YES. Returns 0 (yes) or 1 (no).
# Honors DSH_ASSUME_YES=1 (from the -y flag): returns the default without asking.
ask_yes_no() {
  local prompt="$1"
  local default="${2:-yes}"   # yes | no
  if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
    echo "   [auto-yes] ${prompt}"
    [ "$default" = "yes" ]
    return $?
  fi
  local ans
  while :; do
    if [ "$default" = "yes" ]; then
      printf '%s [Y/n]: ' "$prompt"
    else
      printf '%s [y/N]: ' "$prompt"
    fi
    read -r ans
    case "${ans,,}" in
      "" ) [ "$default" = "yes" ]; return $? ;;
      y|yes ) return 0 ;;
      n|no ) return 1 ;;
      * ) echo "   Please answer y or n." ;;
    esac
  done
}

# Ask for a value with a default; validates input with a validator function.
#   ask_input <var_name> <prompt> <default> <validator_func>
# The validator receives the candidate as $1 and returns 0 if valid.
ask_input() {
  local var="$1" prompt="$2" default="$3" validator="$4"
  if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
    printf -v "$var" '%s' "$default"
    echo "   [auto] ${prompt} -> ${default}"
    return 0
  fi
  local val
  while :; do
    printf '%s [%s]: ' "$prompt" "$default"
    read -r val
    val="${val:-$default}"
    if [ -z "$validator" ] || "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    echo "   Invalid input, please try again."
  done
}

# --- Validators -----------------------------------------------------------

# Absolute path, no spaces, no leading '~'.
validate_abs_path() {
  local p="$1"
  [[ "$p" =~ ^/ ]] || { echo "   (must be an absolute path starting with /)"; return 1; }
  [[ "$p" != *" "* ]] || { echo "   (must not contain spaces — grun cannot handle them)"; return 1; }
  return 0
}

# Semantic version X.Y.Z matching dsh engines: ^22.19.0 || >=24.0.0.
validate_node_version() {
  local v="${1#v}"
  if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "   (expected X.Y.Z, e.g. 22.20.0)"
    return 1
  fi
  local major minor
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
    return 0
  fi
  echo "   (dsh requires Node ^22.19.0 || >=24.0.0; you entered ${major}.${minor})"
  return 1
}

# A bare port number 1..65535.
validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}