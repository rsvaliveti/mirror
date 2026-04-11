#!/usr/bin/env bash

#set -euo pipefail

########################################
# Configuration
########################################

GITHUB_USER="${GITHUB_USER:-rsvaliveti}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-rsvaliveti}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

echo $GITHUB_USER , $GITLAB_NAMESPACE

DRY_RUN=false
FORCE=false

########################################
# Args
########################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        *)
            echo "Unknown argument: $1"
            exit 1
        ;;
    esac
    shift
done

########################################
# Helpers
########################################

log() {
    echo "[INFO] $*"
}

run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

########################################
# Fetch GitHub repos
########################################

log "Fetching GitHub repos"

gh_repos=$(curl -s \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/user/repos?per_page=200" \
    | jq -r '.[].name')

########################################
# Fetch GitLab repos
########################################

log "Fetching GitLab repos"

gl_repos=$(curl -s \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.com/api/v4/projects?membership=true&per_page=200" \
    | jq -r '.[].path')

########################################
# Compare helper
########################################

get_default_branch() {
    git ls-remote --symref "$1" HEAD 2>/dev/null \
        | awk '/^ref:/ {print $2}' \
        | sed 's@refs/heads/@@'
}

compare_repos() {

    gh_url="$1"
    gl_url="$2"

    gh_branch=$(get_default_branch "$gh_url")
    gl_branch=$(get_default_branch "$gl_url")

    gh_head=$(git ls-remote "$gh_url" "refs/heads/$gh_branch" | awk '{print $1}')
    gl_head=$(git ls-remote "$gl_url" "refs/heads/$gl_branch" | awk '{print $1}')

    if [[ "$gh_head" == "$gl_head" ]]; then
        echo "identical"
        return
    fi

    tmp=$(mktemp -d)

    git -C "$tmp" init -q
    git -C "$tmp" remote add gh "$gh_url"
    git -C "$tmp" remote add gl "$gl_url"

    git -C "$tmp" fetch -q gh "$gh_branch"
    git -C "$tmp" fetch -q gl "$gl_branch"

    read gl_only gh_only < <(
        git -C "$tmp" rev-list --left-right --count \
        gl/"$gl_branch"...gh/"$gh_branch"
    )

    rm -rf "$tmp"

    if [[ "$gl_only" == "0" ]]; then
        echo "behind"
    elif [[ "$gh_only" == "0" ]]; then
        echo "ahead"
    else
        echo "diverged"
    fi
}

########################################
# Mirror repo
########################################

mirror_repo() {

    repo="$1"

    gh_url="https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$repo.git"
    gl_url="https://oauth2:$GITLAB_TOKEN@gitlab.com/$GITLAB_NAMESPACE/$repo.git"

    log "Checking $repo"

    if ! echo "$gl_repos" | grep -qx "$repo"; then
        log "Creating GitLab repo $repo"

        run curl -s \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --data "name=$repo&visibility=private" \
            https://gitlab.com/api/v4/projects >/dev/null

        state="missing"
    else
        state=$(compare_repos "$gh_url" "$gl_url")
    fi

    case "$state" in

        identical)
            log "$repo already synced"
            return
        ;;

        behind)
            log "$repo GitLab behind → pushing"
        ;;

        ahead)
            log "$repo GitLab ahead → skipping"
            return
        ;;

        diverged)
            if ! $FORCE; then
                log "$repo diverged → skipping (use --force)"
                return
            fi
            log "$repo diverged → force mirror"
        ;;

        missing)
            log "$repo missing → mirror"
        ;;
    esac

    tmp=$(mktemp -d)

    run git clone --mirror "$gh_url" "$tmp"

    if $FORCE; then
        run git -C "$tmp" push --mirror --force "$gl_url"
    else
        run git -C "$tmp" push --mirror "$gl_url"
    fi

    rm -rf "$tmp"

    log "$repo mirrored"
}

########################################
# Main
########################################

for repo in $gh_repos; do
    mirror_repo "$repo"
done

log "Done"

