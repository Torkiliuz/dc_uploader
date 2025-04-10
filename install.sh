#!/bin/bash

print_help() {
    echo "Script usage: $SCRIPT_NAME [OPTION]"
    echo
    echo "Optional arguments:"
    echo "    -d, --domain: Fully qualified domain name (e.g. hostname.domain.tld) you wish to use for the web app."
    echo
    echo "    -h, --help: Show this help page"
}

set -e

# Pretty colors
RED='\033[0;31m'
NCL='\033[0m'

# Set default values if not provided
HOSTNAME="$(hostname -f)"
FULL_SCRIPT_NAME="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${FULL_SCRIPT_NAME##*/}"

if [ $# -ne 0 ]; then
    # Only bother parsing args if an arg beside path is specified
    if ! OPTS=$(getopt -o 'hd:' -l 'help,domain:' -n "$SCRIPT_NAME" -- "$@"); then
        echo -e "${RED}ERROR: Failed to parse options. See --help.${NCL}" >&2
        exit 1
    fi
    # Reset the positional parameters to the parsed options
    eval set -- "$OPTS"
    # Process arguments
    while true; do
        case "$1" in
            -d | --domain)
                SERVER_NAME="$2"
                shift 2
                ;;
            -h | --help)
                print_help
                exit 0
                ;;
            --)
                shift
                # No domain provided, use a default
                SERVER_NAME=${SERVER_NAME:-"$HOSTNAME"}
                break
                ;;
            *)
                echo -e "${RED}Error: Unrecognized argument${NCL}" >&2
                print_help
                exit 1
                ;;
        esac
    done
fi


if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo.${NCL}" >&2
    exit 1
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ]; then
    echo -e "${RED}ERROR: This program was only built for ubuntu, aborting install.${NCL}" >&2
    exit 1
fi

# Move to install.sh root directory
SCRIPT_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )

cd "$SCRIPT_PATH"

if [ -z "$SERVER_NAME" ]; then
    # Initiate server name to hostname in case user selects N. Needed for handle_reply.
    read -p "Enter the fully qualified domain name for the self-signed certificate [default: hostname] : " -r
    SERVER_NAME=${REPLY:-"$HOSTNAME"}
fi

# Domain name validation if an actual domain is being used
if [ "$SERVER_NAME" != "$HOSTNAME" ]; then
    if ! echo "$SERVER_NAME" | grep -qP '(?=^.{4,253}$)(^((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63}$)'; then
        echo -e "${RED}Error: Invalid domain name provided${NCL}" >&2
        exit 1
    fi
fi

# Add the PPA repository if not already added
if ! [ -f /etc/apt/sources.list.d/wahibre-ubuntu-mtn-noble.sources ]; then
    apt-get update
    apt-get install -y software-properties-common
    echo "Movie thumbnailer repo not detected in apt source, adding"
    add-apt-repository -y ppa:wahibre/mtn
fi

# Update to ensure newest versions are installed (assuming not already installed)
apt-get update

# Required packages
echo "Installing required tools and their dependencies..."
apt-get install -y build-essential mtn mediainfo fuse3 libfuse-dev screen autoconf python3 python3-venv

# Install rar2fs
if [[ ! -f /usr/local/bin/rar2fs ]]; then
    echo "Installing rar2fs..."
    UNRAR_VER="7.1.6"
    RAR2FS_VER="1.29.7"
    WORKDIR="/tmp/rar2fs_installation"

    # Download rar2fs
    mkdir -p $WORKDIR
    cd $WORKDIR
    wget https://github.com/hasse69/rar2fs/archive/refs/tags/v$RAR2FS_VER.tar.gz
    tar zxvf v$RAR2FS_VER.tar.gz
    cd rar2fs-$RAR2FS_VER

    # Download unrar inside rar2fs directory
    wget http://www.rarlab.com/rar/unrarsrc-$UNRAR_VER.tar.gz
    tar zxvf unrarsrc-$UNRAR_VER.tar.gz
    cd unrar

    # Install unrar libraries, that's all rar2fs needs
    echo "Compiling unrar..."
    make --silent lib && echo "Unrar library compiled, installing..."
    make install-lib && echo "Unrar library installed successfully"

    # Back to rar2fs root directory
    cd ..

    # Install rar2fs
    echo "Compiling rar2fs..."
    autoreconf -f -i
    ./configure && make --silent && echo "rar2fs compiled successfully, installing..."
    make install && echo "rar2fs installed successfully"

    sed -i 's/#user_allow_other/user_allow_other/g' /etc/fuse.conf
    cd "$SCRIPT_PATH"
    rm -rf $WORKDIR
fi

# Create venv
python3 -m venv venv

# Install Python packages
echo "Installing Python packages in virtual environment..."
"venv/bin/pip3" install --upgrade pip
"venv/bin/pip3" install --upgrade -r requirements.txt

# Ensure scripts are executable
chmod +x start.sh
chmod +x shutdown.sh
chmod +x upload.sh
chmod +x utils/config_validator.sh

echo "Initiating polar bear attack (do you guys actually read these messages?)"

# Call the Python script with the function name as an argument
echo "Initializing databases..."
# Does not need virtual environment since it is touching stuff outside of virtual environment

if "venv/bin/python3" utils/database_utils.py initialize_all_databases; then
    echo "Databases created successfully."
else
    echo -e "${RED}Error: Couldn't initialize databases${NCL}" >&2
    exit 1
fi

# SSL setup
# Generate a self-signed certificate
echo "Generating self-signed certificate..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -keyout key.pem -out cert.pem -days 3650 -nodes \
-subj "/CN=$SERVER_NAME"

# Move self-signed certificates to an appropriate directory (e.g., /etc/ssl)
echo "Self-signed certificate generated, moving certificates to /etc/ssl from working directory"
mv cert.pem /etc/ssl/certs/selfsigned_cert.pem
mv key.pem /etc/ssl/private/selfsigned_key.pem

# Update SSL paths in Flask app
SSL_CERT_PATH="/etc/ssl/certs/selfsigned_cert.pem"
SSL_KEY_PATH="/etc/ssl/private/selfsigned_key.pem"
echo "Self-signed SSL certificate generation complete."

# Update SSL paths in Flask app
sed -i "s|ssl_cert_path = .*|ssl_cert_path = '$SSL_CERT_PATH'|" app.py
sed -i "s|ssl_key_path = .*|ssl_key_path = '$SSL_KEY_PATH'|" app.py
echo "Your Flask app will now run with HTTPS!"

# Update the config.ini file with user, password, and port
echo "Updating config.ini hostname..."
sed -i "s/^hostname = .*/hostname = $SERVER_NAME/" config.ini

echo "Setup complete. Start web server by executing start.sh, and make your first upload with upload.sh!"
echo "Web app can be shutdown with shutdown.sh"
echo -e "${RED}If you are exposing the web app to the wider Internet, update config.ini to a more secure" \
"username/password${NCL}"
echo "Note: web app does not need to be running to upload, its usage is entirely optional"