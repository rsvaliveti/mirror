# Mirror

# Introduction

This directories contains bash scripts to mirror the Github repos owned by me
to the corresponding gitlab repos. Here are the goals for these scripts:

- No dependence on gh/lab CLIs
- Depend on env variables: GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN. 
  No ssh keys assumed.
- Depend only on basic tools available in ubuntu: git/curl/wget/jq
- Be fast and efficient. That is, no unnecessary cloning and mirroring
- should cover repos owned by a user, or forks initiated by the user
- The actions taken should depend on the comparison of the github & gitlab repos:
  * identical (same head) - no action necessary
  * If the gitlab repo is behind (i.e. missing some commits) push the missing 
    commits and files. 
  * If the github and gitlab repos have diverged, support a force option 
    to completely overwrite the old gitlab repo
  * if the gitlab doesn't exist, create it as a copy of the corresponding github repo
- Support a dry-run option -- which will show the operations that will be executed

# Directory Structure

- `src` contains various versions of the scripts. There are perhaps minor differences 
   between these scripts.  Someday, I will go through these differences and consolidate 
   them into one "final" (or last version) which I will maintain. Until I get a chance 
   to do this examination, these separate versions will stay. 
- `README.md`: this file

