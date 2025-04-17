import json
import os

import requests
from guessit import guessit

from utils.bcolors import bcolors
from utils.config_loader import ConfigLoader
from utils.logging_utils import log_to_file

# Load configuration
config = ConfigLoader().get_config()
TMP_DIR = os.path.join(config.get('Paths', 'TMP_DIR'), str(os.getpid()))

# Ensure TMP_DIR exists
os.makedirs(TMP_DIR, exist_ok=True)


def similar(uploading, existing):
    """
    Calculate the Jaccard similarity between two dictionaries.

    For dictionaries, similarity is based on key-value pairs that match.
    J(A,B) = |A ∩ B| / |A ∪ B| where intersection and union operate on key-value pairs.

    Args:
        uploading (dict): First dictionary
        existing (dict): Second dictionary

    Returns:
        float: Similarity score between 0 and 1
    """
    # Get all keys
    keys1 = set(uploading.keys())
    keys2 = set(existing.keys())

    # Find common keys
    common_keys = keys1.intersection(keys2)

    # Count matching key-value pairs
    matches = sum(1 for k in common_keys if uploading[k] == existing[k])

    # Total unique keys (the union)
    total_keys = len(keys1.union(keys2))

    # Prevent division by zero
    if total_keys == 0:
        return 0

    return matches / total_keys

def check_and_download_dupe(release_name, cookies):
    """Check for duplicate torrent and download it if found, based on configuration."""
    dupe_check_flag = config.getboolean('Settings', 'DUPECHECK')

    # Get the watch folder from the configuration
    watch_folder = config.get('Paths', 'WATCHFOLDER')

    if not dupe_check_flag:
        print(f"{bcolors.WARNING}Duplicate check is disabled in the configuration.{bcolors.ENDC}")
        return False

    uploading_info = guessit(release_name)
    search_url = f"{config.get('Website', 'SITEURL')}/api/v1/torrents?searchText={release_name}"
    try:
        print(f"{bcolors.YELLOW}Checking for dupe: {release_name}\n{bcolors.ENDC}")
        response = requests.get(search_url, cookies=cookies, headers={'User-Agent': 'Mozilla/5.0'})
        response.raise_for_status()

        # Log the response
        log_to_file(os.path.join(TMP_DIR, 'dupe_check_response.log'), response.text)

        # Check if the response is empty
        if not response.text.strip():
            print(f"{bcolors.FAIL}Did not found a dupe for: {release_name}\n{bcolors.ENDC}")
            log_to_file(os.path.join(TMP_DIR, 'dupe_empty_response.log'), f"Empty response received for: {release_name}")
            return False

        # Parse the JSON response
        try:
            torrents = json.loads(response.text)
        except json.JSONDecodeError as e:
            print(f"{bcolors.FAIL}Failed to decode JSON response: {str(e)}{bcolors.ENDC}")
            log_to_file(os.path.join(TMP_DIR, 'dupe_json_decode_error.log'), f"Failed to decode JSON response: {str(e)}")
            return False

        if not isinstance(torrents, list):
            print(f"{bcolors.FAIL}Unexpected response format for: {release_name}{bcolors.ENDC}")
            log_to_file(os.path.join(TMP_DIR, 'dupe_unexpected_format.log'), f"Unexpected response format for: {release_name}")
            return False

        for torrent in torrents:
            # Run torrent name through guessit to "normalize" and then compare
            similarity = similar(uploading_info, guessit(torrent['name']))
            if similarity > 0.85:
                # Chance of it being the same torrent is higher than 85%
                torrent_id = torrent['id']
                dupe_torrent_url = f"{config.get('Website', 'SITEURL')}/api/v1/torrents/download/{torrent_id}"
                
                # Log and print the duplicate detection
                log_to_file(os.path.join(TMP_DIR, 'dupe_detected.log'), f"Duplicate found: {release_name} (ID: {torrent_id})")
                print(f"{bcolors.WARNING}Duplicate found: {release_name}.{bcolors.ENDC}")
                return True
        
        # If no duplicate was found
        print(f"{bcolors.GREEN}No duplicate found for: {release_name}{bcolors.ENDC}")
        log_to_file(os.path.join(TMP_DIR, 'dupe_not_found.log'), f"No duplicate found for: {release_name}")
        return False

    except requests.RequestException as e:
        # Log any request exceptions
        log_to_file(os.path.join(TMP_DIR, 'dupe_check_error.log'), f"Failed to check for duplicate: {str(e)}")
        print(f"{bcolors.FAIL}Failed to check for duplicate: {str(e)}{bcolors.ENDC}")
        return False
