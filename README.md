# Mirror

# Introduction

This directories contains bash scripts to mirror the Github repos owned by me
to the corresponding gitlab repos. Here are the goals for these scripts:

- No dependence on gh/gitlab CLIs
- Depend on env variables: GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN. 
  No ssh keys assumed.
- Depend only on basic tools available in ubuntu: git/curl/wget/jq
- Be fast and efficient. That is, no unnecessary cloning and mirroring
- Should cover repos owned by a user, or forks initiated by the user
- Handle arbitary number of repositories, by utilizing appropriate paging mechanisms
- Should handle all branches present at the source repo. That is, it is not enough 
  to just compare the changes along the "main" or default branch
- The actions taken should depend on the comparison of the github & gitlab repos:
  * identical in all branches (same commits) - no action necessary
  * If the gitlab repo is behind (i.e. missing some commits) push the missing 
    commits and files. 
  * If the github and gitlab repos have diverged, support a force option 
    to completely overwrite the old gitlab repo
  * if the gitlab repo doesn't exist, create it as a copy of the corresponding github repo
- Support a dry-run option -- which will show the operations that will be executed
- [Optional] Copy the issues list from github repos to the corresponding gitlab repos.
  Copy the state of the repos (i.e. open/close)
- Handle all possible errors and generate detailed error messages to help with debugging.


# Directory Structure

- `src/` contains a few versions of the scripts. The README.md file in this directory contains the comparison, examples of use, etc. 
- `README.md`: this file
