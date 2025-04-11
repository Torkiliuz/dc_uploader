#!/bin/bash

print_help() {
    echo "Script usage: $SCRIPT_NAME [QUEUE FILE] [OPTION]"
    echo "Queue file can either be a full absolute path or a relative path relative to $SCRIPT_NAME. e.g." \
    "$SCRIPT_NAME some_queue_file.txt [OPTION] if queue file is located in the same folder as $SCRIPT_NAME"
    echo
    echo "Required argument. Pick one:"
    echo "    -l, --ln: Hardlinks provided directory to DATADIR. If hardlink fails, fallback to symlink."
    echo
    echo "    -c, --cp: Copies provided directory to DATADIR."
    echo
    echo "    -m, --mv: Moves provided directory to DATADIR. May break other torrents that rely on the same data," \
    "use with caution."
    echo
    echo "    -h, --help: Show this help page."
}

SCRIPT_DATA_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" || exit ; pwd -P )

cd "$SCRIPT_DATA_PATH" || exit

# # Only continue if config validator returns on fatal errors
if ! utils/config_validator.sh; then
    exit 1
fi

# Pretty colors
RED='\033[0;31m'
YLW='\033[1;33m'
NCL='\033[0m'

DATA_DIR="$(awk -F '=' '/^DATADIR[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' config.ini)"
# In case user put in a trailing forward slash to DATADIR
DATA_DIR=$(realpath -s "$DATA_DIR")
QUEUE_FILE="$1"
FULL_SCRIPT_NAME="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${FULL_SCRIPT_NAME##*/}"

# Initial argument check
if [ $# -eq 0 ] || [[ "$QUEUE_FILE" == "--help" ]] || [[ "$QUEUE_FILE" == "-h" ]]; then
    # No arguments provided or first argument was help, just print help
    print_help
    exit 0
fi

if [ $# -lt 2 ]; then
    echo -e "${RED}ERROR: Not enough arguments provided${NCL}" >&2
    exit 1
fi

if [ $# -gt 2 ]; then
    echo -e "${RED}ERROR: Too many args.${NCL}" >&2
    exit 1
fi

VALID_ARGS=("-h" "--help" "-l" "--ln" "-c" "--cp" "-m" "--mv")
FOUND=false

for item in "${VALID_ARGS[@]}"; do
    if [[ "$item" == "$2" ]]; then
        FOUND=true
        break
    fi
done
if ! $FOUND; then
    echo -e "${RED}Error: Unrecognized argument: $2${NCL}" >&2
    exit 1
fi

# Store arg so it's not lost after getopt
ARG="$2"

if ! OPTS=$(getopt -o 'hlcm' -l 'help,ln,cp,mv' -n "$SCRIPT_NAME" -- "$@"); then
    echo -e "${RED}ERROR: Failed to parse options. See --help.${NCL}" >&2
    exit 1
fi
# Reset the positional parameters to the parsed options
eval set -- "$OPTS"

# Process arguments
while true; do
    case "$1" in
        -l | --ln)
            shift
            ;;
        -c | --cp)
            shift
            ;;
        -m | --mv)
            shift
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo -e "${RED}ERROR: Unrecognized argument${NCL}" >&2
            exit 1
            ;;
    esac
done

eval set -- "$OPTS"
QUEUE_FILE=$(realpath -s "$QUEUE_FILE")
if ! [ -f "$QUEUE_FILE" ]; then
    # It's a file. Error.
    echo -e "${RED}ERROR: $QUEUE_FILE does not exist${NCL}" >&2
    exit 1
fi

# Remove old log file
LOG_PATH="files/queue_upload.log"
if [ -f "$LOG_PATH" ]; then
    rm "$LOG_PATH"
fi

while IFS= read -r LINE; do
    if ./upload.sh "$LINE" "$ARG"; then
        echo "Successfully uploaded: $(basename "$LINE")" >> "$LOG_PATH"
    else
        echo "Error when uploading: $(basename "$LINE")" >> "$LOG_PATH"
    fi
done < "$QUEUE_FILE"