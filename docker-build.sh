#!/usr/bin/env bash
#
# build.sh - Linux/macOS Build Script
#
# This script automates the process of building and running the Docker container
# with version information dynamically injected at build time.

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

# --- Configuration ---
CONFIG_FILE="config.yaml"
USAGE_BACKUP_FILE=".usage_backup.json"
MGMT_KEY_FILE=".mgmt_key"

# --- Helper Functions ---

# Encrypt and save management key
save_management_key() {
  local key="$1"
  echo "$key" | openssl enc -aes-256-cbc -pbkdf2 -base64 -pass pass:"cli-proxy-build" -out "$MGMT_KEY_FILE" 2>/dev/null
}

# Load and decrypt management key
load_management_key() {
  if [[ -f "$MGMT_KEY_FILE" ]]; then
    openssl enc -aes-256-cbc -pbkdf2 -d -base64 -pass pass:"cli-proxy-build" -in "$MGMT_KEY_FILE" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Prompt user for management key
prompt_management_key() {
  local key
  read -r -s -p "Enter management key: " key
  echo >&2
  echo "$key"
}

# Get management key (from env, saved file, or prompt)
get_management_key() {
  # Try environment variable first
  if [[ -n "${MANAGEMENT_PASSWORD:-}" ]]; then
    echo "$MANAGEMENT_PASSWORD"
    return
  fi
  
  # Try saved key file
  local saved_key
  saved_key=$(load_management_key)
  if [[ -n "$saved_key" ]]; then
    echo "$saved_key"
    return
  fi
  
  # Prompt user
  prompt_management_key
}

# Get server port from config file
get_server_port() {
  if [[ -f "$CONFIG_FILE" ]]; then
    grep -E '^port:' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "8317"
  else
    echo "8317"
  fi
}

# Export usage statistics with retry on auth failure
export_usage_statistics() {
  local api_key="$1"
  local port="$2"
  local base_url="http://127.0.0.1:${port}"
  local max_retries=3
  local retry=0
  
  echo "Exporting usage statistics from ${base_url}..."
  
  while [[ $retry -lt $max_retries ]]; do
    # Try to export usage statistics
    local http_code
    http_code=$(curl -s -w "%{http_code}" -X GET "${base_url}/v0/management/usage/export" \
      -H "Authorization: Bearer ${api_key}" \
      -H "Content-Type: application/json" \
      -o "$USAGE_BACKUP_FILE" 2>/dev/null)
    
    if [[ "$http_code" == "200" ]]; then
      echo "Usage statistics exported to ${USAGE_BACKUP_FILE}"
      # Save the valid key for future use
      save_management_key "$api_key"
      return 0
    elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
      echo "Authentication failed. Please re-enter the management key."
      # Remove invalid saved key
      rm -f "$MGMT_KEY_FILE"
      api_key=$(prompt_management_key)
      if [[ -z "$api_key" ]]; then
        echo "No key provided, skipping export."
        return 1
      fi
      ((retry++))
    elif [[ "$http_code" == "000" ]]; then
      echo "Warning: Failed to connect to server (server may not be running)"
      return 1
    else
      echo "Warning: Failed to export usage statistics (HTTP ${http_code})"
      return 1
    fi
  done
  
  echo "Max retries reached, skipping export."
  return 1
}

# Import usage statistics
import_usage_statistics() {
  local api_key="$1"
  local port="$2"
  local base_url="http://127.0.0.1:${port}"
  
  if [[ ! -f "$USAGE_BACKUP_FILE" ]]; then
    echo "No usage backup file found, skipping import."
    return 0
  fi
  
  echo "Importing usage statistics to ${base_url}..."
  
  # Wait for server to be ready (max 30 seconds)
  local max_attempts=30
  local attempt=0
  while [[ $attempt -lt $max_attempts ]]; do
    if curl -s -f -o /dev/null "${base_url}/health" 2>/dev/null || \
       curl -s -f -o /dev/null "${base_url}/" 2>/dev/null; then
      break
    fi
    sleep 1
    ((attempt++))
  done
  
  if [[ $attempt -ge $max_attempts ]]; then
    echo "Warning: Server did not become ready in time, skipping import."
    return 1
  fi
  
  # Import usage statistics
  if curl -s -f -X POST "${base_url}/v0/management/usage/import" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    -d @"$USAGE_BACKUP_FILE" 2>/dev/null; then
    echo "Usage statistics imported successfully."
    rm -f "$USAGE_BACKUP_FILE"
    return 0
  else
    echo "Warning: Failed to import usage statistics."
    return 1
  fi
}

# Prompt user for confirmation (default Y)
confirm_action() {
  local prompt="$1"
  local response
  read -r -p "${prompt} [Y/n]: " response
  response="${response:-Y}"
  [[ "$response" =~ ^[Yy]$ ]]
}

# --- Main Script ---

# Check config file existence
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Warning: Config file '${CONFIG_FILE}' not found."
fi

# Get server port
SERVER_PORT=$(get_server_port)

# --- Step 1: Choose Environment ---
echo "Please select an option:"
echo "1) Run using Pre-built Image (Recommended)"
echo "2) Build from Source and Run (For Developers)"
read -r -p "Enter choice [1-2]: " choice

# Validate choice
if [[ "$choice" != "1" && "$choice" != "2" ]]; then
  echo "Invalid choice. Please enter 1 or 2."
  exit 1
fi

# --- Step 2: Collect confirmation and credentials before execution ---
DO_USAGE_BACKUP=false
MGMT_KEY=""

if confirm_action "Backup and restore usage statistics during rebuild?"; then
  MGMT_KEY=$(get_management_key)
  if [[ -n "$MGMT_KEY" ]]; then
    DO_USAGE_BACKUP=true
  else
    echo "No management key provided, skipping usage backup/restore."
  fi
fi

echo ""
echo "========================================"
echo "Starting execution..."
echo "========================================"

# --- Step 3: Export usage statistics ---
EXPORT_SUCCESS=false
if [[ "$DO_USAGE_BACKUP" == "true" ]]; then
  if export_usage_statistics "$MGMT_KEY" "$SERVER_PORT"; then
    EXPORT_SUCCESS=true
  fi
fi

# --- Step 4: Execute based on choice ---
case "$choice" in
  1)
    echo "--- Running with Pre-built Image ---"
    docker compose up -d --remove-orphans --no-build
    echo "Services are starting from remote image."
    ;;
  2)
    echo "--- Building from Source and Running ---"

    # Get Version Information
    VERSION="$(git describe --tags --always --dirty)"
    COMMIT="$(git rev-parse --short HEAD)"
    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo "Building with the following info:"
    echo "  Version: ${VERSION}"
    echo "  Commit: ${COMMIT}"
    echo "  Build Date: ${BUILD_DATE}"
    echo "----------------------------------------"

    # Build and start the services with a local-only image tag
    export CLI_PROXY_IMAGE="cli-proxy-api:local"
    
    echo "Building the Docker image..."
    docker compose build \
      --build-arg VERSION="${VERSION}" \
      --build-arg COMMIT="${COMMIT}" \
      --build-arg BUILD_DATE="${BUILD_DATE}"

    echo "Starting the services..."
    docker compose up -d --remove-orphans --pull never
    ;;
esac

# --- Step 5: Import usage statistics after rebuild ---
if [[ "$DO_USAGE_BACKUP" == "true" && "$EXPORT_SUCCESS" == "true" ]]; then
  import_usage_statistics "$MGMT_KEY" "$SERVER_PORT"
fi

echo "Build complete. Services are starting."
echo "Run 'docker compose logs -f' to see the logs."
