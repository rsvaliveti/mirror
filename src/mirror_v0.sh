#!/bin/bash
# file: mirror_all.sh
# description
# - mirrors all github repos to gitlab
# assumptions:
# - GITHUB_{USER|TOKEN}, GITLAB_{USER|TOKEN}: are accessibile as environment variables
# - the github/gitlab credentials are stored in the credential helper
#

# Check that the (env) vars are set
REQUIRED_VARS=("GITHUB_USER" "GITHUB_TOKEN" "GITLAB_USER" "GITLAB_TOKEN")
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "$VAR is not set"
    exit 1
  fi
done

# Get all GitHub repos
repos=$(curl -s -u "$GITHUB_USER:$GITHUB_TOKEN" \
  "https://api.github.com/user/repos?type=owner&per_page=100" | jq -r '.[].name')

for repo in $repos; do
  echo "Processing $repo..."

  # Check if repo exists on GitLab
  gitlab_repo=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.com/api/v4/projects/$GITLAB_USER%2F$repo")
  gitlab_repo_id=$(echo "$gitlab_repo" | jq -r '.id')

  # Create repo on GitLab if it doesn't exist
  if [[ "$gitlab_repo_id" == "null" ]]; then
    echo "Creating $repo on GitLab..."
    curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      -X POST "https://gitlab.com/api/v4/projects" \
      --data "name=$repo&namespace_id=$GITLAB_GROUP_ID"
    # Wait for GitLab to process
    sleep 2
  fi

  # Get latest commit SHA on GitHub (default branch)
  response=$(curl -s -u "$GITHUB_USER:$GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_USER/$repo/commits?per_page=1")
  if echo "$response" | jq -e 'type == "array"' >/dev/null; then
    github_sha=$(echo "$response" | jq -r '.[0].sha')
  else
    echo "Unexpected response: $response"
    continue
  fi
 
  # Get latest commit SHA on GitLab (default branch)
  response=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.com/api/v4/projects/$GITLAB_USER%2F$repo/repository/commits?per_page=1")
  if echo "$response" | jq -e 'type == "array"' >/dev/null; then
    gitlab_sha=$(echo "$response" | jq -r '.[0].id')
  else
    echo "Unexpected response: $response"
    continue
  fi

  # Mirror if GitHub is ahead (different SHA)
  if [[ "$github_sha" != "$gitlab_sha" ]]; then
    echo "Mirroring $repo from GitHub to GitLab..."
    git clone --mirror "https://github.com/$GITHUB_USER/$repo.git"
    cd "$repo.git"
    git remote add gitlab "https://oauth2:$GITLAB_TOKEN@gitlab.com/$GITLAB_USER/$repo.git"
    git push --mirror gitlab
    cd ..
    rm -rf "$repo.git"
  else
    echo "$repo is up-to-date. Skipping."
  fi
done
