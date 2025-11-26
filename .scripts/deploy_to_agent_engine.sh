#!/bin/bash

# Script to deploy the agent to Vertex AI Agent Engine

# --- Go to project root ---
cd "$(dirname "$0")/.."

# --- Configuration ---
# Get Project ID from gcloud
PROJECT_ID=$(gcloud config get-value project)
if [ -z "$PROJECT_ID" ]; then
    echo "GCP Project ID not found. Please run 'gcloud config set project YOUR_PROJECT_ID'"
    exit 1
fi

# Set default values
DEFAULT_LOCATION="us-central1"
DEFAULT_AGENT_NAME="rag-agent"
DEFAULT_SERVICE_ACCOUNT=""
DEFAULT_ENV_VARS=""

# --- Command-line argument parsing ---
LOCATION="$DEFAULT_LOCATION"
AGENT_NAME="$DEFAULT_AGENT_NAME"
SERVICE_ACCOUNT="$DEFAULT_SERVICE_ACCOUNT"
ENV_VARS="$DEFAULT_ENV_VARS"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --location) LOCATION="$2"; shift ;;
        --agent-name) AGENT_NAME="$2"; shift ;;
        --service-account) SERVICE_ACCOUNT="$2"; shift ;;
        --env-vars) ENV_VARS="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# --- Create requirements.txt ---
echo "Generating requirements.txt..."
(cd agents/rag-agent && uv export --no-hashes --no-header --no-dev --no-emit-project --no-annotate > .requirements.txt)

# --- Build the deployment command ---
CMD="uv run agents/rag-agent/app/agent_engine_app.py \
    --project $PROJECT_ID \
    --location $LOCATION \
    --agent-name $AGENT_NAME \
    --requirements-file agents/rag-agent/.requirements.txt \
    --extra-packages agents/rag-agent/app"

if [ -n "$SERVICE_ACCOUNT" ]; then
    CMD="$CMD --service-account $SERVICE_ACCOUNT"
fi

if [ -n "$ENV_VARS" ]; then
    CMD="$CMD --set-env-vars $ENV_VARS"
fi

# --- Execute the deployment ---
echo "Running deployment command:"
echo "$CMD"
eval "$CMD"
