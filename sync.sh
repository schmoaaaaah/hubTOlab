#!/bin/bash
set -euo pipefail

# Configuration
GITLAB_GROUP="${GITLAB_GROUP:-github}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
GITHUB_USER="${GITHUB_USER:-}"
WORK_DIR="${WORK_DIR:-/tmp/github-mirror}"
INCLUDE_FORKS="${INCLUDE_FORKS:-false}"
INCLUDE_ARCHIVED="${INCLUDE_ARCHIVED:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Sync all GitHub repositories to a GitLab instance.

Options:
    -g, --gitlab-group    GitLab group/namespace to sync to (default: github)
    -h, --gitlab-host     GitLab host (default: gitlab.com)
    -u, --github-user     GitHub username (default: authenticated user)
    -w, --work-dir        Working directory for cloning (default: /tmp/github-mirror)
    -f, --include-forks   Include forked repositories (default: false)
    -a, --include-archived Include archived repositories (default: false)
    -d, --dry-run         Show what would be done without doing it
    --help                Show this help message

Environment variables:
    GITHUB_TOKEN          GitHub personal access token (or use 'gh auth login')
    GITLAB_TOKEN          GitLab personal access token (or use 'glab auth login')

Examples:
    $(basename "$0") -g github -h gitlab.r4nd0.com
    $(basename "$0") --include-forks --include-archived
    DRY_RUN=true $(basename "$0")
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--gitlab-group) GITLAB_GROUP="$2"; shift 2 ;;
        -h|--gitlab-host) GITLAB_HOST="$2"; shift 2 ;;
        -u|--github-user) GITHUB_USER="$2"; shift 2 ;;
        -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
        -f|--include-forks) INCLUDE_FORKS="true"; shift ;;
        -a|--include-archived) INCLUDE_ARCHIVED="true"; shift ;;
        -d|--dry-run) DRY_RUN="true"; shift ;;
        --help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Verify dependencies
check_dependencies() {
    local missing=()
    for cmd in gh glab git jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# Check authentication status
check_auth() {
    log_info "Checking GitHub authentication..."
    if ! gh auth status &> /dev/null; then
        log_error "Not authenticated with GitHub. Run 'gh auth login' first."
        exit 1
    fi
    
    log_info "Checking GitLab authentication..."
    if ! glab auth status -h "$GITLAB_HOST" &> /dev/null; then
        log_error "Not authenticated with GitLab. Run 'glab auth login -h $GITLAB_HOST' first."
        exit 1
    fi
    
    log_success "Authentication verified for both GitHub and GitLab"
}

# Ensure GitLab group exists
ensure_gitlab_group() {
    log_info "Checking if GitLab group '$GITLAB_GROUP' exists..."
    
    if glab api "groups/$GITLAB_GROUP" --hostname "$GITLAB_HOST" &> /dev/null; then
        log_success "GitLab group '$GITLAB_GROUP' exists"
        return 0
    fi
    
    log_warn "GitLab group '$GITLAB_GROUP' not found"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create GitLab group '$GITLAB_GROUP'"
        return 0
    fi
    
    log_info "Creating GitLab group '$GITLAB_GROUP'..."
    if glab api groups -X POST \
        --hostname "$GITLAB_HOST" \
        -f "name=$GITLAB_GROUP" \
        -f "path=$GITLAB_GROUP" \
        -f "visibility=private" &> /dev/null; then
        log_success "Created GitLab group '$GITLAB_GROUP'"
    else
        log_error "Failed to create GitLab group. It may need to be created manually or you lack permissions."
        exit 1
    fi
}

# Get list of GitHub repos
get_github_repos() {
    local query_args=("--json" "name,sshUrl,isArchived,isFork,description,isPrivate" "--limit" "1000")
    
    if [[ -n "$GITHUB_USER" ]]; then
        gh repo list "$GITHUB_USER" "${query_args[@]}" | jq -c '.[]'
    else
        gh repo list "${query_args[@]}" | jq -c '.[]'
    fi
}

# Check if GitLab repo exists
gitlab_repo_exists() {
    local repo_name="$1"
    local encoded_path
    encoded_path=$(echo "${GITLAB_GROUP}/${repo_name}" | sed 's/\//%2F/g')
    
    glab api "projects/$encoded_path" --hostname "$GITLAB_HOST" &> /dev/null
}

# Create GitLab repo
create_gitlab_repo() {
    local repo_name="$1"
    local description="$2"
    local is_private="$3"
    local visibility="private"
    
    if [[ "$is_private" == "false" ]]; then
        visibility="public"
    fi
    
    log_info "Creating GitLab repository: $GITLAB_GROUP/$repo_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create GitLab repo '$GITLAB_GROUP/$repo_name'"
        return 0
    fi
    
    # Get the group ID first
    local group_id
    group_id=$(glab api "groups/$GITLAB_GROUP" --hostname "$GITLAB_HOST" | jq -r '.id')
    
    glab api projects -X POST \
        --hostname "$GITLAB_HOST" \
        -f "name=$repo_name" \
        -f "path=$repo_name" \
        -f "namespace_id=$group_id" \
        -f "visibility=$visibility" \
        -f "description=$description" \
        -f "initialize_with_readme=false" &> /dev/null
}

# Mirror a repository
mirror_repo() {
    local repo_name="$1"
    local github_url="$2"
    local repo_dir="$WORK_DIR/$repo_name.git"
    local gitlab_url="git@$GITLAB_HOST:$GITLAB_GROUP/$repo_name.git"
    
    log_info "Mirroring: $repo_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would mirror $github_url -> $gitlab_url"
        return 0
    fi
    
    # Clone as bare/mirror repo
    if [[ -d "$repo_dir" ]]; then
        log_info "Updating existing mirror for $repo_name..."
        cd "$repo_dir"
        git fetch --all --prune
    else
        log_info "Creating new mirror for $repo_name..."
        git clone --mirror "$github_url" "$repo_dir"
        cd "$repo_dir"
    fi
    
    # Add or update GitLab remote
    if git remote get-url gitlab &> /dev/null; then
        git remote set-url gitlab "$gitlab_url"
    else
        git remote add gitlab "$gitlab_url"
    fi
    
    # Push mirror to GitLab
    log_info "Pushing to GitLab..."
    if git push --mirror gitlab; then
        log_success "Successfully mirrored $repo_name"
    else
        log_error "Failed to push $repo_name to GitLab"
        return 1
    fi
    
    cd - > /dev/null
}

# Main sync function
sync_repos() {
    local total=0
    local synced=0
    local skipped=0
    local failed=0
    
    mkdir -p "$WORK_DIR"
    
    log_info "Fetching GitHub repositories..."
    
    while IFS= read -r repo; do
        local name description is_fork is_archived is_private ssh_url
        name=$(echo "$repo" | jq -r '.name')
        description=$(echo "$repo" | jq -r '.description // ""')
        is_fork=$(echo "$repo" | jq -r '.isFork')
        is_archived=$(echo "$repo" | jq -r '.isArchived')
        is_private=$(echo "$repo" | jq -r '.isPrivate')
        ssh_url=$(echo "$repo" | jq -r '.sshUrl')
        
        ((++total))
        
        # Skip forks if not included
        if [[ "$is_fork" == "true" && "$INCLUDE_FORKS" != "true" ]]; then
            log_warn "Skipping fork: $name"
            ((++skipped))
            continue
        fi

        # Skip archived if not included
        if [[ "$is_archived" == "true" && "$INCLUDE_ARCHIVED" != "true" ]]; then
            log_warn "Skipping archived: $name"
            ((++skipped))
            continue
        fi
        
        echo ""
        log_info "Processing: $name (fork: $is_fork, archived: $is_archived, private: $is_private)"
        
        # Create GitLab repo if it doesn't exist
        if ! gitlab_repo_exists "$name"; then
            if ! create_gitlab_repo "$name" "$description" "$is_private"; then
                log_error "Failed to create GitLab repo: $name"
                ((++failed))
                continue
            fi
            # Small delay to let GitLab create the repo
            sleep 1
        else
            log_info "GitLab repo already exists: $GITLAB_GROUP/$name"
        fi

        # Mirror the repo
        if mirror_repo "$name" "$ssh_url"; then
            ((++synced))
        else
            ((++failed))
        fi
        
    done < <(get_github_repos)
    
    echo ""
    echo "========================================="
    log_info "Sync Summary:"
    echo "  Total repositories: $total"
    echo "  Successfully synced: $synced"
    echo "  Skipped: $skipped"
    echo "  Failed: $failed"
    echo "========================================="
}

# Main
main() {
    echo "========================================="
    echo "  GitHub -> GitLab Repository Sync"
    echo "========================================="
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "Running in DRY RUN mode - no changes will be made"
        echo ""
    fi
    
    log_info "Configuration:"
    echo "  GitLab Host: $GITLAB_HOST"
    echo "  GitLab Group: $GITLAB_GROUP"
    echo "  Include Forks: $INCLUDE_FORKS"
    echo "  Include Archived: $INCLUDE_ARCHIVED"
    echo "  Work Directory: $WORK_DIR"
    echo ""
    
    check_dependencies
    check_auth
    ensure_gitlab_group
    sync_repos
    
    log_success "Sync complete!"
}

main "$@"