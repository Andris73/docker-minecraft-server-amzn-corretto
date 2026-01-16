#!/bin/bash

# Git Backup Daemon for Minecraft Server
# Commits server data to a git repository as a backup mechanism

: "${GIT_BACKUP_ENABLED:=false}"
: "${GIT_BACKUP_PATH:=/data}"
: "${GIT_BACKUP_TRIGGERS:=}"
: "${GIT_BACKUP_PERIOD:=0}"
: "${GIT_BACKUP_COMMIT_MSG:=Auto backup - %DATE%}"
: "${GIT_BACKUP_BRANCH:=}"
: "${GIT_BACKUP_ADD_PATHS:=.}"
: "${GIT_BACKUP_EXCLUDE_PATHS:=}"
: "${GIT_BACKUP_AUTHOR_NAME:=Minecraft Server}"
: "${GIT_BACKUP_AUTHOR_EMAIL:=minecraft@server.local}"
: "${GIT_BACKUP_LFS_ENABLED:=false}"
: "${GIT_BACKUP_LFS_PATTERNS:=*.mca,*.jar,*.zip,*.dat,*.dat_old,*.nbt}"
: "${GIT_BACKUP_PUSH_ENABLED:=false}"
: "${GIT_BACKUP_REMOTE:=}"
: "${GIT_BACKUP_REMOTE_NAME:=origin}"
: "${GIT_BACKUP_INIT_MODE:=}"
: "${GIT_BACKUP_RESTORE_ENABLED:=false}"
: "${GIT_BACKUP_RESTORE_TARGET:=}"
: "${GIT_BACKUP_GITIGNORE_ENABLED:=true}"
: "${GIT_BACKUP_GITIGNORE_PATTERNS:=logs/,crash-reports/,cache/,bluemap/,libraries/,plugins/spark/}"
: "${GIT_BACKUP_SSH_KEYGEN:=true}"
: "${GIT_BACKUP_SSH_KEY_PATH:=${GIT_BACKUP_PATH}/.ssh}"

# shellcheck source=../auto/autopause-fcns.sh
. /image/scripts/auto/autopause-fcns.sh

# shellcheck source=start-utils
. /image/scripts/start-utils

logGitBackup() {
  echo "[Git Backup] $*"
}

logGitBackupAction() {
  echo "[$(date -Iseconds)] [Git Backup] $*"
}

# Check if a trigger is enabled in GIT_BACKUP_TRIGGERS
is_trigger_enabled() {
  local trigger="$1"
  local triggers_list="${GIT_BACKUP_TRIGGERS}"

  if [[ -z "$triggers_list" ]]; then
    return 1
  fi

  IFS=',' read -ra triggers_array <<< "$triggers_list"
  for t in "${triggers_array[@]}"; do
    t=$(echo "$t" | xargs)
    if [[ "${t,,}" == "${trigger,,}" ]]; then
      return 0
    fi
  done
  return 1
}

check_git_installed() {
  if ! command -v git &> /dev/null; then
    logGitBackup "ERROR: git is not installed"
    return 1
  fi
  return 0
}

check_git_lfs_installed() {
  if ! command -v git-lfs &> /dev/null; then
    logGitBackup "ERROR: git-lfs is not installed but GIT_BACKUP_LFS_ENABLED is true"
    return 1
  fi
  return 0
}

# Check if a remote URL uses SSH (git@ or ssh://)
is_ssh_remote() {
  local url="$1"
  if [[ -z "$url" ]]; then
    return 1
  fi
  if [[ "$url" =~ ^git@ ]] || [[ "$url" =~ ^ssh:// ]]; then
    return 0
  fi
  return 1
}

# Extract hostname from SSH remote URL
get_ssh_hostname() {
  local url="$1"
  local hostname=""
  
  if [[ "$url" =~ ^git@([^:]+): ]]; then
    hostname="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^ssh://([^@]+@)?([^:/]+) ]]; then
    hostname="${BASH_REMATCH[2]}"
  fi
  
  echo "$hostname"
}

# Setup SSH keys for Git operations
setup_ssh_keys() {
  if ! isTrue "${GIT_BACKUP_SSH_KEYGEN}"; then
    return 0
  fi

  if ! is_ssh_remote "${GIT_BACKUP_REMOTE}"; then
    return 0
  fi

  logGitBackup "Setting up SSH keys for Git operations..."

  local ssh_dir="${GIT_BACKUP_SSH_KEY_PATH}"
  local key_file="${ssh_dir}/id_ed25519"
  local pub_key_file="${key_file}.pub"
  local ssh_config="${ssh_dir}/config"
  local known_hosts="${ssh_dir}/known_hosts"
  local key_generated=false

  # Create SSH directory
  if [[ ! -d "${ssh_dir}" ]]; then
    logGitBackup "Creating SSH directory: ${ssh_dir}"
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
  fi

  # Generate SSH key if it doesn't exist
  if [[ ! -f "${key_file}" ]]; then
    logGitBackup "Generating new SSH key pair..."
    if ! ssh-keygen -t ed25519 -f "${key_file}" -N "" -C "minecraft-server-backup" 2>&1; then
      logGitBackup "ERROR: Failed to generate SSH key"
      return 1
    fi
    chmod 600 "${key_file}"
    chmod 644 "${pub_key_file}"
    key_generated=true
    logGitBackup "SSH key pair generated successfully"
  else
    logGitBackup "Using existing SSH key: ${key_file}"
  fi

  # Extract hostname from remote URL
  local hostname
  hostname=$(get_ssh_hostname "${GIT_BACKUP_REMOTE}")

  # Create SSH config to use our key
  logGitBackup "Configuring SSH for ${hostname:-git hosts}..."
  cat > "${ssh_config}" << EOF
# Auto-generated SSH config for Git Backup
# Key path: ${key_file}

Host *
    IdentityFile ${key_file}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ${known_hosts}
EOF
  chmod 600 "${ssh_config}"

  # Pre-populate known_hosts with common Git hosts
  if [[ ! -f "${known_hosts}" ]] || [[ ! -s "${known_hosts}" ]]; then
    logGitBackup "Fetching SSH host keys for known Git providers..."
    {
      ssh-keyscan -t ed25519,rsa github.com 2>/dev/null
      ssh-keyscan -t ed25519,rsa gitlab.com 2>/dev/null
      ssh-keyscan -t ed25519,rsa bitbucket.org 2>/dev/null
    } > "${known_hosts}" 2>/dev/null
    
    if [[ -n "$hostname" ]] && [[ "$hostname" != "github.com" ]] && [[ "$hostname" != "gitlab.com" ]] && [[ "$hostname" != "bitbucket.org" ]]; then
      logGitBackup "Fetching SSH host key for: ${hostname}"
      ssh-keyscan -t ed25519,rsa "${hostname}" >> "${known_hosts}" 2>/dev/null || true
    fi
  fi

  # Set GIT_SSH_COMMAND to use our config
  export GIT_SSH_COMMAND="ssh -F ${ssh_config}"
  logGitBackup "SSH configured with GIT_SSH_COMMAND"

  # Output the public key for the user
  logGitBackup "============================================================"
  logGitBackup "SSH PUBLIC KEY - Add this as a Deploy Key to your repository"
  logGitBackup "============================================================"
  if [[ -f "${pub_key_file}" ]]; then
    logGitBackup ""
    cat "${pub_key_file}" | while IFS= read -r line; do
      logGitBackup "  ${line}"
    done
    logGitBackup ""
  fi
  logGitBackup "============================================================"
  
  if [[ "$key_generated" == "true" ]]; then
    logGitBackup "NOTE: This is a NEW key. You must add it to your Git provider!"
    logGitBackup ""
    logGitBackup "For GitHub:"
    logGitBackup "  1. Go to your repository -> Settings -> Deploy keys"
    logGitBackup "  2. Click 'Add deploy key'"
    logGitBackup "  3. Paste the public key above"
    logGitBackup "  4. Check 'Allow write access' for push support"
    logGitBackup "  5. Click 'Add key'"
    logGitBackup ""
    logGitBackup "For GitLab:"
    logGitBackup "  1. Go to your repository -> Settings -> Repository -> Deploy keys"
    logGitBackup "  2. Add the key with write access enabled"
    logGitBackup ""
  fi
  logGitBackup "Key location: ${pub_key_file}"
  logGitBackup "============================================================"

  return 0
}

configure_git_safe_directory() {
  logGitBackup "Configuring git safe.directory for ${GIT_BACKUP_PATH}"
  git config --global --add safe.directory "${GIT_BACKUP_PATH}" 2>/dev/null || true
}

generate_gitignore_content() {
  cat << 'EOF'
# Git Backup - Auto-generated .gitignore
# Managed by GIT_BACKUP_GITIGNORE_PATTERNS environment variable
# Changes to this file will be overwritten when the env var changes

EOF

  local patterns
  IFS=',' read -ra patterns <<< "${GIT_BACKUP_GITIGNORE_PATTERNS}"
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    if [[ -n "$pattern" ]]; then
      echo "${pattern}"
    fi
  done
}

setup_gitignore() {
  local skip_push="${1:-false}"

  if ! isTrue "${GIT_BACKUP_GITIGNORE_ENABLED}"; then
    return 0
  fi

  if [[ -z "${GIT_BACKUP_GITIGNORE_PATTERNS}" ]]; then
    logGitBackup "No gitignore patterns configured"
    return 0
  fi

  cd "${GIT_BACKUP_PATH}" || return 1

  local gitignore_file="${GIT_BACKUP_PATH}/.gitignore"
  local expected_content
  local current_content=""

  expected_content=$(generate_gitignore_content)

  if [[ -f "${gitignore_file}" ]]; then
    current_content=$(cat "${gitignore_file}")
  fi

  if [[ "${expected_content}" == "${current_content}" ]]; then
    logGitBackup ".gitignore is up to date"
    return 0
  fi

  if [[ -f "${gitignore_file}" ]]; then
    logGitBackup ".gitignore patterns changed, updating file..."
  else
    logGitBackup "Creating .gitignore file..."
  fi

  echo "${expected_content}" > "${gitignore_file}"

  local patterns
  IFS=',' read -ra patterns <<< "${GIT_BACKUP_GITIGNORE_PATTERNS}"
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    if [[ -n "$pattern" ]]; then
      logGitBackup "  Pattern: ${pattern}"
    fi
  done

  logGitBackup "Removing newly-ignored files from git tracking..."
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    if [[ -n "$pattern" ]]; then
      if git rm -r --cached --ignore-unmatch "${pattern}" 2>/dev/null; then
        if ! git diff --cached --quiet -- "${pattern}" 2>/dev/null; then
          logGitBackup "  Untracked: ${pattern}"
        fi
      fi
    fi
  done

  git add .gitignore

  if ! git diff --cached --quiet 2>/dev/null; then
    git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
    git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

    local commit_msg="Update .gitignore patterns - $(date -Iseconds)"
    if git commit -m "${commit_msg}"; then
      logGitBackupAction ".gitignore committed successfully"
      if [[ "${skip_push}" != "true" ]]; then
        run_git_push
      fi
    else
      logGitBackup "WARNING: Failed to commit .gitignore changes"
    fi
  else
    logGitBackup ".gitignore updated (no tracked files affected)"
  fi

  logGitBackup ".gitignore setup complete"
  return 0
}

# Initialize a fresh git repository (INIT_MODE=init)
init_git_repo() {
  logGitBackup "Initializing fresh git repository in ${GIT_BACKUP_PATH}"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackup "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  if ! git init 2>&1; then
    logGitBackup "ERROR: Failed to initialize git repository"
    return 1
  fi

  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  setup_gitignore true

  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    if command -v git-lfs &> /dev/null; then
      logGitBackup "Initializing Git LFS..."
      git lfs install --local 2>&1 || logGitBackup "WARNING: Failed to initialize LFS"
    fi
  fi

  logGitBackup "Git repository initialized successfully"
  return 0
}

# Clone from remote repository (INIT_MODE=clone)
clone_from_remote() {
  if [[ -z "${GIT_BACKUP_REMOTE}" ]]; then
    logGitBackup "ERROR: GIT_BACKUP_INIT_MODE=clone requires GIT_BACKUP_REMOTE to be set"
    return 1
  fi

  logGitBackup "Cloning from remote repository: ${GIT_BACKUP_REMOTE}"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackup "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  logGitBackup "Initializing git repository..."
  if ! git init 2>&1; then
    logGitBackup "ERROR: Failed to initialize git repository"
    return 1
  fi

  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  logGitBackup "Adding remote '${GIT_BACKUP_REMOTE_NAME}': ${GIT_BACKUP_REMOTE}"
  if ! git remote add "${GIT_BACKUP_REMOTE_NAME}" "${GIT_BACKUP_REMOTE}" 2>&1; then
    logGitBackup "ERROR: Failed to add remote"
    return 1
  fi

  GIT_BACKUP_PUSH_ENABLED="true"

  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    if command -v git-lfs &> /dev/null; then
      logGitBackup "Initializing Git LFS..."
      git lfs install --local 2>&1 || logGitBackup "WARNING: Failed to initialize LFS"
    fi
  fi

  logGitBackupAction "Fetching from remote..."
  local fetch_output
  local fetch_exit_code
  fetch_output=$(git fetch "${GIT_BACKUP_REMOTE_NAME}" 2>&1)
  fetch_exit_code=$?

  if [[ $fetch_exit_code -ne 0 ]]; then
    logGitBackupAction "Fetch FAILED (exit code: ${fetch_exit_code})"
    if [[ -n "$fetch_output" ]]; then
      logGitBackup "  Error details: ${fetch_output}"
    fi
    return 1
  fi
  logGitBackupAction "Fetch succeeded"

  local branch_to_checkout="${GIT_BACKUP_BRANCH}"
  if [[ -z "${branch_to_checkout}" ]]; then
    branch_to_checkout=$(git remote show "${GIT_BACKUP_REMOTE_NAME}" 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
    if [[ -z "${branch_to_checkout}" ]]; then
      if git rev-parse --verify "${GIT_BACKUP_REMOTE_NAME}/main" &>/dev/null; then
        branch_to_checkout="main"
      elif git rev-parse --verify "${GIT_BACKUP_REMOTE_NAME}/master" &>/dev/null; then
        branch_to_checkout="master"
      else
        logGitBackup "ERROR: Could not determine branch to checkout"
        logGitBackup "Hint: Set GIT_BACKUP_BRANCH to specify the branch"
        return 1
      fi
    fi
  fi

  logGitBackup "Checking out branch: ${branch_to_checkout}"

  if ! git checkout -b "${branch_to_checkout}" "${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" --force 2>&1; then
    logGitBackup "Standard checkout failed, trying reset approach..."
    git branch "${branch_to_checkout}" "${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" 2>/dev/null || true
    git checkout "${branch_to_checkout}" 2>/dev/null || true
  fi

  logGitBackup "Resetting working directory to match remote..."
  if ! git reset --hard "${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" 2>&1; then
    logGitBackup "ERROR: Failed to reset to remote branch ${branch_to_checkout}"
    return 1
  fi

  if [[ -n "${GIT_BACKUP_RESTORE_TARGET}" ]] && isTrue "${GIT_BACKUP_RESTORE_ENABLED}"; then
    restore_to_target
  fi

  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    logGitBackup "Pulling LFS files..."
    if git lfs pull 2>&1; then
      logGitBackupAction "LFS pull succeeded"
    else
      logGitBackup "WARNING: LFS pull failed (some large files may be missing)"
    fi
  fi

  git branch --set-upstream-to="${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" "${branch_to_checkout}" 2>/dev/null

  local commit_hash
  local commit_date
  local commit_msg
  commit_hash=$(git rev-parse --short HEAD 2>/dev/null)
  commit_date=$(git show -s --format="%ci" HEAD 2>/dev/null)
  commit_msg=$(git show -s --format="%s" HEAD 2>/dev/null)

  logGitBackupAction "Clone from remote completed successfully"
  logGitBackup "  Branch:  ${branch_to_checkout}"
  logGitBackup "  Commit:  ${commit_hash}"
  logGitBackup "  Date:    ${commit_date}"
  logGitBackup "  Message: ${commit_msg}"

  setup_gitignore true

  return 0
}

# Restore to a specific commit target
restore_to_target() {
  local target="${GIT_BACKUP_RESTORE_TARGET}"

  if [[ -z "$target" ]]; then
    return 0
  fi

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackup "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  logGitBackup "Restoring to target: ${target}"

  if ! git cat-file -e "${target}^{commit}" 2>/dev/null; then
    logGitBackup "ERROR: Target '${target}' not found"
    logGitBackup "Use 'git log --oneline' to see available commits"
    return 1
  fi

  local target_hash
  local target_date
  local target_msg
  target_hash=$(git rev-parse "${target}" 2>/dev/null)
  target_date=$(git show -s --format="%ci" "${target}" 2>/dev/null)
  target_msg=$(git show -s --format="%s" "${target}" 2>/dev/null)

  logGitBackup "Restoring to:"
  logGitBackup "  Commit:  ${target_hash}"
  logGitBackup "  Date:    ${target_date}"
  logGitBackup "  Message: ${target_msg}"

  if ! git reset --hard "${target}" 2>&1; then
    logGitBackup "ERROR: Failed to restore to target ${target}"
    return 1
  fi

  if isTrue "${GIT_BACKUP_LFS_ENABLED}" && [[ -f ".gitattributes" ]]; then
    logGitBackup "Pulling LFS files..."
    git lfs pull 2>/dev/null || logGitBackup "WARNING: LFS pull failed"
  fi

  logGitBackupAction "Restore to target completed successfully"
  logGitBackup "  Current HEAD: $(git rev-parse --short HEAD)"
  return 0
}

# Handle repository initialization based on INIT_MODE
handle_repo_init() {
  if [[ -d "${GIT_BACKUP_PATH}/.git" ]]; then
    return 0
  fi

  case "${GIT_BACKUP_INIT_MODE,,}" in
    init)
      init_git_repo
      return $?
      ;;
    clone)
      clone_from_remote
      return $?
      ;;
    "")
      logGitBackup "ERROR: ${GIT_BACKUP_PATH} is not a git repository"
      logGitBackup "Hint: Set GIT_BACKUP_INIT_MODE=init to create a fresh repo"
      logGitBackup "Hint: Set GIT_BACKUP_INIT_MODE=clone with GIT_BACKUP_REMOTE to clone from remote"
      return 1
      ;;
    *)
      logGitBackup "ERROR: Unknown GIT_BACKUP_INIT_MODE: ${GIT_BACKUP_INIT_MODE}"
      logGitBackup "Valid values: init, clone"
      return 1
      ;;
  esac
}

# Handle restore on boot (if enabled and repo exists)
handle_restore_on_boot() {
  if ! isTrue "${GIT_BACKUP_RESTORE_ENABLED}"; then
    return 0
  fi

  if [[ -z "${GIT_BACKUP_RESTORE_TARGET}" ]]; then
    logGitBackup "Restore enabled but no GIT_BACKUP_RESTORE_TARGET specified, skipping"
    return 0
  fi

  if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
    logGitBackup "Cannot restore: no git repository exists"
    return 1
  fi

  logGitBackupAction "Restore on boot enabled, restoring to: ${GIT_BACKUP_RESTORE_TARGET}"
  restore_to_target
  return $?
}

setup_git_lfs() {
  if ! isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    return 0
  fi

  logGitBackup "Setting up Git LFS..."

  cd "${GIT_BACKUP_PATH}" || return 1

  if ! git lfs install --local 2>/dev/null; then
    logGitBackup "ERROR: Failed to initialize git-lfs"
    return 1
  fi

  local lfs_patterns
  IFS=',' read -ra lfs_patterns <<< "${GIT_BACKUP_LFS_PATTERNS}"
  for pattern in "${lfs_patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    if [[ -n "$pattern" ]]; then
      logGitBackup "LFS tracking pattern: ${pattern}"
      git lfs track "${pattern}" 2>/dev/null || logGitBackup "WARNING: Failed to track ${pattern}"
    fi
  done

  if [[ -f ".gitattributes" ]]; then
    git add .gitattributes 2>/dev/null
  fi

  logGitBackup "Git LFS setup complete"
  return 0
}

setup_git_remote() {
  if ! isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
    return 0
  fi

  if [[ -z "${GIT_BACKUP_REMOTE}" ]]; then
    logGitBackup "ERROR: GIT_BACKUP_PUSH_ENABLED is true but GIT_BACKUP_REMOTE is not set"
    return 1
  fi

  logGitBackup "Setting up Git remote..."

  cd "${GIT_BACKUP_PATH}" || return 1

  local existing_remote
  existing_remote=$(git remote get-url "${GIT_BACKUP_REMOTE_NAME}" 2>/dev/null)

  if [[ -n "${existing_remote}" ]]; then
    if [[ "${existing_remote}" != "${GIT_BACKUP_REMOTE}" ]]; then
      logGitBackup "Updating remote '${GIT_BACKUP_REMOTE_NAME}' URL to: ${GIT_BACKUP_REMOTE}"
      git remote set-url "${GIT_BACKUP_REMOTE_NAME}" "${GIT_BACKUP_REMOTE}" || {
        logGitBackup "ERROR: Failed to update remote URL"
        return 1
      }
    else
      logGitBackup "Remote '${GIT_BACKUP_REMOTE_NAME}' already configured correctly"
    fi
  else
    logGitBackup "Adding remote '${GIT_BACKUP_REMOTE_NAME}': ${GIT_BACKUP_REMOTE}"
    git remote add "${GIT_BACKUP_REMOTE_NAME}" "${GIT_BACKUP_REMOTE}" || {
      logGitBackup "ERROR: Failed to add remote"
      return 1
    }
  fi

  logGitBackup "Git remote setup complete"
  return 0
}

# Sync local branch with remote (fetch and merge)
sync_with_remote() {
  if ! isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
    return 0
  fi

  cd "${GIT_BACKUP_PATH}" || return 1

  local current_branch
  if [[ -n "${GIT_BACKUP_BRANCH}" ]]; then
    current_branch="${GIT_BACKUP_BRANCH}"
  else
    current_branch=$(git branch --show-current 2>/dev/null)
  fi

  if [[ -z "${current_branch}" ]]; then
    logGitBackup "No current branch, skipping remote sync"
    return 0
  fi

  logGitBackupAction "Fetching from remote '${GIT_BACKUP_REMOTE_NAME}'..."
  local fetch_output
  fetch_output=$(git fetch "${GIT_BACKUP_REMOTE_NAME}" 2>&1)
  local fetch_exit_code=$?

  if [[ $fetch_exit_code -ne 0 ]]; then
    logGitBackup "Fetch failed (exit code: ${fetch_exit_code})"
    if [[ -n "$fetch_output" ]]; then
      logGitBackup "  Details: ${fetch_output}"
    fi
    logGitBackup "Continuing without sync (remote may not exist yet)"
    return 0
  fi

  # Check if remote branch exists
  if ! git rev-parse --verify "${GIT_BACKUP_REMOTE_NAME}/${current_branch}" &>/dev/null; then
    logGitBackup "Remote branch '${current_branch}' doesn't exist yet, will be created on first push"
    return 0
  fi

  # Check if we have any local commits
  local local_commits
  local_commits=$(git rev-list HEAD 2>/dev/null | wc -l)

  if [[ "$local_commits" -eq 0 ]]; then
    # No local commits, just reset to remote
    logGitBackup "No local commits, resetting to remote branch..."
    if git reset --hard "${GIT_BACKUP_REMOTE_NAME}/${current_branch}" 2>&1; then
      logGitBackupAction "Reset to remote branch successful"
    else
      logGitBackup "WARNING: Failed to reset to remote branch"
    fi
    return 0
  fi

  # Check if local branch is behind remote
  local behind_count
  behind_count=$(git rev-list --count "HEAD..${GIT_BACKUP_REMOTE_NAME}/${current_branch}" 2>/dev/null || echo "0")

  if [[ "$behind_count" -gt 0 ]]; then
    logGitBackup "Local branch is ${behind_count} commit(s) behind remote, merging..."
    
    # Configure merge settings
    git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
    git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

    # Try to merge remote changes (allow unrelated histories for fresh repos)
    local merge_output
    merge_output=$(git merge "${GIT_BACKUP_REMOTE_NAME}/${current_branch}" --allow-unrelated-histories -m "Merge remote changes" 2>&1)
    local merge_exit_code=$?

    if [[ $merge_exit_code -eq 0 ]]; then
      logGitBackupAction "Merged remote changes successfully"
    else
      logGitBackup "Merge failed, trying rebase..."
      # Abort failed merge
      git merge --abort 2>/dev/null || true
      
      # Try rebase instead
      local rebase_output
      rebase_output=$(git rebase "${GIT_BACKUP_REMOTE_NAME}/${current_branch}" 2>&1)
      local rebase_exit_code=$?

      if [[ $rebase_exit_code -eq 0 ]]; then
        logGitBackupAction "Rebased on remote changes successfully"
      else
        logGitBackup "WARNING: Could not sync with remote, will force push if needed"
        git rebase --abort 2>/dev/null || true
        # Set flag to force push later if needed
        export GIT_BACKUP_FORCE_PUSH="true"
      fi
    fi
  else
    logGitBackup "Local branch is up to date with remote"
  fi

  # Set up tracking
  git branch --set-upstream-to="${GIT_BACKUP_REMOTE_NAME}/${current_branch}" "${current_branch}" 2>/dev/null || true

  return 0
}

run_git_push() {
  if ! isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
    return 0
  fi

  logGitBackupAction "Pushing to remote '${GIT_BACKUP_REMOTE_NAME}'..."

  cd "${GIT_BACKUP_PATH}" || return 1

  local branch_to_push
  if [[ -n "${GIT_BACKUP_BRANCH}" ]]; then
    branch_to_push="${GIT_BACKUP_BRANCH}"
  else
    branch_to_push=$(git branch --show-current 2>/dev/null)
  fi

  if [[ -z "${branch_to_push}" ]]; then
    logGitBackup "ERROR: Could not determine branch to push"
    return 1
  fi

  # Use -u to set upstream tracking on first push
  local push_output
  local push_exit_code
  push_output=$(git push -u "${GIT_BACKUP_REMOTE_NAME}" "${branch_to_push}" 2>&1)
  push_exit_code=$?

  if [[ $push_exit_code -eq 0 ]]; then
    logGitBackupAction "Push to '${GIT_BACKUP_REMOTE_NAME}/${branch_to_push}' succeeded"
    if [[ -n "$push_output" ]] && [[ "$push_output" != "Everything up-to-date" ]]; then
      logGitBackup "  Push output: ${push_output}"
    fi
    # Clear force push flag on success
    unset GIT_BACKUP_FORCE_PUSH
    return 0
  fi

  # Check if push was rejected due to non-fast-forward (remote has changes we don't have)
  if [[ "$push_output" == *"fetch first"* ]] || [[ "$push_output" == *"non-fast-forward"* ]]; then
    logGitBackup "Push rejected: remote has changes not present locally"
    
    # Try to pull and merge first
    logGitBackup "Attempting to pull and merge remote changes..."
    local pull_output
    pull_output=$(git pull --rebase "${GIT_BACKUP_REMOTE_NAME}" "${branch_to_push}" 2>&1)
    local pull_exit_code=$?

    if [[ $pull_exit_code -eq 0 ]]; then
      logGitBackup "Pull successful, retrying push..."
      push_output=$(git push -u "${GIT_BACKUP_REMOTE_NAME}" "${branch_to_push}" 2>&1)
      push_exit_code=$?

      if [[ $push_exit_code -eq 0 ]]; then
        logGitBackupAction "Push to '${GIT_BACKUP_REMOTE_NAME}/${branch_to_push}' succeeded after pull"
        unset GIT_BACKUP_FORCE_PUSH
        return 0
      fi
    else
      logGitBackup "Pull failed: ${pull_output}"
      git rebase --abort 2>/dev/null || true
    fi

    # If force push is allowed (sync failed earlier), use it as last resort
    if isTrue "${GIT_BACKUP_FORCE_PUSH:-false}"; then
      logGitBackup "WARNING: Using force push as fallback..."
      push_output=$(git push --force-with-lease -u "${GIT_BACKUP_REMOTE_NAME}" "${branch_to_push}" 2>&1)
      push_exit_code=$?

      if [[ $push_exit_code -eq 0 ]]; then
        logGitBackupAction "Force push to '${GIT_BACKUP_REMOTE_NAME}/${branch_to_push}' succeeded"
        unset GIT_BACKUP_FORCE_PUSH
        return 0
      fi
    fi
  fi

  logGitBackupAction "Push to '${GIT_BACKUP_REMOTE_NAME}/${branch_to_push}' FAILED (exit code: ${push_exit_code})"
  if [[ -n "$push_output" ]]; then
    logGitBackup "  Error details: ${push_output}"
  fi
  return 1
}

check_git_repo() {
  if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
    handle_repo_init
    return $?
  fi
  return 0
}

has_changes() {
  cd "${GIT_BACKUP_PATH}" || return 1
  if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    return 0
  fi
  return 1
}

run_git_backup() {
  local reason="$1"

  logGitBackupAction "Starting backup (trigger: ${reason})"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackup "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  if [[ -n "${GIT_BACKUP_BRANCH}" ]]; then
    current_branch=$(git branch --show-current 2>/dev/null)
    if [[ "${current_branch}" != "${GIT_BACKUP_BRANCH}" ]]; then
      logGitBackup "Switching to branch: ${GIT_BACKUP_BRANCH}"
      if ! git checkout "${GIT_BACKUP_BRANCH}" 2>/dev/null; then
        logGitBackup "Branch doesn't exist, creating: ${GIT_BACKUP_BRANCH}"
        git checkout -b "${GIT_BACKUP_BRANCH}" || {
          logGitBackup "ERROR: Failed to create branch ${GIT_BACKUP_BRANCH}"
          return 1
        }
      fi
    fi
  fi

  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  local add_paths
  IFS=',' read -ra add_paths <<< "${GIT_BACKUP_ADD_PATHS}"
  for path in "${add_paths[@]}"; do
    path=$(echo "$path" | xargs)
    if [[ -n "$path" ]]; then
      logGitBackup "Adding path: ${path}"
      if ! git add -A "${path}" 2>&1; then
        logGitBackup "WARNING: Failed to add ${path}"
      fi
    fi
  done

  if [[ -n "${GIT_BACKUP_EXCLUDE_PATHS}" ]]; then
    local exclude_paths
    IFS=',' read -ra exclude_paths <<< "${GIT_BACKUP_EXCLUDE_PATHS}"
    for path in "${exclude_paths[@]}"; do
      path=$(echo "$path" | xargs)
      if [[ -n "$path" ]]; then
        logGitBackup "Excluding path: ${path}"
        git reset HEAD -- "${path}" >/dev/null 2>&1 || true
      fi
    done
  fi

  if ! git diff --cached --quiet 2>/dev/null; then
    local commit_msg="${GIT_BACKUP_COMMIT_MSG}"
    commit_msg="${commit_msg//%DATE%/$(date -Iseconds)}"
    commit_msg="${commit_msg//%REASON%/${reason}}"

    logGitBackup "Committing changes: ${commit_msg}"
    if git commit -m "${commit_msg}"; then
      logGitBackupAction "Backup committed successfully"
      run_git_push
      return 0
    else
      logGitBackup "ERROR: Failed to commit changes"
      return 1
    fi
  else
    logGitBackup "No staged changes to commit"
    return 0
  fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if ! isTrue "${GIT_BACKUP_ENABLED}"; then
  logGitBackup "Git backup is disabled, exiting"
  exit 0
fi

if ! check_git_installed; then
  exit 1
fi

# Check if initialization was already done by git-backup-init.sh
# This happens when clone/restore runs blocking before the daemon starts
if isTrue "${GIT_BACKUP_INIT_COMPLETE:-false}"; then
  logGitBackup "Initialization already completed by git-backup-init.sh"
else
  # Setup SSH keys before any git operations (if using SSH remote)
  if is_ssh_remote "${GIT_BACKUP_REMOTE}"; then
    if ! setup_ssh_keys; then
      logGitBackup "WARNING: SSH key setup failed, remote operations may fail"
    fi
  fi

  configure_git_safe_directory

  if ! check_git_repo; then
    logGitBackup "Hint: Initialize a git repo with 'git init ${GIT_BACKUP_PATH}'"
    exit 1
  fi

  if isTrue "${GIT_BACKUP_RESTORE_ENABLED}"; then
    if ! handle_restore_on_boot; then
      logGitBackup "ERROR: Restore on boot failed, continuing with current state"
    fi
  fi
fi

# Always configure safe directory (in case daemon restarts)
configure_git_safe_directory

# Verify repo exists (might have been created by init script)
if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
  logGitBackup "ERROR: No git repository found at ${GIT_BACKUP_PATH}"
  logGitBackup "Hint: Set GIT_BACKUP_INIT_MODE=clone or GIT_BACKUP_INIT_MODE=init"
  exit 1
fi

if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
  if ! check_git_lfs_installed; then
    exit 1
  fi
fi

logGitBackup "Git backup daemon starting"
logGitBackup "  Backup path: ${GIT_BACKUP_PATH}"
logGitBackup "  Init mode: ${GIT_BACKUP_INIT_MODE:-none}"
logGitBackup "  Restore enabled: ${GIT_BACKUP_RESTORE_ENABLED}"
if isTrue "${GIT_BACKUP_RESTORE_ENABLED}"; then
  logGitBackup "  Restore target: ${GIT_BACKUP_RESTORE_TARGET:-latest}"
fi
logGitBackup "  Triggers: ${GIT_BACKUP_TRIGGERS:-none}"
logGitBackup "  Period: ${GIT_BACKUP_PERIOD}s (0=disabled)"
logGitBackup "  LFS enabled: ${GIT_BACKUP_LFS_ENABLED}"
if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
  logGitBackup "  LFS patterns: ${GIT_BACKUP_LFS_PATTERNS}"
fi
logGitBackup "  Gitignore enabled: ${GIT_BACKUP_GITIGNORE_ENABLED}"
if isTrue "${GIT_BACKUP_GITIGNORE_ENABLED}"; then
  logGitBackup "  Gitignore patterns: ${GIT_BACKUP_GITIGNORE_PATTERNS}"
fi
logGitBackup "  Push enabled: ${GIT_BACKUP_PUSH_ENABLED}"
if isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
  logGitBackup "  Remote name: ${GIT_BACKUP_REMOTE_NAME}"
  logGitBackup "  Remote URL: ${GIT_BACKUP_REMOTE}"
  if is_ssh_remote "${GIT_BACKUP_REMOTE}"; then
    logGitBackup "  SSH key path: ${GIT_BACKUP_SSH_KEY_PATH}"
  fi
fi

# Setup remote first (so gitignore commits can be pushed)
if isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
  if ! setup_git_remote; then
    logGitBackup "ERROR: Failed to setup Git remote"
    exit 1
  fi
  # Sync with remote to avoid push rejections
  sync_with_remote
fi

# Setup .gitignore if enabled (will commit and push if patterns changed)
if isTrue "${GIT_BACKUP_GITIGNORE_ENABLED}"; then
  setup_gitignore
fi

# Setup LFS if enabled
if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
  if ! setup_git_lfs; then
    logGitBackup "ERROR: Failed to setup Git LFS"
    exit 1
  fi
fi

# Wait for java process to be started
while :
do
  if java_process_exists; then
    break
  fi
  sleep 0.1
done

CLIENTCONNECTIONS=0
STATE=INIT
LAST_BACKUP_TIME=0
FIRST_JOIN_DONE=false

while :
do
  CURRENT_TIME=$(current_uptime)

  case X$STATE in
  XINIT)
    if mc_server_listening ; then
      logGitBackup "Minecraft server is listening"

      if is_trigger_enabled "startup"; then
        run_git_backup "startup"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi

      if [[ -z "${GIT_BACKUP_TRIGGERS}" ]] && [[ "${GIT_BACKUP_PERIOD}" -eq 0 ]]; then
        logGitBackup "No backup triggers configured, stopping daemon"
        exit 0
      fi

      STATE=RUNNING
    fi
    ;;
  XRUNNING)
    CURR_CLIENTCONNECTIONS=$(java_clients_connections)

    if [[ "${GIT_BACKUP_PERIOD}" -gt 0 ]]; then
      TIME_SINCE_BACKUP=$((CURRENT_TIME - LAST_BACKUP_TIME))
      if [[ $TIME_SINCE_BACKUP -ge ${GIT_BACKUP_PERIOD} ]]; then
        if has_changes; then
          run_git_backup "periodic"
          LAST_BACKUP_TIME=$CURRENT_TIME
        else
          logGitBackup "Periodic check: no changes detected"
          LAST_BACKUP_TIME=$CURRENT_TIME
        fi
      fi
    fi

    if is_trigger_enabled "first_join"; then
      if (( CURR_CLIENTCONNECTIONS > 0 )) && [[ "$FIRST_JOIN_DONE" == "false" ]]; then
        logGitBackupAction "First player joined, running backup"
        run_git_backup "first_join"
        LAST_BACKUP_TIME=$CURRENT_TIME
        FIRST_JOIN_DONE=true
      fi
      if (( CURR_CLIENTCONNECTIONS == 0 )); then
        FIRST_JOIN_DONE=false
      fi
    fi

    if is_trigger_enabled "on_connect"; then
      if (( CURR_CLIENTCONNECTIONS > CLIENTCONNECTIONS )); then
        logGitBackupAction "Player connected, running backup"
        run_git_backup "on_connect"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi
    fi

    if is_trigger_enabled "on_disconnect"; then
      if (( CURR_CLIENTCONNECTIONS < CLIENTCONNECTIONS )) && (( CLIENTCONNECTIONS > 0 )); then
        logGitBackupAction "Player disconnected, running backup"
        run_git_backup "on_disconnect"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi
    fi

    if is_trigger_enabled "last_disconnect"; then
      if (( CURR_CLIENTCONNECTIONS == 0 )) && (( CLIENTCONNECTIONS > 0 )); then
        logGitBackupAction "All players disconnected, running backup"
        run_git_backup "last_disconnect"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi
    fi

    CLIENTCONNECTIONS=$CURR_CLIENTCONNECTIONS
    ;;
  *)
    logGitBackup "ERROR: Invalid state: $STATE"
    exit 1
    ;;
  esac

  sleep 10
done