#!/bin/bash

# .scripts/create-workstation.sh
# Usage: source .scripts/configure.sh && .scripts/create-workstation.sh

set -e # Exit immediately if a command exits with a non-zero status

CONFIG_ID="${WORKSTATION_NAME}-config"

# --- 0. Pre-flight Checks ---
if [ -z "$IMAGE_URL" ]; then
    echo "Error: Environment variables not set."
    echo "Please run: source .scripts/configure.sh"
    exit 1
fi

echo "========================================================"
echo "Deploying Workstation: $WORKSTATION_NAME"
echo "Target Image: $IMAGE_URL"
echo "========================================================"

# --- 1. IAM Permissions ---
# Grant Artifact Registry Reader to the Compute Engine Service Account
echo "[1/4] Verifying IAM permissions..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# We use '|| true' to suppress error if binding already exists
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$COMPUTE_SA" \
    --role="roles/artifactregistry.reader" \
    --condition=None --quiet > /dev/null 2>&1 || true

# Grant Workstations User role to the specified user.
IAM_POLICY_FILE=$(mktemp)
gcloud workstations get-iam-policy "$WORKSTATION_NAME" \
    --cluster="$CLUSTER_NAME" \
    --config="$CONFIG_ID" \
    --region="$REGION" \
    --format="json" > "$IAM_POLICY_FILE"

# Add the user to the policy if they are not already there.
if ! grep -q "user:$GCP_USER_ACCOUNT" "$IAM_POLICY_FILE"; then
    echo "      - Granting 'roles/workstations.user' to $GCP_USER_ACCOUNT"
    jq ".bindings |= . + [{\"role\": \"roles/workstations.user\", \"members\": [\"user:$GCP_USER_ACCOUNT\"]}]" "$IAM_POLICY_FILE" > "$IAM_POLICY_FILE.tmp" && mv "$IAM_POLICY_FILE.tmp" "$IAM_POLICY_FILE"
    gcloud workstations set-iam-policy "$WORKSTATION_NAME" "$IAM_POLICY_FILE" \
        --cluster="$CLUSTER_NAME" \
        --config="$CONFIG_ID" \
        --region="$REGION"
fi

rm -f "$IAM_POLICY_FILE"


# --- 2. Create Workstation Cluster ---
echo "[2/4] Ensuring Workstation Cluster Exists..."

if ! gcloud workstations clusters describe "$CLUSTER_NAME" --region="$REGION" > /dev/null 2>&1; then
    echo "      Creating new cluster: $CLUSTER_NAME"
    gcloud workstations clusters create "$CLUSTER_NAME" \
        --region="$REGION" \
        --network="projects/$PROJECT_ID/global/networks/default" \
        --subnetwork="projects/$PROJECT_ID/regions/$REGION/subnetworks/default"
else
    echo "      Workstation cluster '$CLUSTER_NAME' already exists."
fi

# --- 3. Build & Push Image ---
echo "[3/4] Building and Pushing Container Image..."

# Create Repo if it doesn't exist
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    echo "      Creating Artifact Registry repository '$REPO_NAME'..."
    gcloud artifacts repositories create "$REPO_NAME" \
        --repository-format=docker \
        --location="$REGION" \
        --description="Workstation Custom Images"
fi

# Submit Build (Assumes run from root where Dockerfile is)
gcloud builds submit . \
    --config=cloudbuild.yaml \
    --substitutions=_IMAGE_URL="$IMAGE_URL" \
    --timeout=90m # Added timeout as builds can take time, removed --async to make it synchronous

# --- 3. Workstation Configuration ---
echo "[3/4] Updating Workstation Configuration..."

CONFIG_ID="${WORKSTATION_NAME}-config"

if gcloud workstations configs describe "$CONFIG_ID" --region="$REGION" --cluster="$CLUSTER_NAME" > /dev/null 2>&1; then
    echo "      Updating existing config: $CONFIG_ID"
    gcloud workstations configs update "$CONFIG_ID" \
        --region="$REGION" \
        --cluster="$CLUSTER_NAME" \
        --container-custom-image="$IMAGE_URL" \
        --allowed-ports=first=22,last=22,first=80,last=80,first=1024,last=65535
else
    echo "      Creating new config: $CONFIG_ID"
    gcloud workstations configs create "$CONFIG_ID" \
        --region="$REGION" \
        --cluster="$CLUSTER_NAME" \
        --machine-type="e2-standard-4" \
        --container-custom-image="$IMAGE_URL" \
        --pd-disk-size=50 \
        --pd-disk-type=pd-ssd \
        --pd-reclaim-policy=retain \
        --service-account="$COMPUTE_SA" \
        --allowed-ports=first=22,last=22,first=80,last=80,first=1024,last=65535
fi

# --- 4. Create/Update Workstation ---
echo "[4/4] Provisioning Workstation Instance..."

if gcloud workstations describe "$WORKSTATION_NAME" --region="$REGION" --cluster="$CLUSTER_NAME" --config="$CONFIG_ID" > /dev/null 2>&1; then
    echo "      Workstation '$WORKSTATION_NAME' already exists. Restarting to apply new image..."
    gcloud workstations stop "$WORKSTATION_NAME" \
        --region="$REGION" \
        --cluster="$CLUSTER_NAME" \
        --config="$CONFIG_ID"
    # Wait for the stop operation to complete before starting
    echo "      Waiting for workstation to fully stop..."
    # Poll workstation state until it is STOPPED
    while ! gcloud workstations describe "$WORKSTATION_NAME" \
        --region="$REGION" \
        --cluster="$CLUSTER_NAME" \
        --config="$CONFIG_ID" \
        --format="value(state)" | grep -q "STOPPED"
    do
        sleep 10
    done
    
    gcloud workstations start "$WORKSTATION_NAME" \
        --region="$REGION" \
        --cluster="$CLUSTER_NAME" \
        --config="$CONFIG_ID"
else
    gcloud workstations create "$WORKSTATION_NAME" \
        --region="$REGION" \
        --cluster="$CLUSTER_NAME" \
        --config="$CONFIG_ID"
fi

echo "Waiting for workstation to be ready..."
sleep 30

# Grant Workstations User role to the specified user.
IAM_POLICY_FILE=$(mktemp)
gcloud workstations get-iam-policy "$WORKSTATION_NAME" \
    --cluster="$CLUSTER_NAME" \
    --config="$CONFIG_ID" \
    --region="$REGION" \
    --format="json" > "$IAM_POLICY_FILE"

# Add the user to the policy if they are not already there.
if ! grep -q "user:$GCP_USER_ACCOUNT" "$IAM_POLICY_FILE"; then
    echo "      - Granting 'roles/workstations.user' to $GCP_USER_ACCOUNT"
    jq ".bindings |= . + [{\"role\": \"roles/workstations.user\", \"members\": [\"user:$GCP_USER_ACCOUNT\"]}]" "$IAM_POLICY_FILE" > "$IAM_POLICY_FILE.tmp" && mv "$IAM_POLICY_FILE.tmp" "$IAM_POLICY_FILE"
    gcloud workstations set-iam-policy "$WORKSTATION_NAME" "$IAM_POLICY_FILE" \
        --cluster="$CLUSTER_NAME" \
        --config="$CONFIG_ID" \
        --region="$REGION"
fi

rm -f "$IAM_POLICY_FILE"

echo "========================================================"
echo "SUCCESS. Workstation '$WORKSTATION_NAME' is ready."
echo "========================================================"

echo "Verifying connection to port 80..."
HOSTNAME=$(gcloud workstations describe "$WORKSTATION_NAME" --project="$PROJECT_ID" --region="$REGION" --cluster="$CLUSTER_NAME" --config="$CONFIG_ID" --format="value(host)")
curl -s -o /dev/null -w "%{http_code}" "http://$HOSTNAME"
