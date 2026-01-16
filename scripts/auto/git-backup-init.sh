#!/bin/bash

# Git Backup Initialization Script
# This script runs BLOCKING to ensure clone/restore completes before server init continues
# It handles: SSH setup, clone from remote, restore to target, LFS pull

: "${GIT_BACKUP_ENABLED:=false}"
: "${GIT_BACKUP_SSH_WAIT_TIMEOUT:=300}"
: "${GIT_BACKUP_SSH_RETRY_INTERVAL:=10}"
: "${GIT_BACKUP_PATH:=/data}"
: "${GIT_BACKUP_REMOTE:=}"
: "${GIT_BACKUP_REMOTE_NAME:=origin}"
: "${GIT_BACKUP_BRANCH:=}"
: "${GIT_BACKUP_INIT_MODE:=}"
: "${GIT_BACKUP_RESTORE_ENABLED:=false}"
: "${GIT_BACKUP_RESTORE_TARGET:=}"
: "${GIT_BACKUP_LFS_ENABLED:=false}"
: "${GIT_BACKUP_LFS_PATTERNS:=*.mca,*.jar,*.zip,*.dat,*.dat_old,*.nbt,*.sqlite,*.sqlite-shm,*.sqlite-wal}"
: "${GIT_BACKUP_AUTHOR_NAME:=Minecraft Server}"
: "${GIT_BACKUP_AUTHOR_EMAIL:=minecraft@server.local}"
: "${GIT_BACKUP_SSH_KEYGEN:=true}"
: "${GIT_BACKUP_SSH_KEY_PATH:=${GIT_BACKUP_PATH}/.ssh}"
: "${GIT_BACKUP_GITIGNORE_PATTERNS:=logs/,crash-reports/,cache/,bluemap/,libraries/,plugins/spark/,.ssh/}"

# shellcheck source=../start-utils
. /image/scripts/start-utils

logGitBackupInit() {
  echo "[Git Backup Init] $*"
}

logGitBackupInitAction() {
  echo "[$(date -Iseconds)] [Git Backup Init] $*"
}

# Check if a remote URL uses SSH
is_ssh_remote() {
  local url="$1"
  [[ "$url" =~ ^git@ ]] || [[ "$url" =~ ^ssh:// ]]
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

  logGitBackupInit "Setting up SSH keys for Git operations..."

  local ssh_dir="${GIT_BACKUP_SSH_KEY_PATH}"
  local key_file="${ssh_dir}/id_ed25519"
  local pub_key_file="${key_file}.pub"
  local ssh_config="${ssh_dir}/config"
  local known_hosts="${ssh_dir}/known_hosts"
  local key_generated=false

  # Create SSH directory
  if [[ ! -d "${ssh_dir}" ]]; then
    logGitBackupInit "Creating SSH directory: ${ssh_dir}"
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
  fi

  # Generate SSH key if it doesn't exist
  if [[ ! -f "${key_file}" ]]; then
    logGitBackupInit "Generating new SSH key pair..."
    if ! ssh-keygen -t ed25519 -f "${key_file}" -N "" -C "minecraft-server-backup" 2>&1; then
      logGitBackupInit "ERROR: Failed to generate SSH key"
      return 1
    fi
    chmod 600 "${key_file}"
    chmod 644 "${pub_key_file}"
    key_generated=true
    # Export this so clone_from_remote knows to wait for deploy key
    export GIT_BACKUP_SSH_KEY_NEW="true"
    logGitBackupInit "SSH key pair generated successfully"
  else
    logGitBackupInit "Using existing SSH key: ${key_file}"
    export GIT_BACKUP_SSH_KEY_NEW="false"
  fi

  # Extract hostname from remote URL
  local hostname
  hostname=$(get_ssh_hostname "${GIT_BACKUP_REMOTE}")

  # Create SSH config to use our key
  logGitBackupInit "Configuring SSH for ${hostname:-git hosts}..."
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
    logGitBackupInit "Fetching SSH host keys for known Git providers..."
    {
      ssh-keyscan -t ed25519,rsa github.com 2>/dev/null
      ssh-keyscan -t ed25519,rsa gitlab.com 2>/dev/null
      ssh-keyscan -t ed25519,rsa bitbucket.org 2>/dev/null
    } > "${known_hosts}" 2>/dev/null
    
    if [[ -n "$hostname" ]] && [[ "$hostname" != "github.com" ]] && [[ "$hostname" != "gitlab.com" ]] && [[ "$hostname" != "bitbucket.org" ]]; then
      logGitBackupInit "Fetching SSH host key for: ${hostname}"
      ssh-keyscan -t ed25519,rsa "${hostname}" >> "${known_hosts}" 2>/dev/null || true
    fi
  fi

  # Set GIT_SSH_COMMAND to use our config
  export GIT_SSH_COMMAND="ssh -F ${ssh_config}"
  logGitBackupInit "SSH configured with GIT_SSH_COMMAND"

  # Output the public key for the user
  logGitBackupInit "============================================================"
  logGitBackupInit "SSH PUBLIC KEY - Add this as a Deploy Key to your repository"
  logGitBackupInit "============================================================"
  if [[ -f "${pub_key_file}" ]]; then
    logGitBackupInit ""
    cat "${pub_key_file}" | while IFS= read -r line; do
      logGitBackupInit "  ${line}"
    done
    logGitBackupInit ""
  fi
  logGitBackupInit "============================================================"
  
  if [[ "$key_generated" == "true" ]]; then
    logGitBackupInit "NOTE: This is a NEW key. You must add it to your Git provider!"
    logGitBackupInit ""
    logGitBackupInit "For GitHub:"
    logGitBackupInit "  1. Go to your repository -> Settings -> Deploy keys"
    logGitBackupInit "  2. Click 'Add deploy key'"
    logGitBackupInit "  3. Paste the public key above"
    logGitBackupInit "  4. Check 'Allow write access' for push support"
    logGitBackupInit "  5. Click 'Add key'"
    logGitBackupInit ""
  fi
  logGitBackupInit "Key location: ${pub_key_file}"
  logGitBackupInit "============================================================"

  return 0
}

# Configure git safe.directory
configure_git_safe_directory() {
  # Check if already configured to avoid duplicating entries
  local current_dirs
  current_dirs=$(git config --global --get-all safe.directory 2>/dev/null || true)
  if [[ "$current_dirs" != *"${GIT_BACKUP_PATH}"* ]]; then
    logGitBackupInit "Configuring git safe.directory for ${GIT_BACKUP_PATH}"
    git config --global --add safe.directory "${GIT_BACKUP_PATH}" 2>/dev/null || true
  fi
}

# Clone from remote repository
clone_from_remote() {
  if [[ -z "${GIT_BACKUP_REMOTE}" ]]; then
    logGitBackupInit "ERROR: GIT_BACKUP_INIT_MODE=clone requires GIT_BACKUP_REMOTE to be set"
    return 1
  fi

  logGitBackupInit "Cloning from remote repository: ${GIT_BACKUP_REMOTE}"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackupInit "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  # Initialize if not already a git repo
  if [[ ! -d ".git" ]]; then
    logGitBackupInit "Initializing git repository..."
    if ! git init 2>&1; then
      logGitBackupInit "ERROR: Failed to initialize git repository"
      return 1
    fi
  fi

  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  # Add or update remote
  local existing_remote
  existing_remote=$(git remote get-url "${GIT_BACKUP_REMOTE_NAME}" 2>/dev/null)
  
  if [[ -z "${existing_remote}" ]]; then
    logGitBackupInit "Adding remote '${GIT_BACKUP_REMOTE_NAME}': ${GIT_BACKUP_REMOTE}"
    if ! git remote add "${GIT_BACKUP_REMOTE_NAME}" "${GIT_BACKUP_REMOTE}" 2>&1; then
      logGitBackupInit "ERROR: Failed to add remote"
      return 1
    fi
  elif [[ "${existing_remote}" != "${GIT_BACKUP_REMOTE}" ]]; then
    logGitBackupInit "Updating remote '${GIT_BACKUP_REMOTE_NAME}' URL"
    git remote set-url "${GIT_BACKUP_REMOTE_NAME}" "${GIT_BACKUP_REMOTE}"
  fi

  # Initialize LFS before fetch if enabled
  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    if command -v git-lfs &> /dev/null; then
      logGitBackupInit "Initializing Git LFS..."
      git lfs install --local 2>&1 || logGitBackupInit "WARNING: Failed to initialize LFS"
    fi
  fi

  # Fetch from remote (with retry logic for SSH key setup)
  logGitBackupInitAction "Fetching from remote..."
  local fetch_output
  local fetch_exit_code
  local fetch_attempts=0
  local max_wait_time="${GIT_BACKUP_SSH_WAIT_TIMEOUT}"
  local retry_interval="${GIT_BACKUP_SSH_RETRY_INTERVAL}"
  local waited_time=0

  fetch_output=$(git fetch "${GIT_BACKUP_REMOTE_NAME}" 2>&1)
  fetch_exit_code=$?

  # If fetch failed with permission denied, wait for user to add deploy key
  # This applies whether the key is new or existing (user might not have added it yet)
  if [[ $fetch_exit_code -ne 0 ]]; then
    if [[ "$fetch_output" == *"Permission denied"* ]] || [[ "$fetch_output" == *"publickey"* ]]; then
      logGitBackupInit ""
      logGitBackupInit "============================================================"
      logGitBackupInit "WAITING FOR DEPLOY KEY TO BE ADDED"
      logGitBackupInit "============================================================"
      logGitBackupInit ""
      logGitBackupInit "The SSH key was just generated and needs to be added to your"
      logGitBackupInit "Git repository as a deploy key before we can continue."
      logGitBackupInit ""
      logGitBackupInit "Please add this public key to your repository NOW:"
      logGitBackupInit ""
      cat "${GIT_BACKUP_SSH_KEY_PATH}/id_ed25519.pub" | while IFS= read -r line; do
        logGitBackupInit "  ${line}"
      done
      logGitBackupInit ""
      logGitBackupInit "For GitHub: Repository -> Settings -> Deploy keys -> Add deploy key"
      logGitBackupInit "            (Enable 'Allow write access' for push support)"
      logGitBackupInit ""
      logGitBackupInit "Waiting up to ${max_wait_time} seconds for deploy key..."
      logGitBackupInit "(Set GIT_BACKUP_SSH_WAIT_TIMEOUT=0 to skip waiting)"
      logGitBackupInit "============================================================"
      logGitBackupInit ""

      while [[ $waited_time -lt $max_wait_time ]]; do
        sleep "${retry_interval}"
        waited_time=$((waited_time + retry_interval))
        fetch_attempts=$((fetch_attempts + 1))
        
        logGitBackupInit "Retry attempt ${fetch_attempts} (waited ${waited_time}s of ${max_wait_time}s)..."
        fetch_output=$(git fetch "${GIT_BACKUP_REMOTE_NAME}" 2>&1)
        fetch_exit_code=$?
        
        if [[ $fetch_exit_code -eq 0 ]]; then
          logGitBackupInit ""
          logGitBackupInit "============================================================"
          logGitBackupInit "Deploy key accepted! Continuing with clone..."
          logGitBackupInit "============================================================"
          break
        fi
        
        if [[ "$fetch_output" != *"Permission denied"* ]] && [[ "$fetch_output" != *"publickey"* ]]; then
          # Different error, stop waiting
          logGitBackupInit "Fetch failed with different error, stopping retry"
          break
        fi
      done
    fi
  fi

  if [[ $fetch_exit_code -ne 0 ]]; then
    logGitBackupInitAction "Fetch FAILED (exit code: ${fetch_exit_code})"
    if [[ -n "$fetch_output" ]]; then
      logGitBackupInit "  Error details: ${fetch_output}"
    fi
    logGitBackupInit ""
    logGitBackupInit "TIP: Add the deploy key shown above to your repository and restart the container."
    logGitBackupInit "     Or set GIT_BACKUP_SSH_WAIT_TIMEOUT to a higher value to wait longer."
    return 1
  fi
  logGitBackupInitAction "Fetch succeeded"

  # Determine branch to checkout
  local branch_to_checkout="${GIT_BACKUP_BRANCH}"
  if [[ -z "${branch_to_checkout}" ]]; then
    branch_to_checkout=$(git remote show "${GIT_BACKUP_REMOTE_NAME}" 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
    if [[ -z "${branch_to_checkout}" ]]; then
      if git rev-parse --verify "${GIT_BACKUP_REMOTE_NAME}/main" &>/dev/null; then
        branch_to_checkout="main"
      elif git rev-parse --verify "${GIT_BACKUP_REMOTE_NAME}/master" &>/dev/null; then
        branch_to_checkout="master"
      else
        logGitBackupInit "ERROR: Could not determine branch to checkout"
        logGitBackupInit "Hint: Set GIT_BACKUP_BRANCH to specify the branch"
        return 1
      fi
    fi
  fi

  logGitBackupInit "Checking out branch: ${branch_to_checkout}"

  # Checkout the branch
  if ! git checkout -B "${branch_to_checkout}" "${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" --force 2>&1; then
    logGitBackupInit "Standard checkout failed, trying alternative approach..."
    git branch -f "${branch_to_checkout}" "${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" 2>/dev/null || true
    git checkout -f "${branch_to_checkout}" 2>/dev/null || true
  fi

  # Reset to match remote exactly
  logGitBackupInit "Resetting working directory to match remote..."
  if ! git reset --hard "${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" 2>&1; then
    logGitBackupInit "ERROR: Failed to reset to remote branch ${branch_to_checkout}"
    return 1
  fi

  # Set upstream tracking
  git branch --set-upstream-to="${GIT_BACKUP_REMOTE_NAME}/${branch_to_checkout}" "${branch_to_checkout}" 2>/dev/null

  # Pull LFS files SYNCHRONOUSLY - this is critical!
  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    logGitBackupInit "Pulling LFS files (this may take a while)..."
    if git lfs pull 2>&1; then
      logGitBackupInitAction "LFS pull completed successfully"
    else
      logGitBackupInit "WARNING: LFS pull had issues (some large files may be missing)"
    fi
  fi

  local commit_hash
  local commit_date
  local commit_msg
  commit_hash=$(git rev-parse --short HEAD 2>/dev/null)
  commit_date=$(git show -s --format="%ci" HEAD 2>/dev/null)
  commit_msg=$(git show -s --format="%s" HEAD 2>/dev/null)

  logGitBackupInitAction "Clone from remote completed successfully"
  logGitBackupInit "  Branch:  ${branch_to_checkout}"
  logGitBackupInit "  Commit:  ${commit_hash}"
  logGitBackupInit "  Date:    ${commit_date}"
  logGitBackupInit "  Message: ${commit_msg}"

  return 0
}

# Initialize a fresh git repository
init_git_repo() {
  logGitBackupInit "Initializing fresh git repository in ${GIT_BACKUP_PATH}"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackupInit "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  if [[ ! -d ".git" ]]; then
    if ! git init 2>&1; then
      logGitBackupInit "ERROR: Failed to initialize git repository"
      return 1
    fi
  fi

  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    if command -v git-lfs &> /dev/null; then
      logGitBackupInit "Initializing Git LFS..."
      git lfs install --local 2>&1 || logGitBackupInit "WARNING: Failed to initialize LFS"
    fi
  fi

  logGitBackupInit "Git repository initialized successfully"
  return 0
}

# Restore to a specific commit target
restore_to_target() {
  local target="${GIT_BACKUP_RESTORE_TARGET}"

  if [[ -z "$target" ]]; then
    logGitBackupInit "No restore target specified, using current HEAD"
    return 0
  fi

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackupInit "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  logGitBackupInit "Restoring to target: ${target}"

  # Check if target exists
  if ! git cat-file -e "${target}^{commit}" 2>/dev/null; then
    logGitBackupInit "ERROR: Target '${target}' not found"
    logGitBackupInit "Use 'git log --oneline' to see available commits"
    return 1
  fi

  local target_hash
  local target_date
  local target_msg
  target_hash=$(git rev-parse "${target}" 2>/dev/null)
  target_date=$(git show -s --format="%ci" "${target}" 2>/dev/null)
  target_msg=$(git show -s --format="%s" "${target}" 2>/dev/null)

  logGitBackupInit "Restoring to:"
  logGitBackupInit "  Commit:  ${target_hash}"
  logGitBackupInit "  Date:    ${target_date}"
  logGitBackupInit "  Message: ${target_msg}"

  # Reset to target
  if ! git reset --hard "${target}" 2>&1; then
    logGitBackupInit "ERROR: Failed to restore to target ${target}"
    return 1
  fi

  # Pull LFS files for the restored commit
  if isTrue "${GIT_BACKUP_LFS_ENABLED}" && [[ -f ".gitattributes" ]]; then
    logGitBackupInit "Pulling LFS files for restored commit..."
    git lfs pull 2>/dev/null || logGitBackupInit "WARNING: LFS pull failed"
  fi

  logGitBackupInitAction "Restore to target completed successfully"
  logGitBackupInit "  Current HEAD: $(git rev-parse --short HEAD)"
  return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

logGitBackupInit "Starting Git backup initialization..."

# Check git is installed
if ! command -v git &> /dev/null; then
  logGitBackupInit "ERROR: git is not installed"
  exit 1
fi

# Setup SSH keys if using SSH remote
if is_ssh_remote "${GIT_BACKUP_REMOTE}"; then
  if ! setup_ssh_keys; then
    logGitBackupInit "WARNING: SSH key setup failed, remote operations may fail"
  fi
fi

# Configure safe directory
configure_git_safe_directory

# Handle repository initialization based on mode
case "${GIT_BACKUP_INIT_MODE,,}" in
  clone)
    if ! clone_from_remote; then
      logGitBackupInit "ERROR: Clone from remote failed"
      exit 1
    fi
    ;;
  init)
    if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
      if ! init_git_repo; then
        logGitBackupInit "ERROR: Repository initialization failed"
        exit 1
      fi
    fi
    ;;
  "")
    # No init mode specified, check if repo exists
    if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
      logGitBackupInit "WARNING: No git repository found and no INIT_MODE specified"
      logGitBackupInit "Hint: Set GIT_BACKUP_INIT_MODE=clone to clone from remote"
      logGitBackupInit "Hint: Set GIT_BACKUP_INIT_MODE=init to create fresh repo"
    fi
    ;;
esac

# Handle restore if enabled and target specified
if isTrue "${GIT_BACKUP_RESTORE_ENABLED}" && [[ -n "${GIT_BACKUP_RESTORE_TARGET}" ]]; then
  if [[ -d "${GIT_BACKUP_PATH}/.git" ]]; then
    if ! restore_to_target; then
      logGitBackupInit "WARNING: Restore to target failed, continuing with current state"
    fi
  else
    logGitBackupInit "WARNING: Cannot restore - no git repository exists"
  fi
fi

logGitBackupInit "Git backup initialization complete"
logGitBackupInit "============================================================"

exit 0