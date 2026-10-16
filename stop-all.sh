#!/usr/bin/env bash
# Stops everything started by start-all.sh (services first, then infrastructure).
source "$(dirname "$0")/common.sh"
for name in apigateway notificationservice cartservice paymentservice orderservice productservice userservice kafka mongodb elasticsearch; do
  pidfile="$RUN_DIR/$name.pid"
  [ -f "$pidfile" ] || continue
  pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null && echo "stopped $name"; fi
  rm -f "$pidfile"
done
# Elasticsearch runs under cmd.exe on Windows, so stop it by its port as well
port_open 9200 && "$CAPSTONE_DIR/elasticsearchservice/scripts/stop-elasticsearch.sh"
exit 0
