# Updating Forged from upstream

Forged is a fork of `openai/codex`. This checkout uses `origin` for your fork
(`alifwr/forged`) and `upstream` for the original repository. Updating from
upstream brings the latest changes into Forged while retaining its own changes.

1. Open a terminal in the repository and check for uncommitted work:

   ```bash
   cd /home/alif/codex
   git status
   ```

   Commit or stash any work you want to keep before continuing.

2. Switch to your main branch and update it from your fork:

   ```bash
   git switch main
   git pull --ff-only origin main
   ```

3. Fetch the latest upstream changes and merge them:

   ```bash
   git fetch upstream
   git merge upstream/main
   ```

4. If Git reports conflicts, open each file listed by `git status`, resolve the
   conflict markers, and stage the resolved files. Then complete the merge:

   ```bash
   git status
   git add <resolved-file>
   git commit
   ```

   Repeat `git add` for each resolved file. To abandon an unfinished merge and
   return to the state before it, run `git merge --abort`.

5. Build and run relevant tests. For example:

   ```bash
   cd codex-rs
   cargo build --bin codex
   cargo test -p codex-tui
   cd ..
   ```

   Fix any failures before pushing. See [install.md](install.md) for the full
   development setup and additional test commands.

6. Push the updated branch to your fork:

   ```bash
   git push origin main
   ```

Updates are manual; repeat these steps when you want to incorporate new upstream
changes. Your redesign may need adjustments when upstream changes the same TUI
code.
