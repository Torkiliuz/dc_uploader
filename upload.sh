#!/bin/bash

print_help() {
    echo "Script usage: $(basename "$0") \"/full/path/to/torrent/directory\" [OPTION]"
    echo "Full path must be in double quotes, as shown above"
    echo "Optional arguments:"
    echo "-l, --link: Hardlinks provided directory to DATADIR. If hardlink fails, fallback to symlink."
    echo
    echo "-c, --copy: Copies provided directory to DATADIR"
    echo
    echo "-m, --move: Moves provided directory to DATADIR"
    echo
    echo "-h, --help: Show this help page"
}

# Initial argument check
if [ $# -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    # No arguments provided or first argument was help, just print help
    print_help
    exit 0
fi

if [ $# -gt 2 ]; then
    echo "Too many arguments provided" >&2
    exit 1
fi

if ! [ -d "$1" ] && ! [ -f "$1" ]; then
    # Provided path does not resolve to an existing file or directory
    echo "Provided directory or file does not exist. Remember, the first argument MUST be the valid path of the data to be uploaded" >&2
    exit 1
fi

DATA_PATH=$1
LN=false
CP=false
MV=false

if [ $# -gt 1 ]; then
    # Only bother parsing args if an arg beside path is specified
    if ! OPTS=$(getopt -o 'hlcm' -l 'help,link,copy,move' -n "$(basename "$0")" -- "$@"); then
        echo "Failed to parse options" >&2
        print_help
        exit 1
    fi
    # Reset the positional parameters to the parsed options
    eval set -- "$OPTS"

    # Process arguments
    while true; do
        case "$1" in
            -l | --link)
                LN=true
                shift
                ;;
            -c | --copy)
                CP=true
                shift
                ;;
            -m | --move)
                MV=true
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
                echo "Unrecognized argument" >&2
                print_help
                exit 1
                ;;
        esac
    done
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo" >&2
    #exit 1
fi

SCRIPT_DATA_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" || exit ; pwd -P )

cd "$SCRIPT_DATA_PATH" || exit

# Run using venv
source "venv/bin/activate"

"python3" upload.py "$DATA_PATH"