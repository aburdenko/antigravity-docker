#!/bin/bash

# Source the configuration to get PROJECT_ID and other common variables
source "$(dirname "$0")/configure.sh"

# --- Configuration Variables ---
# Default values can be overridden by environment variables or by editing this script.
: "${REGION:=us-central1}"
: "${ARTIFACT_REGISTRY_REPO:=workstation-images}"
: "${IMAGE_NAME:=antigravity}"
: "${IMAGE_TAG:=2.0}"
: "${WORKSTATION_NAME:=antigravity-2-0-dev}"
: "${WORKSTATION_CLUSTER_NAME:=cluster-mrfgarf5}"
: "${WORKSTATION_CONFIG_NAME:=config-mrfgmyox}"

# Full image URL
IMAGE_URL="us-central1-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# --- Automate Antigravity Executable Download and Placement ---
if [ ! -f "$HOME/.local/bin/agy" ] && [ ! -f "$HOME/.antigravity/bin/antigravity" ]; then
    echo "Attempting to download and install antigravity executable locally..."
    curl -fsSL https://antigravity.google/cli/install.sh | bash
else
    echo "Antigravity executable already installed locally."
fi

# Find the installed antigravity executable
ANTIGRAVITY_LOCAL_PATH=""
if [ -f "$HOME/.local/bin/agy" ]; then
    ANTIGRAVITY_LOCAL_PATH="$HOME/.local/bin/agy"
elif [ -f "$HOME/.antigravity/bin/antigravity" ]; then
    ANTIGRAVITY_LOCAL_PATH="$HOME/.antigravity/bin/antigravity"
else
    echo "Error: Could not find the installed 'antigravity' executable. Please ensure the installation script completed successfully."
    exit 1
fi

echo "Antigravity executable found at: ${ANTIGRAVITY_LOCAL_PATH}"
echo "Copying 'antigravity' executable to project root for Cloud Build context..."
cp "${ANTIGRAVITY_LOCAL_PATH}" ./antigravity

if [ $? -ne 0 ]; then
    echo "Failed to copy 'antigravity' executable to project root. Exiting."
    exit 1
fi
echo "'antigravity' executable successfully copied to project root."

echo "Starting Cloud Build for image: ${IMAGE_URL}"

echo "Listing files in current directory before Cloud Build (for debugging):"
ls -l .

# 1. Kick off a new container image build using Cloud Build
gcloud builds submit --project "${PROJECT_ID}" --config cloudbuild.yaml . --substitutions _IMAGE_URL="${IMAGE_URL}"

if [ $? -ne 0 ]; then
    echo "Cloud Build failed. Exiting."
    exit 1
fi

echo "Cloud Build completed successfully. Image pushed to: ${IMAGE_URL}"

# Get the exact image digest to force Cloud Workstations to bypass the cache
echo "Resolving image digest for ${IMAGE_URL}..."
IMAGE_DIGEST=$(gcloud artifacts docker images describe "${IMAGE_URL}" --format="value(image_summary.digest)")
if [ -n "$IMAGE_DIGEST" ]; then
    DEPLOY_IMAGE_URL="us-central1-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}/${IMAGE_NAME}@${IMAGE_DIGEST}"
    echo "Resolved digest image URL: ${DEPLOY_IMAGE_URL}"
else
    echo "Warning: Could not resolve image digest. Falling back to tagged image URL."
    DEPLOY_IMAGE_URL="${IMAGE_URL}"
fi

echo "Updating Workstation Config '${WORKSTATION_CONFIG_NAME}' with new image..."

# 2. Update Workstation Config to use the new image and mimic the working config
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
WORKSTATION_SA="service-${PROJECT_NUMBER}@gcp-sa-workstationsvm.iam.gserviceaccount.com"
WORKSTATION_VM_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "Granting Artifact Registry reader role to Workstation Service Agent..."
gcloud artifacts repositories add-iam-policy-binding "${ARTIFACT_REGISTRY_REPO}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${WORKSTATION_SA}" \
    --role="roles/artifactregistry.reader" \
    --quiet

gcloud workstations configs update "${WORKSTATION_CONFIG_NAME}" \
    --cluster="${WORKSTATION_CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --container-custom-image="${DEPLOY_IMAGE_URL}" \
    --machine-type=n1-standard-32 \
    --pool-size=1 \
    --running-timeout=43200 \
    --no-disable-public-ip-addresses \
    --service-account="${WORKSTATION_VM_SA}" \
    --pd-disk-size=200 \
    --pd-disk-type=pd-balanced \
    --allowed-ports="first=22,last=22" \
    --allowed-ports="first=80,last=80" \
    --allowed-ports="first=1024,last=65535"

if [ $? -ne 0 ]; then
    echo "Workstation config update failed. Exiting."
    exit 1
fi

echo "Checking if Cloud Workstation '${WORKSTATION_NAME}' already exists..."

if gcloud workstations describe "${WORKSTATION_NAME}" \
    --cluster="${WORKSTATION_CLUSTER_NAME}" \
    --config="${WORKSTATION_CONFIG_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" &>/dev/null; then

    echo "Cloud Workstation '${WORKSTATION_NAME}' already exists. Stopping it to apply the new config..."
    gcloud workstations stop "${WORKSTATION_NAME}" \
        --cluster="${WORKSTATION_CLUSTER_NAME}" \
        --config="${WORKSTATION_CONFIG_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet

    echo "Starting Cloud Workstation '${WORKSTATION_NAME}'..."
    gcloud workstations start "${WORKSTATION_NAME}" \
        --cluster="${WORKSTATION_CLUSTER_NAME}" \
        --config="${WORKSTATION_CONFIG_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet

    if [ $? -ne 0 ]; then
        echo "Failed to start Cloud Workstation. Exiting."
        exit 1
    fi
    echo "Cloud Workstation restarted successfully."

else
    echo "Cloud Workstation '${WORKSTATION_NAME}' does not exist. Creating it..."
    gcloud workstations create "${WORKSTATION_NAME}" \
        --cluster="${WORKSTATION_CLUSTER_NAME}" \
        --config="${WORKSTATION_CONFIG_NAME}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}"

    if [ $? -ne 0 ]; then
        echo "Cloud Workstation creation failed. Exiting."
        exit 1
    fi
    echo "Cloud Workstation '${WORKSTATION_NAME}' created successfully."

    echo "Granting roles/workstations.user to ${GCP_USER_ACCOUNT} on the workstation..."
    gcloud workstations get-iam-policy "${WORKSTATION_NAME}" \
        --project="${PROJECT_ID}" \
        --cluster="${WORKSTATION_CLUSTER_NAME}" \
        --config="${WORKSTATION_CONFIG_NAME}" \
        --region="${REGION}" --format=json > policy.json

    # Use a small python script to safely append the user to the workstations.user role
    python3 -c "
import json
import sys

try:
    with open('policy.json', 'r') as f:
        policy = json.load(f)
except FileNotFoundError:
    policy = {'bindings': []}

user_to_add = 'user:${GCP_USER_ACCOUNT}'
user_binding = next((b for b in policy.get('bindings', []) if b.get('role') == 'roles/workstations.user'), None)

if user_binding is None:
    user_binding = {'role': 'roles/workstations.user', 'members': []}
    if 'bindings' not in policy:
        policy['bindings'] = []
    policy['bindings'].append(user_binding)

if user_to_add not in user_binding['members']:
    user_binding['members'].append(user_to_add)

with open('new_policy.json', 'w') as f:
    json.dump(policy, f)
"

    gcloud workstations set-iam-policy "${WORKSTATION_NAME}" \
        --project="${PROJECT_ID}" \
        --cluster="${WORKSTATION_CLUSTER_NAME}" \
        --config="${WORKSTATION_CONFIG_NAME}" \
        --region="${REGION}" \
        new_policy.json

    rm policy.json new_policy.json
    echo "IAM policy configured."
fi

echo "You can now access your workstation from the Google Cloud Console."
