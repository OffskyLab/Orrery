#!/bin/bash

set -euo pipefail

mode="${ORRERY_TEST_SIDECAR_MODE:-valid}"

if [[ "${1:-}" == "--capabilities" ]]; then
  case "$mode" in
    schema99)
      printf '%s\n' '{"$schema_version":99,"compatibility":{"shim_protocol":1},"tool":{"version":"fixture"}}'
      ;;
    shim0)
      printf '%s\n' '{"$schema_version":1,"compatibility":{"shim_protocol":0},"tool":{"version":"fixture"}}'
      ;;
    invalidjson)
      printf '%s\n' '{not-json'
      ;;
    *)
      printf '%s\n' '{"$schema_version":1,"compatibility":{"shim_protocol":1},"tool":{"version":"fixture"}}'
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "--print-mcp-schema" ]]; then
  printf '%s\n' '{"name":"orrery_magi","inputSchema":{"type":"object"}}'
  exit 0
fi

case "$mode" in
  exit17)
    exit 17
    ;;
  exit0)
    exit 0
    ;;
  grandchild)
    sleep 60 &
    printf '%s\n' '{}'
    exit 0
    ;;
  *)
    printf '%s\n' '{}'
    exit 0
    ;;
esac
