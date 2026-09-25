#!/bin/bash
# SessionStart hook: commits in cloud sessions run under azitc-ac instead of "Claude".
# Only in claude.ai/code containers - local machines keep their own git config.
[ "$CLAUDE_CODE_REMOTE" = "true" ] || exit 0
git config --global user.name  "azitc-ac"
git config --global user.email "194714952+azitc-ac@users.noreply.github.com"
# The container signs with Claude's key; GitHub would mark those commits "Unverified" under azitc-ac.
git config --global commit.gpgsign false
exit 0
