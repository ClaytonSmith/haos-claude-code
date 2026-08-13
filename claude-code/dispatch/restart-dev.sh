#!/bin/bash
# Restart house-dispatch in the foreground-less dev mode used while it is not yet
# baked into the add-on image. Once it ships in the Dockerfile, s6 owns it and
# this script is only for iterating.
#
# Deliberately NOT `pkill -f dispatchd.py`: the calling shell's own command line
# contains that string, so pkill kills the shell running it. Learned the hard way.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE=/tmp/dispatchd.pid

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && sleep 1
fi

cd "$DIR"
nohup python3 dispatchd.py > /tmp/dispatchd.log 2>&1 &
echo $! > "$PIDFILE"
sleep 2
curl -s -m 5 http://localhost:8097/health && echo || { echo "FAILED to start:"; tail -20 /tmp/dispatchd.log; exit 1; }
