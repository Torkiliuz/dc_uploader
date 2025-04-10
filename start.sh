#!/bin/bash
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo" >&2
    exit 1
fi

SCRIPT_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" || exit ; pwd -P )

cd "$SCRIPT_PATH" || exit

if utils/config_validator.sh; then
    # Only start if config validator returns on fatal errors
    screen -dmS dcc-uploader "venv/bin/python3" app.py
fi