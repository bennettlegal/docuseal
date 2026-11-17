#!/usr/bin/env bash
# Restore reviewed ancestry in the disposable CI work copy only. A squash
# merge may discard parents, but this helper must never change source bytes.
restore_reviewed_history() {
  local ref=$1 expected=$2 before_tree actual
  git diff --quiet && git diff --cached --quiet || return 1
  git fetch --quiet --no-tags origin "$ref" || return 1
  actual=$(git rev-parse FETCH_HEAD) || return 1
  if [ "$actual" != "$expected" ]; then
    echo '::error::Reviewed history reference no longer matches its pinned commit'
    return 1
  fi
  if git merge-base --is-ancestor "$expected" HEAD; then return 0; fi
  before_tree=$(git rev-parse 'HEAD^{tree}') || return 1
  if ! git merge --no-ff --no-commit -m 'Restore reviewed upstream ancestry without source changes' "$expected" > /dev/null 2>&1; then
    git merge --abort || true
    return 1
  fi
  if [ "$(git write-tree)" != "$before_tree" ]; then
    git merge --abort
    echo '::error::Reviewed history would change the current source tree; refusing restoration'
    return 1
  fi
  git commit --quiet --no-edit
}
