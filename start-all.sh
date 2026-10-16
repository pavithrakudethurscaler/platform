#!/usr/bin/env bash
# Starts the whole ecom platform in the background: MongoDB, Kafka, Elasticsearch, then the seven services.
#   ./start-all.sh            start (builds any service whose jar is missing)
#   ./start-all.sh --build    rebuild every service first
# Logs: platform/logs/<name>.log   Stop: ./stop-all.sh   Check: ./status.sh   Test: ./e2e-test.sh
set -uo pipefail
source "$(dirname "$0")/common.sh"
BUILD_ALL=false; [ "${1:-}" = "--build" ] && BUILD_ALL=true

start_bg() { # name command...
  local name=$1; shift
  if [ -f "$RUN_DIR/$name.pid" ] && kill -0 "$(cat "$RUN_DIR/$name.pid")" 2>/dev/null; then
    echo "  $name already running"; return 0
  fi
  "$@" > "$LOG_DIR/$name.log" 2>&1 &
  echo $! > "$RUN_DIR/$name.pid"
}

echo "== Infrastructure"
if port_open 27017; then echo "  mongodb already running"
else start_bg mongodb "$CAPSTONE_DIR/tools/start-mongodb.sh" --quiet; wait_port mongodb 27017 60 && echo "  mongodb      :27017"; fi
if port_open 9092; then echo "  kafka already running"
else start_bg kafka "$CAPSTONE_DIR/kafkaservice/scripts/start-kafka.sh"; wait_port kafka 9092 90 && echo "  kafka        :9092"; fi
if [ -d "$CAPSTONE_DIR/elasticsearchservice/elasticsearch/bin" ]; then
  if port_open 9200; then echo "  elasticsearch already running"
  else start_bg elasticsearch "$CAPSTONE_DIR/elasticsearchservice/scripts/start-elasticsearch.sh"; wait_port elasticsearch 9200 180 && echo "  elasticsearch :9200"; fi
else
  echo "  elasticsearch not installed (search will use the database); run elasticsearchservice/scripts/setup-elasticsearch.sh"
fi

echo "== Services"
for svc in "${SERVICES[@]}"; do
  jar="$CAPSTONE_DIR/$svc/build/libs/$svc-0.0.1-SNAPSHOT.jar"
  if $BUILD_ALL || [ ! -f "$jar" ]; then
    echo "  building $svc..."
    (cd "$CAPSTONE_DIR/$svc" && ./gradlew bootJar --no-daemon -q) || { echo "  !! build failed for $svc"; exit 1; }
  fi
  start_bg "$svc" "$JAVA" -jar "$jar"
  # User Service must be up before the others validate tokens against it
  [ "$svc" = userservice ] && wait_port userservice 8082 90 >/dev/null
done
ok=true
for svc in "${SERVICES[@]}"; do
  if wait_port "$svc" "${PORTS[$svc]}" 120; then printf "  %-20s :%s\n" "$svc" "${PORTS[$svc]}"; else ok=false; fi
done

echo
if $ok; then
  echo "Platform is up. API: http://localhost:8000/api/v1/...   Admin email: $ADMIN_EMAILS"
  echo "Run ./e2e-test.sh to check a full purchase end to end."
else
  echo "Some components did not start; check $LOG_DIR"; exit 1
fi
