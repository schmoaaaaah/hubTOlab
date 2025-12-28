# GitHub to GitLab Repository Sync

Automatically mirror all your GitHub repositories to a GitLab instance.

## Features

- Syncs all GitHub repos to a GitLab group
- Creates GitLab repos if they don't exist
- Preserves all branches, tags, and history (mirror clone)
- Optional inclusion of forks and archived repos
- Dry-run mode for testing
- Docker support for easy deployment

## Prerequisites

### Authentication

You need access tokens for both GitHub and GitLab:

**GitHub Personal Access Token:**
- Go to GitHub → Settings → Developer settings → Personal access tokens
- Create a token with `repo` scope (for private repos) or `public_repo` (for public only)

**GitLab Personal Access Token:**
- Go to GitLab → User Settings → Access Tokens
- Create a token with `api` and `write_repository` scopes

## Usage

### With Docker (Recommended)

1. **Build the image:**
   ```bash
   docker build -t github-gitlab-sync .
   ```

2. **Run with authentication:**
   ```bash
   # Using environment variables
   docker run --rm -it \
     -e GITHUB_TOKEN=ghp_xxxx \
     -e GITLAB_TOKEN=glpat-xxxx \
     -v ~/.ssh:/home/syncer/.ssh:ro \
     -v $(pwd)/data:/data \
     github-gitlab-sync \
     -g github -h gitlab.r4nd0.com
   ```

3. **Or use docker-compose:**
   ```bash
   # Set tokens in .env file or export them
   export GITHUB_TOKEN=ghp_xxxx
   export GITLAB_TOKEN=glpat-xxxx
   
   docker-compose run --rm github-gitlab-sync -g github -h gitlab.r4nd0.com
   ```

### Without Docker

1. **Install dependencies:**
   ```bash
   # On Arch/CachyOS
   sudo pacman -S git jq github-cli glab
   
   # On Ubuntu/Debian
   sudo apt install git jq
   # Install gh: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
   # Install glab: https://gitlab.com/gitlab-org/cli#installation
   ```

2. **Authenticate:**
   ```bash
   gh auth login
   glab auth login -h gitlab.r4nd0.com
   ```

3. **Run the script:**
   ```bash
   chmod +x sync.sh
   ./sync.sh -g github -h gitlab.r4nd0.com
   ```

## Options

| Option | Environment Variable | Default | Description |
|--------|---------------------|---------|-------------|
| `-g, --gitlab-group` | `GITLAB_GROUP` | `github` | GitLab group/namespace to sync to |
| `-h, --gitlab-host` | `GITLAB_HOST` | `gitlab.com` | GitLab instance hostname |
| `-u, --github-user` | `GITHUB_USER` | (authenticated user) | GitHub username to sync from |
| `-w, --work-dir` | `WORK_DIR` | `/tmp/github-mirror` | Directory for bare repos |
| `-f, --include-forks` | `INCLUDE_FORKS` | `false` | Include forked repositories |
| `-a, --include-archived` | `INCLUDE_ARCHIVED` | `false` | Include archived repositories |
| `-d, --dry-run` | `DRY_RUN` | `false` | Show what would be done |

## Examples

```bash
# Dry run to see what would happen
./sync.sh -d -g github -h gitlab.r4nd0.com

# Include forks and archived repos
./sync.sh -f -a -g github -h gitlab.r4nd0.com

# Sync a specific user's repos
./sync.sh -u someuser -g github -h gitlab.r4nd0.com
```

## Running on a Schedule

### With Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: github-gitlab-sync
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: sync
            image: github-gitlab-sync:latest
            args: ["-g", "github", "-h", "gitlab.r4nd0.com"]
            env:
            - name: GITHUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: github-gitlab-sync
                  key: github-token
            - name: GITLAB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: github-gitlab-sync
                  key: gitlab-token
            volumeMounts:
            - name: ssh-keys
              mountPath: /home/syncer/.ssh
              readOnly: true
            - name: data
              mountPath: /data
          volumes:
          - name: ssh-keys
            secret:
              secretName: github-gitlab-sync-ssh
              defaultMode: 0400
          - name: data
            persistentVolumeClaim:
              claimName: github-gitlab-sync-data
          restartPolicy: OnFailure
```

### With systemd timer

```bash
# /etc/systemd/system/github-gitlab-sync.service
[Unit]
Description=GitHub to GitLab Sync

[Service]
Type=oneshot
ExecStart=/usr/local/bin/github-gitlab-sync -g github -h gitlab.r4nd0.com
User=syncer

# /etc/systemd/system/github-gitlab-sync.timer
[Unit]
Description=Run GitHub to GitLab Sync daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

## How It Works

1. Authenticates with both GitHub and GitLab APIs
2. Creates the GitLab group if it doesn't exist
3. Lists all GitHub repositories for the authenticated user
4. For each repository:
   - Skips forks/archived unless enabled
   - Creates the GitLab project if it doesn't exist
   - Clones as a bare/mirror repository
   - Pushes all refs to GitLab (mirror push)

## Troubleshooting

**"Permission denied (publickey)"**
- Ensure your SSH key is added to both GitHub and GitLab
- Check that the SSH key is mounted correctly in Docker

**"Failed to create GitLab repo"**
- Verify your GitLab token has `api` scope
- Check if you have permission to create projects in the group

**"Not authenticated"**
- Run `gh auth status` and `glab auth status` to check
- Re-authenticate if needed
