#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# but we will handle git/curl errors manually where necessary.
set -eo pipefail

# --- Configuration & Validation ---

# Ensure required environment variables are set
if [[ -z "$GITHUB_USER" || -z "$GITHUB_TOKEN" || -z "$GITLAB_USER" || -z "$GITLAB_TOKEN" ]]; then
    echo "Error: Missing required environment variables." >&2
    echo "Please set: GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN" >&2
    exit 1
fi

# Parse command-line arguments
DRY_RUN=false
FORCE_PUSH=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE_PUSH=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN MODE ENABLED (No changes will be made) ==="
fi

# Temporary directory *only* used if a sync is actually needed
WORK_DIR=$(mktemp -d -t git-mirror-XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Helper Functions ---

log_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
log_err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }

# Check if a GitLab repo exists, create it if it doesn't
ensure_gitlab_repo() {
    local repo_name="$1"
    
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $GITLAB_TOKEN" \
        "https://gitlab.com/api/v4/projects/${GITLAB_USER}%2F${repo_name}")

    if [ "$status_code" -eq 200 ]; then
        return 0
    elif [ "$status_code" -eq 404 ]; then
        if [ "$DRY_RUN" = true ]; then
            log_info "Dry-run: Would create non-existent GitLab repository: $repo_name"
            return 1 # Treat as missing/needs sync
        fi

        log_warn "GitLab repository '$repo_name' not found. Creating it..."
        
        local create_response
        create_response=$(curl -s -X POST \
            -H "Authorization: Bearer $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"$repo_name\", \"visibility\": \"private\"}" \
            "https://gitlab.com/api/v4/projects")

        if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
            log_info "Successfully created GitLab repository: $repo_name"
            return 0
        else
            local err_msg
            err_msg=$(echo "$create_response" | jq -r '.message // "Unknown error"')
            log_err "Failed to create GitLab repository '$repo_name': $err_msg"
            return 1
        fi
    else
        log_err "Unexpected API response ($status_code) while checking GitLab repo '$repo_name'."
        return 1
    fi
}

# Fetch all issues from GitHub and migrate missing ones to GitLab
sync_issues() {
    local repo_name="$1"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry-run: Scanning issue configurations for $repo_name..."
        return 0
    fi

    # Fetch existing issues on GitLab to avoid double creation (Idempotency)
    # Project path must be URL encoded (e.g., username%2Freponame)
    local encoded_project="${GITLAB_USER}%2F${repo_name}"
    local gitlab_issues
    gitlab_issues=$(curl -s -H "Authorization: Bearer $GITLAB_TOKEN" \
        "https://gitlab.com/api/v4/projects/${encoded_project}/issues?per_page=100")

    local issue_page=1
    while true; do
        # Fetch both open and closed issues from GitHub
        local github_issues_json
        github_issues_json=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/${GITHUB_USER}/${repo_name}/issues?state=all&page=${issue_page}&per_page=100")

        # Break if payload is empty, invalid, or hits pull requests exclusively 
        # (GitHub API bundles PRs inside the issues endpoint; we filter them out)
        if ! echo "$github_issues_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
            break
        fi
        
        local issues_count
        issues_count=$(echo "$github_issues_json" | jq '. | length')
        if [ "$issues_count" -eq 0 ]; then
            break
        fi

        # Process each individual GitHub issue
        while read -r issue_idx; do
            # Extract key properties safely using jq
            local is_pr
            is_pr=$(echo "$github_issues_json" | jq -r ".[$issue_idx].pull_request // empty")
            if [ -n "$is_pr" ]; then continue; fi # Skip actual PR blocks

            local gh_num gh_title gh_body gh_state
            gh_num=$(echo "$github_issues_json" | jq -r ".[$issue_idx].number")
            gh_title=$(echo "$github_issues_json" | jq -r ".[$issue_idx].title")
            gh_body=$(echo "$github_issues_json" | jq -r ".[$issue_idx].body // \"\"")
            gh_state=$(echo "$github_issues_json" | jq -r ".[$issue_idx].state")

            # Unique tracking signature title
            local target_title="[GitHub Sync] Issue #${gh_num}: ${gh_title}"

            # Check if this tracking signature already exists on GitLab
            local match_check
            match_check=$(echo "$gitlab_issues" | jq --arg t "$target_title" '.[] | select(.title == $t) | .id' 2>/dev/null || true)

            if [ -z "$match_check" ]; then
                log_info "  Syncing Issue #${gh_num} -> GitLab..."
                
                # Append original reference context to the top of the body text
                local modified_body="*Original GitHub Reference: Issue #${gh_num}*\n\n${gh_body}"

                # Generate JSON payload using jq variables to handle special characters safely
                local post_payload
                post_payload=$(jq -n \
                    --arg title "$target_title" \
                    --arg desc "$modified_body" \
                    '{title: $title, description: $desc}')

                # Push issue creation to GitLab
                local gl_create_resp
                gl_create_resp=$(curl -s -X POST \
                    -H "Authorization: Bearer $GITLAB_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "$post_payload" \
                    "https://gitlab.com/api/v4/projects/${encoded_project}/issues")

                # If the issue was closed on GitHub, update its status on GitLab immediately
                if [ "$gh_state" = "closed" ]; then
                    local gl_issue_iid
                    gl_issue_iid=$(echo "$gl_create_resp" | jq -r '.iid // empty')
                    if [ -n "$gl_issue_iid" ]; then
                        curl -s -X PUT \
                            -H "Authorization: Bearer $GITLAB_TOKEN" \
                            -H "Content-Type: application/json" \
                            -d '{"state_event": "close"}' \
                            "https://gitlab.com/api/v4/projects/${encoded_project}/issues/${gl_issue_iid}" > /dev/null
                    fi
                fi
            fi
        done < <(echo "$github_issues_json" | jq -r 'keys[]')

        ((issue_page++))
    done
}

# --- Main Logic ---

page=1
per_page=100

log_info "Fetching GitHub repositories for user: $GITHUB_USER..."

while true; do
    github_repos_json=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/user/repos?type=owner&page=$page&per_page=$per_page")

    if ! echo "$github_repos_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_err "Failed to fetch repositories from GitHub or invalid token."
        exit 1
    fi

    repo_count=$(echo "$github_repos_json" | jq '. | length')
    if [ "$repo_count" -eq 0 ]; then
        break
    fi

    while read -r repo_name; do
        if [ -z "$repo_name" ]; then continue; fi
        
        echo "--------------------------------------------------"
        log_info "Processing repository: $repo_name"

        github_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${repo_name}.git"
        gitlab_url="https://oauth2:${GITLAB_TOKEN}@gitlab.com/${GITLAB_USER}/${repo_name}.git"

        # 1. Ensure GitLab destination exists
        gitlab_exists=true
        if ! ensure_gitlab_repo "$repo_name"; then
            gitlab_exists=false
            if [ "$DRY_RUN" = false ]; then
                log_err "Skipping $repo_name due to GitLab setup failure."
                continue
            fi
        fi

        # 2. Sync issues metadata using API pipelines
        sync_issues "$repo_name"

        # 3. Remote-scan GitHub references (No Clone!)
        github_refs=$(git ls-remote --heads "$github_url" 2>/dev/null)
        if [ -z "$github_refs" ]; then
            log_warn "GitHub repository seems empty or inaccessible. Skipping code sync."
            continue
        fi

        # 4. Remote-scan GitLab references (No Clone!)
        gitlab_refs=""
        if [ "$gitlab_exists" = true ]; then
            gitlab_refs=$(git ls-remote --heads "$gitlab_url" 2>/dev/null || echo "")
        fi

        # 5. Compare references purely in-memory
        needs_push=false
        force_required=false
        
        # Temporary file to map out GitLab refs for quick lookup
        gitlab_map_file=$(mktemp)
        echo "$gitlab_refs" > "$gitlab_map_file"

        while read -r gh_sha gh_ref; do
            if [ -z "$gh_ref" ]; then continue; fi

            # Find matching branch ref in the GitLab reference mapping
            gl_sha=$(awk -v ref="$gh_ref" '$2 == ref {print $1}' "$gitlab_map_file")

            if [ -z "$gl_sha" ]; then
                log_info "  Branch [${gh_ref#refs/heads/}]: Missing on GitLab."
                needs_push=true
            elif [ "$gh_sha" != "$gl_sha" ]; then
                log_info "  Branch [${gh_ref#refs/heads/}]: Out of sync (GitHub: ${gh_sha:0:7}, GitLab: ${gl_sha:0:7})."
                needs_push=true
            fi
        done < <(echo "$github_refs")
        
        rm -f "$gitlab_map_file"

        # 6. Only clone if code tracking changes are absolutely required
        if [ "$needs_push" = false ]; then
            log_info "Result: Repository codebase is completely up-to-date. (Skipped Cloning)"
        else
            log_info "Changes detected. Proceeding to clone and resolve histories..."
            
            repo_dir="$WORK_DIR/$repo_name"
            if ! git clone --bare "$github_url" "$repo_dir" 2>/dev/null; then
                log_err "Failed to clone GitHub repository: $repo_name"
                continue
            fi

            cd "$repo_dir"
            git remote add gitlab "$gitlab_url"

            # Fetch GitLab to determine if history has diverged or is just behind
            if [ "$gitlab_exists" = true ] && [ "$DRY_RUN" = false ]; then
                git fetch gitlab --prune 2>/dev/null || true
                
                # Double-check if a forced push is necessary
                branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
                for branch in $branches; do
                    local_sha=$(git rev-parse "$branch")
                    remote_sha=$(git rev-parse "refs/remotes/gitlab/$branch" 2>/dev/null || echo "MISSING")
                    
                    if [ "$remote_sha" != "MISSING" ] && [ "$local_sha" != "$remote_sha" ]; then
                        if ! git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
                            log_warn "  Branch [$branch]: History has diverged!"
                            force_required=true
                        fi
                    fi
                done
            fi

            # Execution logic
            if [ "$force_required" = true ] && [ "$FORCE_PUSH" = false ]; then
                log_err "Result: Push rejected due to diverged history. Use --force to overwrite."
            else
                push_cmd="git push gitlab --all"
                if [ "$FORCE_PUSH" = true ] && [ "$force_required" = true ]; then
                    push_cmd="git push gitlab --all --force"
                fi

                if [ "$DRY_RUN" = true ]; then
                    log_info "Dry-run: Would execute '$push_cmd' and 'git push gitlab --tags'"
                else
                    if eval "$push_cmd" && git push gitlab --tags; then
                        log_info "Result: Successfully mirrored changes."
                    else
                        log_err "Result: Git push failed."
                    fi
                fi
            fi

            # Cleanup clone workspace immediately
            cd "$WORK_DIR"
            rm -rf "$repo_dir"
        fi

    done < <(echo "$github_repos_json" | jq -r '.[].name')

    ((page++))
done

log_info "=================================================="
log_info "Mirror sync process complete."
