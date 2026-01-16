# Git Backup

The Git Backup feature allows you to automatically commit your Minecraft server data to a git repository as a backup mechanism. This can be triggered on server startup, when all players disconnect, or on a periodic schedule.

!!! note

    This feature requires git to be installed in the container and the backup path to be initialized as a git repository.

## Enabling Git Backup

Set `GIT_BACKUP_ENABLED` to `true` to enable the git backup daemon:

``` yaml
      GIT_BACKUP_ENABLED: "true"
```

## Configuration Options

| Variable | Default | Description |
|----------|---------|-------------|
| `GIT_BACKUP_ENABLED` | `false` | Enable or disable the git backup feature |
| `GIT_BACKUP_PATH` | `/data` | Path to the directory to backup (must be a git repository) |
| `GIT_BACKUP_TRIGGERS` | `` | Comma-separated list of backup triggers (see below) |
| `GIT_BACKUP_PERIOD` | `0` | Periodic backup interval in seconds (0 = disabled) |
| `GIT_BACKUP_COMMIT_MSG` | `Auto backup - %DATE%` | Commit message template |
| `GIT_BACKUP_BRANCH` | `` | Branch to commit to (empty = current branch) |
| `GIT_BACKUP_ADD_PATHS` | `.` | Comma-separated paths to add (relative to backup path) |
| `GIT_BACKUP_EXCLUDE_PATHS` | `` | Comma-separated paths to exclude from backup |
| `GIT_BACKUP_AUTHOR_NAME` | `Minecraft Server` | Git author name for commits |
| `GIT_BACKUP_AUTHOR_EMAIL` | `minecraft@server.local` | Git author email for commits |
| `GIT_BACKUP_LFS_ENABLED` | `false` | Enable Git LFS for large files |
| `GIT_BACKUP_LFS_PATTERNS` | `*.mca,*.jar,*.zip,*.dat,*.dat_old,*.nbt` | Comma-separated file patterns to track with LFS |
| `GIT_BACKUP_PUSH_ENABLED` | `false` | Enable pushing commits to a remote repository |
| `GIT_BACKUP_REMOTE` | `` | Remote repository URL (required if push enabled) |
| `GIT_BACKUP_REMOTE_NAME` | `origin` | Name of the git remote |
| `GIT_BACKUP_RESTORE_COMMIT` | `` | Restore to this commit on startup (empty = no restore) |
| `GIT_BACKUP_AUTO_INIT` | `false` | Automatically initialize git repository if it doesn't exist |
| `GIT_BACKUP_GITIGNORE_ENABLED` | `true` | Auto-generate `.gitignore` if it doesn't exist |
| `GIT_BACKUP_GITIGNORE_PATTERNS` | `logs/,crash-reports/,cache/,bluemap/,libraries/,plugins/spark/` | Comma-separated patterns for auto-generated `.gitignore` |

## Backup Triggers

The `GIT_BACKUP_TRIGGERS` variable accepts a comma-separated list of trigger events:

| Trigger | Description |
|---------|-------------|
| `startup` | Run backup when the server starts and is ready |
| `last_disconnect` | Run backup when the last player disconnects (server empty) |
| `first_join` | Run backup when the first player joins (after server was empty) |
| `on_connect` | Run backup whenever any player connects |
| `on_disconnect` | Run backup whenever any player disconnects |

**Examples:**

``` yaml
# Single trigger
GIT_BACKUP_TRIGGERS: "startup"

# Multiple triggers
GIT_BACKUP_TRIGGERS: "startup,last_disconnect"

# All common triggers
GIT_BACKUP_TRIGGERS: "startup,first_join,last_disconnect"
```

## Commit Message Templates

The commit message supports the following placeholders:

- `%DATE%` - Current date/time in ISO 8601 format
- `%REASON%` - The trigger reason (`startup`, `last_disconnect`, or `periodic`)

**Example:**

``` yaml
      GIT_BACKUP_COMMIT_MSG: "Server backup [%REASON%] - %DATE%"
```

## Example Configurations

**Basic - Backup when all players leave:**

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_AUTO_INIT: "true"
      GIT_BACKUP_TRIGGERS: "last_disconnect"
```

**Backup on startup and when players leave:**

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_AUTO_INIT: "true"
      GIT_BACKUP_TRIGGERS: "startup,last_disconnect"
```

**Periodic backups every hour:**

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_AUTO_INIT: "true"
      GIT_BACKUP_PERIOD: "3600"
```

**Full configuration example:**

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_AUTO_INIT: "true"
      GIT_BACKUP_PATH: "/data"
      GIT_BACKUP_TRIGGERS: "startup,last_disconnect"
      GIT_BACKUP_PERIOD: "1800"
      GIT_BACKUP_COMMIT_MSG: "Minecraft backup [%REASON%] - %DATE%"
      GIT_BACKUP_BRANCH: "backups"
      GIT_BACKUP_ADD_PATHS: "world,world_nether,world_the_end,server.properties"
      GIT_BACKUP_EXCLUDE_PATHS: "logs,crash-reports"
      GIT_BACKUP_AUTHOR_NAME: "MC Backup Bot"
      GIT_BACKUP_AUTHOR_EMAIL: "backup@minecraft.local"
      GIT_BACKUP_LFS_ENABLED: "true"
      GIT_BACKUP_LFS_PATTERNS: "*.mca,*.jar,*.zip,*.dat,*.dat_old,*.nbt"
      GIT_BACKUP_PUSH_ENABLED: "true"
      GIT_BACKUP_REMOTE: "https://github.com/username/minecraft-backup.git"
```

## Git LFS (Large File Storage)

Minecraft world data contains large binary files (region files, NBT data, etc.) that are not efficient to store in regular git. Git LFS handles these large files by storing them separately and only keeping pointers in the repository.

!!! warning

    Git LFS is **strongly recommended** for Minecraft server backups. Without it, your repository will quickly become very large and slow.

### Enabling LFS

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_LFS_ENABLED: "true"
```

### Default LFS Patterns

The following file patterns are tracked by LFS by default:

| Pattern | Description |
|---------|-------------|
| `*.mca` | Region files (world chunk data) - these are the largest files |
| `*.jar` | Server and plugin JAR files |
| `*.zip` | Compressed archives (resource packs, backups) |
| `*.dat` | NBT data files (player data, level.dat, etc.) |
| `*.dat_old` | Backup NBT data files |
| `*.nbt` | Raw NBT files |

### Custom LFS Patterns

You can customize which files are tracked by LFS:

``` yaml
    environment:
      GIT_BACKUP_LFS_ENABLED: "true"
      GIT_BACKUP_LFS_PATTERNS: "*.mca,*.jar,*.zip,*.dat,*.dat_old,*.nbt,*.png,*.schematic"
```

### LFS Prerequisites

1. **git-lfs must be installed** in the container
2. **Your remote repository must support LFS** (GitHub, GitLab, Bitbucket all support it)
3. **LFS storage quotas** - be aware of your hosting provider's LFS storage limits

## Pushing to a Remote Repository

Enable automatic pushing after each backup commit:

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_PUSH_ENABLED: "true"
      GIT_BACKUP_REMOTE: "https://github.com/username/minecraft-backup.git"
```

### Authentication

For pushing to work, you'll need to configure authentication. There are several methods:

**Option 1: HTTPS with Personal Access Token (recommended for GitHub/GitLab)**

Include the token in the remote URL:

``` yaml
      GIT_BACKUP_REMOTE: "https://<token>@github.com/username/minecraft-backup.git"
```

Or use environment-based credential helper:

``` yaml
      GIT_BACKUP_REMOTE: "https://github.com/username/minecraft-backup.git"
    environment:
      GIT_ASKPASS: "/path/to/credential-script.sh"
```

**Option 2: SSH Key**

Mount your SSH key into the container and use an SSH URL:

``` yaml
    volumes:
      - ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro
      - ~/.ssh/known_hosts:/root/.ssh/known_hosts:ro
    environment:
      GIT_BACKUP_REMOTE: "git@github.com:username/minecraft-backup.git"
```

**Option 3: Git Credential Store**

Mount a `.git-credentials` file:

``` yaml
    volumes:
      - ./git-credentials:/root/.git-credentials:ro
    environment:
      GIT_BACKUP_REMOTE: "https://github.com/username/minecraft-backup.git"
```

Contents of `git-credentials`:
```
https://<username>:<token>@github.com
```

!!! warning "Security Note"

    Never commit credentials to version control. Use Docker secrets or environment variables from a secure source for production deployments.

### Custom Remote Name

If you need to use a remote name other than `origin`:

``` yaml
      GIT_BACKUP_REMOTE_NAME: "backup"
      GIT_BACKUP_REMOTE: "https://github.com/username/minecraft-backup.git"
```

## Setting Up the Git Repository

Before using git backup, the backup path must be a git repository. There are several ways to set this up:

**Option 1: Automatic Initialization (Recommended)**

Set `GIT_BACKUP_AUTO_INIT` to `true` and the daemon will automatically initialize the git repository on first startup:

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_AUTO_INIT: "true"
      GIT_BACKUP_LFS_ENABLED: "true"
```

This will automatically run `git init` and `git lfs install` (if LFS is enabled) when the container starts.

**Option 2: Mount an existing repository:**

``` yaml
    volumes:
      - /path/to/your/backup-repo:/data
```

**Option 3: Initialize manually:**

```bash
docker exec -u 1000 -it <container_name> bash
cd /data
git init
git lfs install  # if using LFS
git remote add origin <your-remote-url>  # if pushing to remote
exit
```

!!! warning "File Ownership"

    When initializing git manually via `docker exec`, you typically run as root, but the Minecraft server runs as uid 1000. This causes permission errors.

    **After running `git init`, fix the ownership:**

    ```bash
    # Inside the container (as root)
    chown -R 1000:1000 /data/.git
    ```

    Or initialize as the correct user:

    ```bash
    docker exec -u 1000 -it <container_name> bash
    cd /data
    git init
    git lfs install
    ```

    You can verify correct ownership with:

    ```bash
    ls -la /data/.git
    # Should show: drwxr-xr-x ... 1000 1000 ... .git
    # Or: drwxr-xr-x ... minecraft minecraft ... .git
    ```

## Excluding Files with .gitignore

The git backup daemon can automatically create a `.gitignore` file with sensible defaults for Minecraft servers. This is enabled by default.

### Automatic .gitignore Management

When `GIT_BACKUP_GITIGNORE_ENABLED` is `true` (the default), the `.gitignore` file is automatically managed based on the `GIT_BACKUP_GITIGNORE_PATTERNS` environment variable.

**Key behaviors:**

1. **Auto-creation**: If `.gitignore` doesn't exist, it will be created automatically
2. **Auto-update**: When `GIT_BACKUP_GITIGNORE_PATTERNS` changes, the file is updated to match
3. **Auto-commit**: Changes to `.gitignore` are committed immediately so they take effect
4. **Auto-untrack**: Files matching new ignore patterns are automatically removed from git tracking (but not deleted from disk)

!!! note "Why auto-commit?"

    In Git, `.gitignore` only affects *untracked* files. Once a file is tracked, adding it to `.gitignore` has no effect until you explicitly untrack it. The daemon handles this automatically by:
    
    1. Updating the `.gitignore` file
    2. Running `git rm --cached` on newly-ignored patterns to untrack them
    3. Committing both changes together
    4. Pushing to remote (if enabled)

**Default patterns excluded:**

| Pattern | Description |
|---------|-------------|
| `logs/` | Server log files |
| `crash-reports/` | Crash report files |
| `cache/` | Various cache directories |
| `bluemap/` | BlueMap web map data (large, can be regenerated) |
| `libraries/` | Downloaded library files |
| `plugins/spark/` | Spark profiler data |

### Customizing .gitignore Patterns

You can customize the patterns via environment variable:

``` yaml
    environment:
      GIT_BACKUP_GITIGNORE_PATTERNS: "logs/,crash-reports/,cache/,*.tmp,dynmap/"
```

### Disabling Auto-Management

If you want to manage `.gitignore` manually, disable auto-management:

``` yaml
    environment:
      GIT_BACKUP_GITIGNORE_ENABLED: "false"
```

!!! warning

    When `GIT_BACKUP_GITIGNORE_ENABLED` is `true`, the daemon **will overwrite** any existing `.gitignore` if it differs from the expected content based on `GIT_BACKUP_GITIGNORE_PATTERNS`. Set it to `false` if you want full manual control.

### Manual .gitignore

With `GIT_BACKUP_GITIGNORE_ENABLED: "false"`, you can create and manage your own `.gitignore`:

```
# Logs and crash reports
logs/
crash-reports/

# Cache and temp files
cache/
*.tmp
*.lock

# Map plugins (large, regeneratable)
bluemap/
dynmap/

# Profiler data
plugins/spark/

# Downloaded libraries
libraries/
```

### .gitignore vs GIT_BACKUP_EXCLUDE_PATHS

Both methods exclude files, but they work differently:

| Feature | `.gitignore` | `GIT_BACKUP_EXCLUDE_PATHS` |
|---------|--------------|----------------------------|
| **Scope** | Affects all git operations | Only affects backup commits |
| **Persistence** | Committed to repo | Runtime only |
| **Untracking** | Auto-untracks when patterns added | Unstages per-commit |
| **Recommended for** | Files you never want in history | Temporary exclusions |

!!! tip

    Use `GIT_BACKUP_GITIGNORE_PATTERNS` for permanent exclusions (logs, caches, generated files) and `GIT_BACKUP_EXCLUDE_PATHS` for situational exclusions you might change frequently.

!!! tip

    If `GIT_BACKUP_PUSH_ENABLED` is set to `true`, commits will automatically be pushed to the configured remote after each backup.

## Storage Considerations

| Storage Method | Pros | Cons |
|----------------|------|------|
| **Local git only** | Simple, no network needed | No off-site backup |
| **GitHub/GitLab** | Free LFS storage (limited), easy setup | Storage quotas, network dependent |
| **Self-hosted git** | Full control, unlimited storage | Requires infrastructure |
| **Git + cloud sync** | Redundancy | Complexity, potential conflicts |

### Estimated Storage Requirements

- **Small world** (few chunks explored): ~50-200 MB
- **Medium world** (moderate exploration): ~500 MB - 2 GB
- **Large world** (extensive exploration): 5-20+ GB

With Git LFS, only changed chunks are uploaded on each backup, making incremental backups efficient.

## Restoring Backups

There are two ways to restore from a backup:

### Method 1: Using the Restore Script (Recommended)

The `git-backup-restore.sh` script provides an easy way to manage and restore backups.

**List available backups:**

```bash
docker exec -it <container_name> /image/scripts/auto/git-backup-restore.sh list
```

Output:
```
[INFO] Available backups (last 10):

COMMIT      DATE                      MESSAGE
────────────────────────────────────────────────────────────────────
abc1234  2025-01-15 16:20:55 +0000  Server backup [2025-01-15T16:20:55+00:00]
def5678  2025-01-15 14:30:00 +0000  Server backup [2025-01-15T14:30:00+00:00]
...
```

**Show details of a specific backup:**

```bash
docker exec -it <container_name> /image/scripts/auto/git-backup-restore.sh show HEAD~1
```

**Restore to a previous backup:**

```bash
# First, stop the server
docker stop <container_name>

# Restore to the previous backup
docker exec -it <container_name> /image/scripts/auto/git-backup-restore.sh restore HEAD~1

# Or restore to a specific commit
docker exec -it <container_name> /image/scripts/auto/git-backup-restore.sh restore abc1234

# Start the server
docker start <container_name>
```

**Show what changed since a backup:**

```bash
docker exec -it <container_name> /image/scripts/auto/git-backup-restore.sh diff HEAD~1
```

**Available commands:**

| Command | Description |
|---------|-------------|
| `list [count]` | List available backups (default: 10) |
| `show <commit>` | Show details of a specific backup |
| `restore <commit>` | Restore to a specific backup |
| `diff <commit>` | Show changes between current state and a backup |
| `pull` | Pull latest changes from remote |

**Options:**

| Option | Description |
|--------|-------------|
| `-f, --force` | Force restore without confirmation |
| `-p, --path <path>` | Override backup path |
| `-h, --help` | Show help message |

### Method 2: Automatic Restore on Startup

You can automatically restore to a specific commit when the container starts by setting `GIT_BACKUP_RESTORE_COMMIT`:

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_RESTORE_COMMIT: "abc1234"  # Commit hash or reference
```

This is useful for:
- Rolling back after a bad update
- Deploying a known good state
- Disaster recovery

!!! warning

    Remember to remove `GIT_BACKUP_RESTORE_COMMIT` after the restore completes, or the server will restore to that commit on every restart.

### Restore Examples

**Restore to the previous backup:**

```bash
docker exec -it mc /image/scripts/auto/git-backup-restore.sh restore HEAD~1 --force
```

**Restore to 3 backups ago:**

```bash
docker exec -it mc /image/scripts/auto/git-backup-restore.sh restore HEAD~3
```

**Restore to a specific date (find commit first):**

```bash
# List more backups to find the right one
docker exec -it mc /image/scripts/auto/git-backup-restore.sh list 50

# Then restore to that commit
docker exec -it mc /image/scripts/auto/git-backup-restore.sh restore abc1234
```