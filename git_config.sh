#!/usr/bin/env bash
# One-time dev-machine setup: commit identity + dual-push remotes.
# GitHub is the source of truth (dev, CI); GitLab is the IPv6 mirror the
# fleet clones from. A single `git push` updates both.
set -euo pipefail

git config --global user.name "cschlick"
git config --global user.email "16112328+cschlick@users.noreply.github.com"

# Fetch from GitHub; push atomically to GitHub AND the GitLab mirror.
# (Setting any explicit push URL disables the implicit fetch-URL push,
# so BOTH must be added. Idempotent: clear existing push URLs first.)
git remote set-url origin git@github.com:cschlick/postinstall.git
git config --unset-all remote.origin.pushurl || true
git remote set-url --add --push origin git@github.com:cschlick/postinstall.git
git remote set-url --add --push origin git@gitlab.com:cschlick/postinstall.git

git remote -v
