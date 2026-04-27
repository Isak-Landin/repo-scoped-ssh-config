# Repo-scoped SSH key without SSH config

Use a specific SSH key for one git repository - without touching your global `~/.ssh/config` or affecting any other repo.

## The problem

When you need a different SSH key for a specific repository (e.g. a deploy key, a work key, a personal key), the usual solution is to edit `~/.ssh/config`. That file is global, easy to get wrong, and affects every repo on your machine.

This script scopes the key to one repo only. No SSH config changes. No side effects elsewhere.

## Setup

1. Copy `setup-repo-git-key.sh` into your repository, or keep it anywhere on your machine.
2. Make it executable:
   ```sh
   chmod +x setup-repo-git-key.sh
   ```
3. Run it once, pointing it at your private key:
   ```sh
   ./setup-repo-git-key.sh --key ~/.ssh/your_private_key
   ```
   If the script is not inside the target repo, add `--repo /path/to/repo`:
   ```sh
   ./setup-repo-git-key.sh --key ~/.ssh/your_private_key --repo /path/to/repo
   ```

The script will install `direnv` automatically if it is not already installed (requires `apt-get`).

> Use the private key file, not the `.pub` file.

## Usage

After running the script once, you are done. Open a new terminal, `cd` into the repo, and all `git` commands in that directory automatically use the configured key - no extra steps.

```sh
cd /path/to/repo
git fetch   # uses your scoped key
git push    # uses your scoped key
```

Any other repo on your machine is unaffected.

## How it works

The script creates a `.envrc` file inside your repo that sets the `GIT_SSH_COMMAND` environment variable to use your chosen key. `direnv` loads this automatically whenever you enter the repo directory, and unloads it when you leave.

The `.envrc` file is excluded from git tracking via `.git/info/exclude`, so it stays local to your machine and is never committed or shared.
