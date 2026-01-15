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
| `GIT_BACKUP_ON_STARTUP` | `false` | Run a backup when the server starts |
| `GIT_BACKUP_ON_LAST_DISCONNECT` | `true` | Run a backup when all players disconnect |
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
      GIT_BACKUP_ON_LAST_DISCONNECT: "true"
```

**Periodic backups every hour:**

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_PERIOD: "3600"
      GIT_BACKUP_ON_LAST_DISCONNECT: "false"
```

**Full configuration example:**

``` yaml
    environment:
      GIT_BACKUP_ENABLED: "true"
      GIT_BACKUP_PATH: "/data"
      GIT_BACKUP_ON_STARTUP: "true"
      GIT_BACKUP_ON_LAST_DISCONNECT: "true"
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

Before using git backup, you need to initialize the backup path as a git repository:

**Option 1: Mount an existing repository:**

``` yaml
    volumes:
      - /path/to/your/backup-repo:/data
```

**Option 2: Initialize during container setup:**

You can use an init script or manually run:

```bash
cd /data
git init
git remote add origin <your-remote-url>
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

For better control over what gets backed up, create a `.gitignore` file in your data directory:

```
# Logs and crash reports
logs/
crash-reports/

# Cache and temp files
*.tmp
*.lock

# Large files that change frequently
*.jar
```

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