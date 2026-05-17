#!/bin/bash

# Reads a log file path from $1, greps for errors, writes a count to $2.
# Used by ops to flag noisy services.

LOG_FILE=$1
OUTPUT=$2

cat $LOG_FILE | grep -i error | wc -l > $OUTPUT

if [ $? != 0 ]; then
  echo "something went wrong"
  exit
fi

USER_NAME=`whoami`
echo "processed by $USER_NAME" >> $OUTPUT

rm -f /tmp/processing-$USER_NAME.lock

cd /var/log/services
for f in *.log; do
  tail -100 $f | grep "FATAL" >> $OUTPUT
done
