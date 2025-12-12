#!/bin/bash

# This script creates or updates a Google Cloud Workstation.

# Source the configuration
source .scripts/configure.sh

# Update the workstation configuration

unset CLOUDSDK_CONFIG && env \
CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
gcloud workstations configs update antigravity-ide-config \
  --cluster=my-cluster --region=us-central1 --project="$PROJECT_ID" \
  --container-custom-image="$IMAGE_URL" \
  --quiet --no-user-output-enabled

# Start the workstation

unset CLOUDSDK_CONFIG && env \
CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
gcloud workstations create antigravity-ide \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 \
    --project="$PROJECT_ID" \
    --quiet --no-user-output-enabled

# Stop the workstation
echo "Stopping workstation..."

unset CLOUDSDK_CONFIG && env \
CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
gcloud workstations stop antigravity-ide \
    --config=antigravity-ide-config \
    --cluster=my-cluster \
    --region=us-central1 \
    --project="$PROJECT_ID" \
    --quiet --no-user-output-enabled

# Wait for the workstation to be stopped
echo "Waiting for workstation to stop..."
while true; do
    WORKSTATION_STATE=$(unset CLOUDSDK_CONFIG && env \
        CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
        gcloud workstations describe antigravity-ide \
        --config=antigravity-ide-config \
        --cluster=my-cluster \
        --region=us-central1 \
        --project="$PROJECT_ID" \
        --format="value(state)" --quiet --no-user-output-enabled)
    if [ "$WORKSTATION_STATE" == "STATE_STOPPED" ]; then
        echo "Workstation stopped."
        break
    fi
    echo "Current state: ${WORKSTATION_STATE:-'UNKNOWN'}. Waiting..."
    sleep 10
done

# Start the workstation
echo "Starting workstation..."

unset CLOUDSDK_CONFIG && env \
CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
gcloud workstations start antigravity-ide \
    --config=antigravity-ide-config \
    --cluster="$CLUSTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet --no-user-output-enabled

# Wait for the workstation to be running
echo "Waiting for workstation to start..."
while true; do
    WORKSTATION_STATE=$(unset CLOUDSDK_CONFIG && env \
        CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
        gcloud workstations describe antigravity-ide \
        --config=antigravity-ide-config \
        --cluster="$CLUSTER_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(state)" --quiet --no-user-output-enabled)
    if [ "$WORKSTATION_STATE" == "STATE_RUNNING" ]; then
        echo "Workstation started."
        break
    fi
    echo "Current state: ${WORKSTATION_STATE:-'UNKNOWN'}. Waiting..."
    sleep 10
done