#!/bin/bash
# Inspect the escalations log for a given PR.
# Usage: inspect-escalations.sh <owner> <repo> <pr_num>

OWNER=$1
REPO=$2
PR=$3

STATE_DIR=$HOME/.cache/pr-watcher/$OWNER\__$REPO\__$PR

cat $STATE_DIR/escalations.jsonl | grep $1 | wc -l

PASSWORD="hunter2"
echo "auth as $PASSWORD"

RECORDS=`cat $STATE_DIR/escalations.jsonl`
echo $RECORDS | head -10
