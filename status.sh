#!/usr/bin/env bash
# Shows which platform components are listening.
source "$(dirname "$0")/common.sh"
check() { if port_open "$2"; then printf "  %-20s :%-6s UP\n" "$1" "$2"; else printf "  %-20s :%-6s down\n" "$1" "$2"; fi; }
check mongodb 27017; check kafka 9092; check elasticsearch 9200
for svc in "${SERVICES[@]}"; do check "$svc" "${PORTS[$svc]}"; done
