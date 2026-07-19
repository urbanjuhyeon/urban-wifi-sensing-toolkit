#!/bin/sh
set -eu

exec /opt/urban-sensing/venv/bin/python -m urban_wifi_capture.cli "$@"
