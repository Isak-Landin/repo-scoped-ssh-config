#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-repo-git-key.sh --key /path/to/private_key [--repo /path/to/repo]
  setup-repo-git-key.sh /path/to/private_key

What it does:
  - Installs direnv with apt-get if it is not already installed
  - Finds the target repository root, defaulting to the repo that contains this script
  - Adds or updates a managed .envrc block that sets GIT_SSH_COMMAND
  - Adds .envrc to .git/info/exclude so it stays local to the repo
  - Adds the direnv bash hook to the target user's .bashrc if it is missing
  - Runs direnv allow for the active repo
  - Verifies the repo can load the configured GIT_SSH_COMMAND through direnv

Notes:
  - The key must be the private key file, not the .pub file
  - The repo must already exist as a git repository
  - This script uses Ubuntu's apt-get to install direnv when needed
  - If you are not root, the install step uses sudo and may prompt for your password
  - The script updates .bashrc for future shells; an already-open parent shell may need re-entry into the repo before auto-loading occurs
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "$value" ]] || die "You must pass the SSH private key path as an argument. Example: $0 --key /path/to/private_key"
}

abspath() {
  local path="$1"
  if [[ "$path" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi

  if [[ -d "$path" ]]; then
    (
      cd "$path"
      pwd -P
    )
    return
  fi

  local dir
  dir="$(dirname "$path")"
  local base
  base="$(basename "$path")"

  (
    cd "$dir"
    printf '%s/%s\n' "$(pwd -P)" "$base"
  )
}

strip_managed_block() {
  local file="$1"
  local begin_marker="$2"
  local end_marker="$3"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file"
}

get_target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

get_target_home() {
  local user="$1"
  local home_dir

  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || die "Could not determine home directory for user: $user"
  printf '%s\n' "$home_dir"
}

get_path_owner_spec() {
  local path="$1"
  stat -c '%u:%g' "$path"
}

get_user_owner_spec() {
  local user="$1"
  local uid
  local gid

  uid="$(id -u "$user")"
  gid="$(id -g "$user")"
  printf '%s:%s\n' "$uid" "$gid"
}

ensure_path_owner_and_mode() {
  local path="$1"
  local owner_spec="$2"
  local mode="$3"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown "$owner_spec" "$path"
  fi
  chmod "$mode" "$path"
}

resolve_repo_root() {
  local requested_path="${1-}"
  local candidate
  local repo_root=""
  local -a candidates=()

  if [[ -n "$requested_path" ]]; then
    candidates=("$requested_path")
  else
    candidates=("$script_dir" ".")
  fi

  for candidate in "${candidates[@]}"; do
    if repo_root="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)"; then
      printf '%s\n' "$repo_root"
      return
    fi
  done

  if [[ -n "$requested_path" ]]; then
    die "Not inside a git repository: $requested_path"
  fi

  die "Could not find a git repository from the script directory ($script_dir) or current directory ($(pwd -P)). Pass --repo /path/to/repo explicitly."
}

ensure_direnv_installed() {
  if command -v direnv >/dev/null 2>&1; then
    return
  fi

  command -v apt-get >/dev/null 2>&1 || die "apt-get is required to install direnv automatically"

  printf 'direnv is not installed. Installing with apt-get...\n'

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    apt-get update
    apt-get install -y direnv
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install direnv automatically"
    sudo apt-get update
    sudo apt-get install -y direnv
  fi

  command -v direnv >/dev/null 2>&1 || die "direnv installation did not succeed"
}

ensure_bash_hook() {
  local bashrc_path="$1"
  local hook_line='eval "$(direnv hook bash)"'

  touch "$bashrc_path"
  if ! grep -Fqx "$hook_line" "$bashrc_path"; then
    printf '\n%s\n' "$hook_line" >> "$bashrc_path"
  fi
}

ensure_line_in_file() {
  local file_path="$1"
  local line="$2"

  touch "$file_path"
  if ! grep -Fqx "$line" "$file_path"; then
    printf '%s\n' "$line" >> "$file_path"
  fi
}

verify_direnv_load() {
  local repo_root="$1"
  local expected_ssh_command="$2"
  local loaded_ssh_command

  loaded_ssh_command="$(direnv exec "$repo_root" bash -lc 'printf %s "${GIT_SSH_COMMAND-}"')"
  [[ "$loaded_ssh_command" == "$expected_ssh_command" ]] || die "direnv did not load the expected GIT_SSH_COMMAND for $repo_root"
}

key_path=""
repo_path=""
script_path="$(abspath "${BASH_SOURCE[0]}")"
script_dir="$(dirname "$script_path")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--key)
      require_value "$1" "${2-}"
      key_path="$2"
      shift 2
      ;;
    -r|--repo)
      require_value "$1" "${2-}"
      repo_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$key_path" ]]; then
        key_path="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

[[ -n "$key_path" ]] || {
  die "You must pass the SSH private key path as an argument. Example: $0 --key /path/to/private_key"
}

key_path="$(abspath "$key_path")"
[[ -f "$key_path" ]] || die "SSH key not found: $key_path"
[[ "$key_path" != *.pub ]] || die "Use the private key file, not the .pub file: $key_path"

ensure_direnv_installed

target_user="$(get_target_user)"
target_home="$(get_target_home "$target_user")"
bashrc_path="$target_home/.bashrc"
runtime_cwd="$(pwd -P)"

repo_root="$(resolve_repo_root "$repo_path")"
repo_owner_spec="$(get_path_owner_spec "$repo_root")"
target_user_owner_spec="$(get_user_owner_spec "$target_user")"
envrc_path="$repo_root/.envrc"
exclude_path="$repo_root/.git/info/exclude"
root_gitignore_path="$repo_root/.gitignore"
script_name="$(basename "$script_path")"

begin_marker="# >>> git-ssh-key-direnv >>>"
end_marker="# <<< git-ssh-key-direnv <<<"

printf -v ssh_command_escaped '%q' "ssh -i $key_path -o IdentitiesOnly=yes"

tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

if [[ -f "$envrc_path" ]]; then
  strip_managed_block "$envrc_path" "$begin_marker" "$end_marker" > "$tmp_file"
else
  : > "$tmp_file"
fi

if [[ -s "$tmp_file" ]]; then
  last_char="$(tail -c 1 "$tmp_file" || true)"
  [[ -z "$last_char" ]] || printf '\n' >> "$tmp_file"
  printf '\n' >> "$tmp_file"
fi

{
  printf '%s\n' "$begin_marker"
  printf 'export GIT_SSH_COMMAND=%s\n' "$ssh_command_escaped"
  printf '%s\n' "$end_marker"
} >> "$tmp_file"

mv "$tmp_file" "$envrc_path"
ensure_path_owner_and_mode "$envrc_path" "$repo_owner_spec" 664

ensure_line_in_file "$exclude_path" '.envrc'
ensure_path_owner_and_mode "$exclude_path" "$repo_owner_spec" 664

if [[ "$runtime_cwd" == "$repo_root" && "$script_dir" == "$repo_root" ]]; then
  ensure_line_in_file "$root_gitignore_path" "$script_name"
  ensure_path_owner_and_mode "$root_gitignore_path" "$repo_owner_spec" 664
fi

printf 'Configured repo: %s\n' "$repo_root"
printf 'SSH key: %s\n' "$key_path"
printf 'Updated: %s\n' "$envrc_path"
printf 'Ignored locally via: %s\n' "$exclude_path"
printf 'Bash hook file: %s\n' "$bashrc_path"

ensure_bash_hook "$bashrc_path"
ensure_path_owner_and_mode "$bashrc_path" "$target_user_owner_spec" 644
direnv allow "$repo_root"
verify_direnv_load "$repo_root" "ssh -i $key_path -o IdentitiesOnly=yes"
printf 'direnv status: allowed\n'
if [[ "$runtime_cwd" == "$repo_root" || "$runtime_cwd" == "$repo_root/"* ]]; then
  cd "$runtime_cwd"
else
  cd "$repo_root"
fi
