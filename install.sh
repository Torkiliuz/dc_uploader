#!/bin/bash

print_help() {
    echo "Script usage: $(basename "$0") [OPTION]"
    echo "Optional arguments:"
    echo "-y: All user warning prompts will all be answered with \"y\"."
    echo
    echo "-d, --domain: Fully qualified domain name (e.g. hostname.domain.tld) you wish to use for the web app."\
         "If not provided, will use a self-signed certificate"
    echo
    echo "-v, --venv: Path where virtual environment is install to. Default: /opt/dcc-uploader"
    echo
    echo "-c, --cloudflare-token: Cloudflare API token to use for Cloudflare DNS challenge if you want to use"\
         "Cloudflare DNS challenege instead of HTTP challenge. If set, will automatically install certbot cloudflare"\
         "plugin. Only needed if using a \"real\" certificate"
    echo
    echo "-h, --help: Show this help page"
}

set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

certbot_cf() {
    TOKEN=CF
    if [ -f "/root/.secrets/cloudflare.ini" ]; then
        echo "Cloudflare credentials already exist, reusing existing credentials"
    else
        read -p "Cloudflare API token : " CF_TOKEN -r
        if [ -z "$CF_TOKEN" ]; then
            echo "No Cloudflare token supplied, cannot continue" >&2
            exit 1
        fi
        mkdir /root/.secrets/
        touch /root/.secrets/cloudflare.ini
        echo "dns_cloudflare_api_token = $CF_TOKEN" | tee /root/.secrets/cloudflare.ini
        chmod 0700 /root/.secrets/
        chmod 0600 /root/.secrets/cloudflare.ini
        echo "Cloudflare credentials created"
    fi
    echo "Installing certbot cloudflare plugin..."
    /opt/certbot/bin/pip install certbot-dns-cloudflare
    echo "Calling certbot for credentials using DNS challenge..."
    certbot certonly --agree-tos --register-unsafely-without-email --key-type ecdsa --elliptic-curve secp384r1 --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini -d "$SERVER_NAME"
}

handle_reply() {
    RPLY=$1
    NO_MSG=$2
    TO_ERROR=${3:-false}

    if [[ "$RPLY" =~ ^[Yy]$ ]]; then
        # Continue install, but echo once to make lines cleaner
        echo
        return 0
    elif [[ "$RPLY" =~ ^[Nn]$ ]]; then
        echo
        if $TO_ERROR; then
            echo "$NO_MSG" >&2
        else
            echo "$NO_MSG"
        fi
        return 1
    elif [ -z "$RPLY" ]; then
        if $TO_ERROR; then
            echo "$NO_MSG" >&2
        else
            echo "$NO_MSG"
        fi
        return 1
    else
        echo
        echo "Invalid input. Only y/n are accepted (case insensitive)" >&2
        exit 1
    fi
}

# Set default values if not provided
YES=false
ARGS_USED=false
USE_DOMAIN=false
VENV_PATH=/opt/dcc-uploader
SERVER_NAME=$(hostname -f)

if [ $# -ne 0 ]; then
    # Only bother parsing args if an arg beside path is specified
    if ! OPTS=$(getopt -o 'nhyd:v:c:' -l 'help,domain:,venv:,cloudflare-token:,no-ssl' -n "$(basename "$0")" -- "$@"); then
        echo "Failed to parse options" >&2
        print_help
        exit 1
    fi
    # Reset the positional parameters to the parsed options
    eval set -- "$OPTS"
    # Process arguments
    while true; do
        case "$1" in
            -y )
                YES=true
                shift
                ;;
            -d | --domain)
                SERVER_NAME="$2"
                ARGS_USED=true
                USE_DOMAIN=true
                shift 2
                ;;
            -v | --venv)
                VENV_PATH="$2"
                ARGS_USED=true
                shift 2
                ;;
            -c | --cloudflare-token)
                CF_TOKEN="$2"
                ARGS_USED=true
                shift 2
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
    exit 1
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ]; then
    echo "This program was only built for ubuntu, aborting install" >&2
    exit 1
fi

# Move to install.sh root directory
SCRIPT_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )

cd "$SCRIPT_PATH"

# Ask user if they want to use a domain or a self-signed certificate
if ! $ARGS_USED; then
    read -p "Enter the path for the python virtual environment [default: /opt/dcc-uploader] : " -r
    VENV_PATH=${REPLY:-/opt/dcc-uploader}

    read -p "Do you want to use a domain with Let's Encrypt? Defaults to self signed [y/n, default: n]: " -n 1 -r
    # Echo for newline
    if handle_reply "$REPLY" "Using self-signed certificate for server name: $SERVER_NAME" false; then
        # User chooses to use a domain
        echo "Info: If Let's Encrypt certificate for domain already exists, it will be imported instead of creating a new certificate"
        read -p "Enter the fully qualified domain name for the server for Let's Encrypt : "
        USE_DOMAIN=true
        SERVER_NAME=$REPLY
    else
        # User chooses to use a self-signed certificate
        USE_DOMAIN=false
    fi
fi

# Domain name validation if SSL is being used
if $USE_DOMAIN; then
    if [ -z "$SERVER_NAME" ]; then
        echo "No domain name provided." >&2
        exit 1
    elif ! echo "$SERVER_NAME" | grep -qP '(?=^.{4,253}$)(^((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63}$)'; then
        echo "Invalid domain name provided." >&2
        exit 1
    fi
fi

# Clean up the venv path
VENV_PATH=$(realpath -s "$VENV_PATH")

# Add the PPA repository if not already added
if ! [ -f /etc/apt/sources.list.d/wahibre-ubuntu-mtn-noble.sources ]; then
    echo "Movie thumbnailer repo not detected in apt source, adding"
    add-apt-repository -y ppa:wahibre/mtn
fi

# Update to ensure newest versions are installed (assuming not already installed)
apt-get update

# Required packages
echo "Installing required tools and their dependencies..."
apt-get install build-essential mtn mediainfo libfuse-dev screen software-properties-common autoconf -y

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

# Check if Python is installed, and install it if not
if ! command_exists python3; then
    echo "Python not found. Installing Python..."
    apt-get install python3 -y
fi

if ! dpkg -l python3-venv | grep -q "venv module"; then
    echo "Python venv package not found. Installing..."
    apt-get install python3-venv -y
fi

# Create venv
echo "Creating python virtaul environment..."
if [ -d "$VENV_PATH" ]; then
    if ! [ -f "$VENV_PATH/bin/python3" ]; then
        # Existing directory is NOT a virtual environment, aborting
        echo "Supplied virtual environment path conflicts with existing directory that is not a python virtual"\
             "environment, please select a different path for the virtual environment" >&2
        exit 1
    fi
    if ! $YES; then
        # Only ask for user warning confirmation if they didn't specify -y
        read -p "Warning: virtual environment already exists, continue? [y/n, default: n] : " -n 1 -r
        if ! handle_reply "$REPLY" "Aborting install" true; then
            exit 1
        fi
    fi
else
    # Make venv
    python3 -m venv "$VENV_PATH"
fi

# Install Python packages
echo "Installing Python packages in $VENV_PATH virtual environment..."
"$VENV_PATH/bin/pip3" install --upgrade pip
"$VENV_PATH/bin/pip3" install -r requirements.txt

# Write virtual env path to venv.path
echo "$VENV_PATH" | tee venv.path > /dev/null
# Ensure user scripts are executable
chmod +x start.sh
chmod +x shutdown.sh
chmod +x upload.sh

echo "Initiating polar bear attack (do you guys actually read these messages?)"

# Call the Python script with the function name as an argument
echo "Initializing databases..."
# Does not need virtual environment since it is touching stuff outside of virtual environment

if "$VENV_PATH/bin/python3" utils/database_utils.py initialize_all_databases; then
    echo "Databases created successfully."
else
    echo "Error occurred while creating databases." >&2
    exit 1
fi

# SSL setup
if $USE_DOMAIN; then
    # Install Certbot and configure SSL with Let's Encrypt
        echo "Uninstalling any certbot instances installed via apt"
        if ! $YES; then
            read -p "Ready to uninstall any certbot instances installed from apt? [y/n, default n] : " -n 1 -r
            if ! handle_reply "$REPLY" "User did not want to uninstall existing certbot, aborting" true; then
                exit 1
            fi
        fi
        #apt-get remove -y certbot
        #echo "Installing Certbot via pip..."
        #apt-get install -y libaugeas0
        #if ! [ -d "/opt/certbot" ]; then
        #    echo "Certbot virtual environment does not exist, creating now..."
        #    python3 -m venv /opt/certbot/
        #fi
        #/opt/certbot/bin/pip install --upgrade pip
        #/opt/certbot/bin/pip install certbot certbot-nginx
        #ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

    echo "Configuring SSL with Let's Encrypt..."
    SSL_CERT_PATH="/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$SERVER_NAME/privkey.pem"
    if [ -f "$SSL_CERT_PATH" ] && [ -f "$SSL_KEY_PATH" ]; then
        echo "Certificates already exist, existing certificates will be imported"
        echo "Calling certbot renew to ensure existing certificates are not expired"
        certbot renew -q
    else
        if ! $YES; then
            read -p "Would you like to use Cloudflare DNS challenge instead of the default HTTP challenge? [y/n, default n] : " -n 1 -r
            if handle_reply "$REPLY" "Calling certbot for credentials using HTTP challenge..." false; then
                # User answered yes
                echo
            else
                # User answered no, just call certbot.
                echo "Calling certbot for credentials using HTTP challenge..."
                certbot --nginx --agree-tos --register-unsafely-without-email --key-type ecdsa --elliptic-curve secp384r1 -d "$SERVER_NAME"
            fi
        else
            # If -y is selected, make decision on presence of CF token argument
            if [ -n "$CF_TOKEN" ]; then
                # User provided a CF token, use CF
                echo "CF"
            else
                # No CF token provided, use HTTP challenge
                echo "Calling certbot for credentials using HTTP challenge..."
                #certbot --nginx --agree-tos --register-unsafely-without-email --key-type ecdsa --elliptic-curve secp384r1 -d "$SERVER_NAME"
            fi
        fi
        exit 5
        if [[ $REPLY =~ ^[Yy]$ ]]; then

	    else
            echo
        fi
    fi

    # Update SSL paths in Flask app
    sed -i "s|ssl_cert_path = .*|ssl_cert_path = '$SSL_CERT_PATH'|" app.py
    sed -i "s|ssl_key_path = .*|ssl_key_path = '$SSL_KEY_PATH'|" app.py
    read -p "SSL setup completed using Let's Encrypt, set up automatic renewal and monthly certbot updates? [y/n] : " -r
    echo # Move to new line for cleaner look
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Adding automatic renewal and monthly certbot updates to /etc/crontab if they don't already exist"
        # Adds renewal to cron
        if ! cat /etc/crontab | grep -q "certbot renew -q"; then
            # At 12AM and 12PM every day. Will only renew certificates if eligible for automatic renewal
            echo "0 0,12 * * * root /opt/certbot/bin/python -c 'import random; import time; time.sleep(random.random() * 3600)' && sudo certbot renew -q" | tee -a /etc/crontab > /dev/null
        fi
        if ! cat /etc/crontab | grep -q "/opt/certbot/bin/pip install --upgrade certbot"; then
            # At 8am on the first day of the month
	        echo "0 8 1 * * root /opt/certbot/bin/pip install --upgrade certbot" | tee -a /etc/crontab > /dev/null
        fi
    else
        echo "Not setting up automatic renewal, please be mindful of certificate expiry, especially if this instance is exposed to the wide Internet"
    fi
else
    # Generate a self-signed certificate
    echo "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=$SERVER_NAME"

    # Move self-signed certificates to an appropriate directory (e.g., /etc/ssl)
    mv cert.pem /etc/ssl/certs/selfsigned_cert.pem
    mv key.pem /etc/ssl/private/selfsigned_key.pem

    # Update SSL paths in Flask app
    SSL_CERT_PATH="/etc/ssl/certs/selfsigned_cert.pem"
    SSL_KEY_PATH="/etc/ssl/private/selfsigned_key.pem"
    sed -i "s|ssl_cert_path = .*|ssl_cert_path = '$SSL_CERT_PATH'|" app.py
    sed -i "s|ssl_key_path = .*|ssl_key_path = '$SSL_KEY_PATH'|" app.py
    echo "SSL setup complete using a self-signed certificate."
fi

echo "Your Flask app will now run with HTTPS!"

# Update the config.ini file with user, password, and port
echo "Updating config.ini hostname..."
sed -i "s/^hostname = .*/hostname = $SERVER_NAME/" config.ini