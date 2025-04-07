#!/bin/bash
SCRIPT_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" || exit ; pwd -P )

cd "$SCRIPT_PATH" || exit

VENV_PATH=$(head -n 1 venv.path)

screen -dmS dcc-uploader "$VENV_PATH/bin/python3" app.py