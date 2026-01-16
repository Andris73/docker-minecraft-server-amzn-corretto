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
: "${GIT_BACKUP_RESTORE_COMMIT:=}"
: "${GIT_BACKUP_AUTO_INIT:=false}"
: "${GIT_BACKUP_GITIGNORE_ENABLED:=true}"
: "${GIT_BACKUP_GITIGNORE_PATTERNS:=logs/,crash-reports/,cache/,bluemap/,libraries/,plugins/spark/}"

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

  # Empty triggers means nothing is enabled
  if [[ -z "$triggers_list" ]]; then
    return 1
  fi

  # Check if trigger is in the comma-separated list
  IFS=',' read -ra triggers_array <<< "$triggers_list"
  for t in "${triggers_array[@]}"; do
    t=$(echo "$t" | xargs)  # trim whitespace
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

generate_gitignore_content() {
  # Generate the expected .gitignore content based on env var
  cat << 'EOF'
# Git Backup - Auto-generated .gitignore
# Managed by GIT_BACKUP_GITIGNORE_PATTERNS environment variable
# Changes to this file will be overwritten when the env var changes

EOF

  local patterns
  IFS=',' read -ra patterns <<< "${GIT_BACKUP_GITIGNORE_PATTERNS}"
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)  # trim whitespace
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

  # Generate expected content
  expected_content=$(generate_gitignore_content)

  # Get current content if file exists
  if [[ -f "${gitignore_file}" ]]; then
    current_content=$(cat "${gitignore_file}")
  fi

  # Compare content
  if [[ "${expected_content}" == "${current_content}" ]]; then
    logGitBackup ".gitignore is up to date"
    return 0
  fi

  # Content differs - update the file
  if [[ -f "${gitignore_file}" ]]; then
    logGitBackup ".gitignore patterns changed, updating file..."
  else
    logGitBackup "Creating .gitignore file..."
  fi

  # Write new content
  echo "${expected_content}" > "${gitignore_file}"

  # Log the patterns
  local patterns
  IFS=',' read -ra patterns <<< "${GIT_BACKUP_GITIGNORE_PATTERNS}"
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    if [[ -n "$pattern" ]]; then
      logGitBackup "  Pattern: ${pattern}"
    fi
  done

  # Untrack files that are now ignored (remove from index but keep on disk)
  logGitBackup "Removing newly-ignored files from git tracking..."
  for pattern in "${patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)
    if [[ -n "$pattern" ]]; then
      # Use git rm --cached to untrack without deleting
      # The -r flag handles directories, --ignore-unmatch prevents errors if nothing matches
      if git rm -r --cached --ignore-unmatch "${pattern}" 2>/dev/null; then
        # Check if anything was actually removed
        if ! git diff --cached --quiet -- "${pattern}" 2>/dev/null; then
          logGitBackup "  Untracked: ${pattern}"
        fi
      fi
    fi
  done

  # Stage the .gitignore file
  git add .gitignore

  # Check if there are changes to commit
  if ! git diff --cached --quiet 2>/dev/null; then
    # Configure git author if not already set
    git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
    git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

    # Commit the .gitignore changes
    local commit_msg="Update .gitignore patterns - $(date -Iseconds)"
    if git commit -m "${commit_msg}"; then
      logGitBackupAction ".gitignore committed successfully"
      # Push if enabled (unless skip_push is set, e.g. during auto-init)
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

auto_init_git_repo() {
  if ! isTrue "${GIT_BACKUP_AUTO_INIT}"; then
    return 1
  fi

  if [[ -d "${GIT_BACKUP_PATH}/.git" ]]; then
    # Already initialized
    return 0
  fi

  logGitBackup "Auto-initializing git repository in ${GIT_BACKUP_PATH}"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackup "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  # Initialize git
  if ! git init 2>&1; then
    logGitBackup "ERROR: Failed to initialize git repository"
    return 1
  fi

  # Configure git user
  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  # Create .gitignore (skip push since remote isn't set up yet)
  setup_gitignore true

  # Initialize LFS if enabled
  if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    if command -v git-lfs &> /dev/null; then
      logGitBackup "Initializing Git LFS..."
      git lfs install --local 2>&1 || logGitBackup "WARNING: Failed to initialize LFS"
    fi
  fi

  logGitBackup "Git repository initialized successfully"
  return 0
}

setup_git_lfs() {
  if ! isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
    return 0
  fi

  logGitBackup "Setting up Git LFS..."

  cd "${GIT_BACKUP_PATH}" || return 1

  # Initialize LFS for this repository
  if ! git lfs install --local 2>/dev/null; then
    logGitBackup "ERROR: Failed to initialize git-lfs"
    return 1
  fi

  # Track patterns
  local lfs_patterns
  IFS=',' read -ra lfs_patterns <<< "${GIT_BACKUP_LFS_PATTERNS}"
  for pattern in "${lfs_patterns[@]}"; do
    pattern=$(echo "$pattern" | xargs)  # trim whitespace
    if [[ -n "$pattern" ]]; then
      logGitBackup "LFS tracking pattern: ${pattern}"
      git lfs track "${pattern}" 2>/dev/null || logGitBackup "WARNING: Failed to track ${pattern}"
    fi
  done

  # Make sure .gitattributes is added
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

  # Check if remote already exists
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

run_git_push() {
  if ! isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
    return 0
  fi

  logGitBackupAction "Pushing to remote '${GIT_BACKUP_REMOTE_NAME}'..."

  cd "${GIT_BACKUP_PATH}" || return 1

  # Determine branch to push
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

  # Push to remote
  if git push "${GIT_BACKUP_REMOTE_NAME}" "${branch_to_push}" 2>&1; then
    logGitBackupAction "Push successful"
    return 0
  else
    logGitBackup "ERROR: Failed to push to remote"
    return 1
  fi
}

check_git_repo() {
  if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
    # Try auto-init if enabled
    if isTrue "${GIT_BACKUP_AUTO_INIT}"; then
      auto_init_git_repo
      return $?
    fi
    logGitBackup "ERROR: ${GIT_BACKUP_PATH} is not a git repository"
    logGitBackup "Hint: Set GIT_BACKUP_AUTO_INIT=true to automatically initialize"
    return 1
  fi
  return 0
}

configure_git_safe_directory() {
  # Add safe.directory to prevent "dubious ownership" errors
  # This is needed when running as different users in containers
  logGitBackup "Configuring git safe.directory for ${GIT_BACKUP_PATH}"
  git config --global --add safe.directory "${GIT_BACKUP_PATH}" 2>/dev/null || true
}

restore_from_commit() {
  local commit="${GIT_BACKUP_RESTORE_COMMIT}"

  if [[ -z "$commit" ]]; then
    return 0
  fi

  logGitBackup "Restore requested to commit: ${commit}"

  cd "${GIT_BACKUP_PATH}" || {
    logGitBackup "ERROR: Failed to change to ${GIT_BACKUP_PATH}"
    return 1
  }

  # Verify commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    logGitBackup "ERROR: Commit '${commit}' not found"
    logGitBackup "Use 'git log --oneline' to see available commits"
    return 1
  fi

  # Get commit info for logging
  local commit_hash
  local commit_date
  local commit_msg
  commit_hash=$(git rev-parse "${commit}")
  commit_date=$(git show -s --format="%ci" "${commit}")
  commit_msg=$(git show -s --format="%s" "${commit}")

  logGitBackup "Restoring to:"
  logGitBackup "  Commit:  ${commit_hash}"
  logGitBackup "  Date:    ${commit_date}"
  logGitBackup "  Message: ${commit_msg}"

  # Perform the restore
  if git reset --hard "${commit}"; then
    # If LFS is enabled, pull LFS files
    if isTrue "${GIT_BACKUP_LFS_ENABLED}" && [[ -f ".gitattributes" ]]; then
      logGitBackup "Pulling LFS files..."
      git lfs pull 2>/dev/null || logGitBackup "WARNING: LFS pull failed"
    fi

    logGitBackupAction "Restore completed successfully"
    logGitBackup "Server data restored to: $(git rev-parse --short HEAD)"
    return 0
  else
    logGitBackup "ERROR: Failed to restore to commit ${commit}"
    return 1
  fi
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

  # Switch branch if specified
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

  # Configure git author if not already set
  git config user.name "${GIT_BACKUP_AUTHOR_NAME}" 2>/dev/null
  git config user.email "${GIT_BACKUP_AUTHOR_EMAIL}" 2>/dev/null

  # Add files (use -A to include deletions and modifications)
  local add_paths
  IFS=',' read -ra add_paths <<< "${GIT_BACKUP_ADD_PATHS}"
  for path in "${add_paths[@]}"; do
    path=$(echo "$path" | xargs)  # trim whitespace
    if [[ -n "$path" ]]; then
      logGitBackup "Adding path: ${path}"
      if ! git add -A "${path}" 2>&1; then
        logGitBackup "WARNING: Failed to add ${path}"
      fi
    fi
  done

  # Handle exclusions by unstaging
  if [[ -n "${GIT_BACKUP_EXCLUDE_PATHS}" ]]; then
    local exclude_paths
    IFS=',' read -ra exclude_paths <<< "${GIT_BACKUP_EXCLUDE_PATHS}"
    for path in "${exclude_paths[@]}"; do
      path=$(echo "$path" | xargs)  # trim whitespace
      if [[ -n "$path" ]]; then
        logGitBackup "Excluding path: ${path}"
        git reset HEAD -- "${path}" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Check if there are staged changes
  if ! git diff --cached --quiet 2>/dev/null; then
    # Generate commit message with date substitution
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

# Exit if not enabled
if ! isTrue "${GIT_BACKUP_ENABLED}"; then
  logGitBackup "Git backup is disabled, exiting"
  exit 0
fi

# Validate prerequisites
if ! check_git_installed; then
  exit 1
fi

if ! check_git_repo; then
  logGitBackup "Hint: Initialize a git repo with 'git init ${GIT_BACKUP_PATH}'"
  exit 1
fi

# Configure safe.directory to prevent ownership issues
configure_git_safe_directory

# Restore from commit if requested
if [[ -n "${GIT_BACKUP_RESTORE_COMMIT}" ]]; then
  if ! restore_from_commit; then
    logGitBackup "ERROR: Restore failed, continuing with current state"
  fi
  # Clear the variable so we don't restore again on next iteration
  GIT_BACKUP_RESTORE_COMMIT=""
fi

# Validate LFS if enabled
if isTrue "${GIT_BACKUP_LFS_ENABLED}"; then
  if ! check_git_lfs_installed; then
    exit 1
  fi
fi

logGitBackup "Git backup daemon starting"
logGitBackup "  Backup path: ${GIT_BACKUP_PATH}"
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
fi

# Setup remote first (so gitignore commits can be pushed)
if isTrue "${GIT_BACKUP_PUSH_ENABLED}"; then
  if ! setup_git_remote; then
    logGitBackup "ERROR: Failed to setup Git remote"
    exit 1
  fi
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
    # Server startup
    if mc_server_listening ; then
      logGitBackup "Minecraft server is listening"

      if is_trigger_enabled "startup"; then
        run_git_backup "startup"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi

      # Check if we need to continue running
      if [[ -z "${GIT_BACKUP_TRIGGERS}" ]] && [[ "${GIT_BACKUP_PERIOD}" -eq 0 ]]; then
        logGitBackup "No backup triggers configured, stopping daemon"
        exit 0
      fi

      STATE=RUNNING
    fi
    ;;
  XRUNNING)
    CURR_CLIENTCONNECTIONS=$(java_clients_connections)

    # Check for periodic backup
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

    # Check for first_join backup
    if is_trigger_enabled "first_join"; then
      if (( CURR_CLIENTCONNECTIONS > 0 )) && [[ "$FIRST_JOIN_DONE" == "false" ]]; then
        logGitBackupAction "First player joined, running backup"
        run_git_backup "first_join"
        LAST_BACKUP_TIME=$CURRENT_TIME
        FIRST_JOIN_DONE=true
      fi
      # Reset first_join flag when all players leave
      if (( CURR_CLIENTCONNECTIONS == 0 )); then
        FIRST_JOIN_DONE=false
      fi
    fi

    # Check for on_connect backup (any player joins)
    if is_trigger_enabled "on_connect"; then
      if (( CURR_CLIENTCONNECTIONS > CLIENTCONNECTIONS )); then
        logGitBackupAction "Player connected, running backup"
        run_git_backup "on_connect"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi
    fi

    # Check for on_disconnect backup (any player leaves)
    if is_trigger_enabled "on_disconnect"; then
      if (( CURR_CLIENTCONNECTIONS < CLIENTCONNECTIONS )) && (( CLIENTCONNECTIONS > 0 )); then
        logGitBackupAction "Player disconnected, running backup"
        run_git_backup "on_disconnect"
        LAST_BACKUP_TIME=$CURRENT_TIME
      fi
    fi

    # Check for last_disconnect backup
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
