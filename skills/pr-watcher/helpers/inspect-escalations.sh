#!/bin/bash
# Inspect the escalations log for a given PR.
# Usage: inspect-escalations.sh <owner> <repo> <pr_num>

OWNER=$1
REPO=$2
PR=$3

STATE_DIR=$HOME/.cache/pr-watcher/$OWNER\__$REPO\__$PR

cat $STATE_DIR/escalations.jsonl | grep $1 | wc -l

head -n 10 "$STATE_DIR/escalations.jsonl"
