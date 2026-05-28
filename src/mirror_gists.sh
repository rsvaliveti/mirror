#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Validation ---
if [[ -z "$GITHUB_USER" || -z "$GITHUB_TOKEN" || -z "$GITLAB_USER" || -z "$GITLAB_TOKEN" ]]; then
    echo "Error: Missing required environment variables."
    echo "Please ensure GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, and GITLAB_TOKEN are set."
    exit 1
fi

# Base API URLs
GITHUB_API="https://api.github.com"
GITLAB_API="https://gitlab.com/api/v4"

echo "Fetching all (public and secret) Gists for authenticated user..."

# --- Step 1: Fetch all GitHub Gists ---
# Hitting /gists directly ensures both public and secret gists are returned
GISTS=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "$GITHUB_API/gists?per_page=100")

# Check if the API returned an error or empty array
if echo "$GISTS" | jq -e '.message' > /dev/null 2>&1; then
    echo "GitHub API Error: $(echo "$GISTS" | jq -r '.message')"
    exit 1
fi

GIST_COUNT=$(echo "$GISTS" | jq '. | length')
echo "Found $GIST_COUNT Gists on GitHub."

if [ "$GIST_COUNT" -eq 0 ]; then
    echo "Nothing to mirror."
    exit 0
fi

# --- Step 2: Loop through each Gist ---
echo "$GISTS" | jq -c '.[]' | while read -r gist; do
    GIST_ID=$(echo "$gist" | jq -r '.id')
    DESCRIPTION=$(echo "$gist" | jq -r '.description // "Synced from GitHub Gist"')
    IS_PUBLIC=$(echo "$gist" | jq -r '.public')
    
    # Map GitHub visibility to GitLab visibility scope
    # GitHub: public (true/false) -> GitLab: public or private
    VISIBILITY="private"
    if [ "$IS_PUBLIC" = "true" ]; then
        VISIBILITY="public"
    fi

    # Get the primary/first filename to use as the snippet title if description is empty
    FIRST_FILE=$(echo "$gist" | jq -r '.files | keys[0]')
    TITLE="${DESCRIPTION}"
    if [ "$TITLE" = "null" ] || [ -z "$TITLE" ] || [ "$TITLE" = "Synced from GitHub Gist" ]; then
        TITLE="$FIRST_FILE"
    fi

    echo "--------------------------------------------------"
    echo "Processing Gist ID: $GIST_ID ($TITLE)"

    # --- Step 3: Construct GitLab Snippet Files payload ---
    # GitLab Snippets API requires an array of file objects: [{ file_path: "x", content: "y" }]
    FILES_JSON=$(echo "$gist" | jq -c '[.files[] | {file_path: .filename, content: .content}]')

    # If GitHub didn't return content inline (sometimes happens for large payloads), fetch raw content
    if echo "$FILES_JSON" | jq -e '.[] | select(.content == null)' > /dev/null 2>&1; then
        echo "Fetching raw content for files..."
        FILES_JSON="[]"
        
        # Reconstruct files payload by hitting raw_url
        while read -r file_info; do
            FILENAME=$(echo "$file_info" | jq -r '.filename')
            RAW_URL=$(echo "$file_info" | jq -r '.raw_url')
            CONTENT=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RAW_URL")
            
            # Append to our JSON array safely using jq
            FILES_JSON=$(echo "$FILES_JSON" | jq --arg name "$FILENAME" --arg ctx "$CONTENT" '. += [{file_path: $name, content: $ctx}]')
        done < <(echo "$gist" | jq -c '.files[]')
    fi

    # --- Step 4: Check if Snippet already exists on GitLab ---
    # Search existing snippets by title to avoid duplicates
    EXISTING_SNIPPETS=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API/snippets")
    SNIPPET_ID=$(echo "$EXISTING_SNIPPETS" | jq --arg title "$TITLE" '.[] | select(.title == $title) | .id')

    # --- Step 5: Create or Update the Snippet ---
    if [ -n "$SNIPPET_ID" ]; then
        echo "Found existing GitLab Snippet ID: $SNIPPET_ID. Updating..."
        
        # Build Update Payload
        PAYLOAD=$(jq -n \
          --arg title "$TITLE" \
          --arg desc "Synced from GitHub Gist $GIST_ID" \
          --arg vis "$VISIBILITY" \
          --argjson files "$FILES_JSON" \
          '{title: $title, description: $desc, visibility: $vis, files: $files}')

        RESPONSE=$(curl -s -X PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
          --header "Content-Type: application/json" \
          -d "$PAYLOAD" \
          "$GITLAB_API/snippets/$SNIPPET_ID")
          
        echo "Successfully updated."
    else
        echo "No existing snippet found. Creating new GitLab Snippet..."
        
        # Build Create Payload
        PAYLOAD=$(jq -n \
          --arg title "$TITLE" \
          --arg desc "Synced from GitHub Gist $GIST_ID" \
          --arg vis "$VISIBILITY" \
          --argjson files "$FILES_JSON" \
          '{title: $title, description: $desc, visibility: $vis, files: $files}')

        RESPONSE=$(curl -s -X POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
          --header "Content-Type: application/json" \
          -d "$PAYLOAD" \
          "$GITLAB_API/snippets")
          
        NEW_ID=$(echo "$RESPONSE" | jq -r '.id')
        echo "Successfully created Snippet ID: $NEW_ID"
    fi
done

echo "--------------------------------------------------"
echo "Mirroring complete!"