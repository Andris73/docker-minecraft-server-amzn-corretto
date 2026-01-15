#!/bin/bash

# Git Backup Restore Script
# Allows easy restoration of server backups from git commits

set -e

: "${GIT_BACKUP_PATH:=/data}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

usage() {
  cat << EOF
Git Backup Restore Utility

Usage: $(basename "$0") <command> [options]

Commands:
  list [count]        List available backups (default: 10)
  show <commit>       Show details of a specific backup
  restore <commit>    Restore to a specific backup commit
  diff <commit>       Show changes between current state and a backup
  pull                Pull latest changes from remote (if configured)

Options:
  -h, --help          Show this help message
  -f, --force         Force restore without confirmation
  -p, --path <path>   Override backup path (default: /data)

Examples:
  $(basename "$0") list                    # List last 10 backups
  $(basename "$0") list 20                 # List last 20 backups
  $(basename "$0") show HEAD~1             # Show previous backup details
  $(basename "$0") restore HEAD~1          # Restore to previous backup
  $(basename "$0") restore abc1234         # Restore to specific commit
  $(basename "$0") restore HEAD~3 --force  # Restore without confirmation
  $(basename "$0") diff HEAD~1             # Show what changed since last backup

EOF
  exit 0
}

check_git_repo() {
  if [[ ! -d "${GIT_BACKUP_PATH}/.git" ]]; then
    print_error "${GIT_BACKUP_PATH} is not a git repository"
    exit 1
  fi
}

configure_safe_directory() {
  git config --global --add safe.directory "${GIT_BACKUP_PATH}" 2>/dev/null || true
}

list_backups() {
  local count="${1:-10}"
  
  cd "${GIT_BACKUP_PATH}" || exit 1
  
  echo ""
  print_info "Available backups (last ${count}):"
  echo ""
  echo -e "${YELLOW}COMMIT      DATE                      MESSAGE${NC}"
  echo "────────────────────────────────────────────────────────────────────"
  
  git log --oneline --format="%h  %ci  %s" -n "${count}" 2>/dev/null || {
    print_error "No commits found or unable to read git log"
    exit 1
  }
  
  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  print_info "Use '$(basename "$0") restore <commit>' to restore a backup"
  print_info "Use '$(basename "$0") show <commit>' for more details"
  echo ""
}

show_backup() {
  local commit="$1"
  
  if [[ -z "$commit" ]]; then
    print_error "Please specify a commit hash or reference (e.g., HEAD~1)"
    exit 1
  fi
  
  cd "${GIT_BACKUP_PATH}" || exit 1
  
  echo ""
  print_info "Backup details for: ${commit}"
  echo ""
  
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    print_error "Commit '${commit}' not found"
    exit 1
  fi
  
  git show --stat --format="Commit:  %H%nDate:    %ci%nAuthor:  %an <%ae>%nMessage: %s%n" "${commit}"
  echo ""
}

restore_backup() {
  local commit="$1"
  local force="$2"
  
  if [[ -z "$commit" ]]; then
    print_error "Please specify a commit hash or reference (e.g., HEAD~1)"
    echo ""
    echo "Usage: $(basename "$0") restore <commit>"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") restore HEAD~1    # Restore to previous backup"
    echo "  $(basename "$0") restore abc1234   # Restore to specific commit"
    exit 1
  fi
  
  cd "${GIT_BACKUP_PATH}" || exit 1
  
  # Verify commit exists
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    print_error "Commit '${commit}' not found"
    echo ""
    print_info "Use '$(basename "$0") list' to see available backups"
    exit 1
  fi
  
  # Get commit info
  local commit_hash
  local commit_date
  local commit_msg
  commit_hash=$(git rev-parse "${commit}")
  commit_date=$(git show -s --format="%ci" "${commit}")
  commit_msg=$(git show -s --format="%s" "${commit}")
  
  echo ""
  print_warning "You are about to restore to:"
  echo ""
  echo "  Commit:  ${commit_hash}"
  echo "  Date:    ${commit_date}"
  echo "  Message: ${commit_msg}"
  echo ""
  
  # Show what will change
  local changes
  changes=$(git diff --stat HEAD "${commit}" 2>/dev/null | tail -1)
  if [[ -n "$changes" ]]; then
    echo "  Changes: ${changes}"
    echo ""
  fi
  
  if [[ "$force" != "true" ]]; then
    print_warning "This will overwrite current server data!"
    print_warning "Make sure the Minecraft server is STOPPED before restoring."
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [[ "${confirm,,}" != "yes" ]]; then
      print_info "Restore cancelled"
      exit 0
    fi
  fi
  
  echo ""
  print_info "Restoring backup..."
  
  # Perform the restore
  if git reset --hard "${commit}"; then
    # If LFS is enabled, pull LFS files
    if command -v git-lfs &> /dev/null && [[ -f ".gitattributes" ]]; then
      print_info "Pulling LFS files..."
      git lfs pull 2>/dev/null || print_warning "LFS pull failed (may not be configured)"
    fi
    
    echo ""
    print_success "Backup restored successfully!"
    print_info "Current state is now at: $(git rev-parse --short HEAD)"
    echo ""
    print_warning "Please restart the Minecraft server for changes to take effect."
    echo ""
  else
    print_error "Failed to restore backup"
    exit 1
  fi
}

show_diff() {
  local commit="$1"
  
  if [[ -z "$commit" ]]; then
    print_error "Please specify a commit hash or reference (e.g., HEAD~1)"
    exit 1
  fi
  
  cd "${GIT_BACKUP_PATH}" || exit 1
  
  if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
    print_error "Commit '${commit}' not found"
    exit 1
  fi
  
  echo ""
  print_info "Changes between current state and ${commit}:"
  echo ""
  
  git diff --stat "${commit}" HEAD
  echo ""
}

pull_remote() {
  cd "${GIT_BACKUP_PATH}" || exit 1
  
  local remote
  remote=$(git remote 2>/dev/null | head -1)
  
  if [[ -z "$remote" ]]; then
    print_error "No remote configured"
    exit 1
  fi
  
  print_info "Pulling from remote '${remote}'..."
  
  if git pull "${remote}" 2>&1; then
    # If LFS is enabled, pull LFS files
    if command -v git-lfs &> /dev/null && [[ -f ".gitattributes" ]]; then
      print_info "Pulling LFS files..."
      git lfs pull 2>/dev/null || true
    fi
    
    print_success "Pull completed successfully!"
  else
    print_error "Failed to pull from remote"
    exit 1
  fi
}

# Parse arguments
FORCE=false
COMMAND=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -p|--path)
      GIT_BACKUP_PATH="$2"
      shift 2
      ;;
    *)
      if [[ -z "$COMMAND" ]]; then
        COMMAND="$1"
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

# Validate environment
check_git_repo
configure_safe_directory

# Execute command
case "$COMMAND" in
  list)
    list_backups "${ARGS[0]}"
    ;;
  show)
    show_backup "${ARGS[0]}"
    ;;
  restore)
    restore_backup "${ARGS[0]}" "$FORCE"
    ;;
  diff)
    show_diff "${ARGS[0]}"
    ;;
  pull)
    pull_remote
    ;;
  "")
    usage
    ;;
  *)
    print_error "Unknown command: ${COMMAND}"
    echo ""
    usage
    ;;
esac