#!/bin/bash

# Path to the .env file
ENV_FILE="./.env"

# Check if the .env file exists
if [ ! -f "$ENV_FILE" ]; then
  echo "Environment file $ENV_FILE not found. Please create it with the required variables."
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

# Ensure required environment variables are set
if [ -z "$DEFAULT_EMAIL" ] || [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_TOKEN" ] || \
   [ -z "$REPO_URL_API" ] || [ -z "$REPO_BRANCH_API" ] || [ -z "$VIRTUAL_HOST_API" ] || [ -z "$LETSENCRYPT_HOST_API" ] || \
   [ -z "$REPO_URL_SITE" ] || [ -z "$REPO_BRANCH_SITE" ] || [ -z "$VIRTUAL_HOST_SITE" ] || [ -z "$LETSENCRYPT_HOST_SITE" ] || \
   [ -z "$TZ" ] || [ -z "$API_URL" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ] ; then
  echo "One or more required environment variables are missing in $ENV_FILE."
  echo "Please ensure all required variables are set."
  exit 1
fi

# -----------------------------------------------------------------------------
# SYSTEM & DOCKER SETUP
# -----------------------------------------------------------------------------

# Update the system
sudo apt update

# Check if Docker is installed, and install if it is not
if ! command -v docker &> /dev/null; then
  echo "Docker not found, installing..."
  sudo apt install -y docker.io
  sudo systemctl start docker
  sudo systemctl enable docker
else
  echo "Docker is already installed."
fi

# -----------------------------------------------------------------------------
# REPOSITORY MANAGEMENT
# -----------------------------------------------------------------------------

# Function to clone or pull a Git repository
manage_repo() {
  local repo_url=$1
  local repo_dir=$2
  local repo_branch=$3
  # Injects both username and token for authentication
  local authenticated_repo_url=$(echo "$repo_url" | sed "s|://|://$GITHUB_USER:$GITHUB_TOKEN@|")

  echo "--- Managing repository: $repo_dir ---"
  if [ -d "$repo_dir" ]; then
    echo "Directory found. Pulling latest changes from branch '$repo_branch'..."
    (cd "$repo_dir" && git reset --hard && git clean -fd && git pull "$authenticated_repo_url" "$repo_branch") || {
      echo "Error: Failed to pull repository $repo_dir. Check connection, credentials, and branch name."
      exit 1
    }
  else
    echo "Cloning repository from branch '$repo_branch'..."
    git clone -b "$repo_branch" "$authenticated_repo_url" "$repo_dir" || {
      echo "Error: Failed to clone repository. Check URL, credentials, and branch name."
      exit 1
    }
  fi
}

# Clone or pull both repositories
# manage_repo "$REPO_URL_API" "backend" "$REPO_BRANCH_API"
manage_repo "$REPO_URL_SITE" "frontend" "$REPO_BRANCH_SITE"

# -----------------------------------------------------------------------------
# DOCKER VOLUME & CONTAINER UTILITIES
# -----------------------------------------------------------------------------

# Function to create a Docker volume if it doesn't exist
create_volume_if_missing() {
  if ! docker volume inspect "$1" > /dev/null 2>&1; then
    echo "Creating Docker volume: $1"
    docker volume create "$1"
  else
    echo "Docker volume $1 already exists."
  fi
}

# Function to stop and remove a Docker container if it exists
remove_container_if_exists() {
  if [ "$(docker ps -q -f name=$1)" ]; then
    echo "Stopping and removing existing container: $1"
    docker stop "$1"
    docker rm "$1"
  fi
}

# -----------------------------------------------------------------------------
# DOCKER SETUP
# -----------------------------------------------------------------------------

# Ensure Docker volumes are created
echo "--- Ensuring Docker volumes exist ---"
create_volume_if_missing html
create_volume_if_missing certs
create_volume_if_missing acme
create_volume_if_missing api-docs-cache
create_volume_if_missing database

echo "--- Setting up Database ---"
remove_container_if_exists postgres-db

# Run the PostgreSQL container
docker run -d \
  --name postgres-db --restart unless-stopped \
  --cpus=0.5 --memory=500m \
  -p 5432:5432 \
  -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -e POSTGRES_DB="$DB_NAME" \
  -v database_data:/var/lib/postgresql/data \
  postgres:17.5-alpine3.22


# Run nginx-proxy and acme-companion containers (shared for all services)
echo "--- Setting up proxy and SSL containers ---"
remove_container_if_exists nginx-proxy
docker run -d \
  --name nginx-proxy --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -v html:/usr/share/nginx/html \
  -v certs:/etc/nginx/certs:ro \
  -v /var/run/docker.sock:/tmp/docker.sock:ro \
   -v ./custom_proxy.conf:/etc/nginx/conf.d/custom_proxy.conf:rw \
  --network bridge \
  nginxproxy/nginx-proxy

remove_container_if_exists nginx-proxy-acme
docker run -d \
  --name nginx-proxy-acme --restart unless-stopped \
  --env DEFAULT_EMAIL="$DEFAULT_EMAIL" \
  --volumes-from nginx-proxy \
  -v certs:/etc/nginx/certs:rw -v acme:/etc/acme.sh \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --network bridge \
  nginxproxy/acme-companion

# -----------------------------------------------------------------------------
# SERVICE
# -----------------------------------------------------------------------------

# echo "--- Building and deploying backend ---"
# docker build -t backend -f ./backend/Dockerfile ./backend

# remove_container_if_exists backend
# docker run -d \
#   --name backend --restart unless-stopped \
#   --cpus=0.9 --memory=900m \
#   --env VIRTUAL_HOST="$VIRTUAL_HOST_API" \
#   --env LETSENCRYPT_HOST="$LETSENCRYPT_HOST_API" \
#   --env NODE_ENV=production \
#   --env TZ="$TZ" \
#   --env PORT=80 \
#   --env VALID_ORIGIN="https://$VIRTUAL_HOST_SITE" \
#   --env DB_HOST=postgres-db \
#   --env DB_PORT=5432 \
#   --env DB_USER="$DB_USER" \
#   --env DB_PASSWORD="$DB_PASSWORD" \
#   --env DB_NAME="$DB_NAME" \
#   --expose 80 \
#   -v api-docs-cache:/app/docs-cache \
#   --network bridge \
#   backend

# -----------------------------------------------------------------------------
# FRONT END
# -----------------------------------------------------------------------------

echo "--- Building and deploying frontend ---"
# Assumes the Dockerfile for the site is in the root of its repository
docker build -t frontend -f ./frontend/Dockerfile ./frontend

remove_container_if_exists frontend
docker run -d \
  --name frontend --restart unless-stopped \
  --cpus=0.5 --memory=500m \
  --env VIRTUAL_HOST="$VIRTUAL_HOST_SITE" \
  --env LETSENCRYPT_HOST="$LETSENCRYPT_HOST_SITE" \
  --env NODE_ENV=production \
  --env TZ="$TZ" \
  --env API_URL="$API_URL" \
  --expose 80 \
  --network bridge \
  frontend

# -----------------------------------------------------------------------------
# FINAL NOTIFICATION
# -----------------------------------------------------------------------------

echo "✅ Docker containers for frontend and back-end have been set up successfully."