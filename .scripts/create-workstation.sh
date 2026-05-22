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

if ! CREATE_OUTPUT=$(unset CLOUDSDK_CONFIG && env \
    CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
    CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
    CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
    CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
    bash -c "gcloud workstations create antigravity-ide \\
        --cluster=my-cluster \\
        --config=antigravity-ide-config \\
        --region=us-central1 \\
        --project=\"$PROJECT_ID\" \\
        --quiet --no-user-output-enabled" 2>&1); then
        if [[ "$CREATE_OUTPUT" == *"ALREADY_EXISTS"* ]]; then
            echo "Creation failed because workstation already exists. Proceeding..."
        else
            echo "Error creating workstation: $CREATE_OUTPUT"
            exit 1
        fi
    fi

# Set the IAM policy for the workstation
echo "Setting IAM policy for the workstation..."

# Get the current IAM policy
echo "Getting current IAM policy..."
unset CLOUDSDK_CONFIG && env \
CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
gcloud workstations get-iam-policy antigravity-ide \
    --project="$PROJECT_ID" \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 --format=json > policy.json

# Create a python script to update the policy
cat << 'EOF' > update_policy.py
import yaml
import sys

users_to_add = [
    "user:aburdenko@kallogjeri.altostrat.com",
    "user:aburdenko@google.com"
]

try:
    with open('policy.json', 'r') as f:
        policy = yaml.safe_load(f)
except FileNotFoundError:
    policy = {'bindings': []}


workstation_user_binding = None
for binding in policy.get('bindings', []):
    if binding['role'] == 'roles/workstations.user':
        workstation_user_binding = binding
        break

if workstation_user_binding is None:
    workstation_user_binding = {'role': 'roles/workstations.user', 'members': []}
    if 'bindings' not in policy:
        policy['bindings'] = []
    policy['bindings'].append(workstation_user_binding)

for user in users_to_add:
    if user not in workstation_user_binding['members']:
        workstation_user_binding['members'].append(user)

with open('new_policy.json', 'w') as f:
    yaml.dump(policy, f)
EOF

# Run the python script
echo "Updating IAM policy..."
python3 update_policy.py

# Clean up the python script and the old policy file
rm update_policy.py policy.json

unset CLOUDSDK_CONFIG && env \
CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
gcloud workstations set-iam-policy antigravity-ide \
    --project="$PROJECT_ID" \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 \
    new_policy.json

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
    CURRENT_STATE=$(unset CLOUDSDK_CONFIG && env \
        CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
        bash -c "gcloud workstations describe antigravity-ide \\
            --cluster=my-cluster \\
            --config=antigravity-ide-config \\
            --region=us-central1 \\
            --project=\"$PROJECT_ID\" \\
            --format=\"value(state)\"")
    if [ "$CURRENT_STATE" == "STATE_STOPPED" ]; then
        echo "Workstation stopped."
        break
    fi
    echo "Current state: ${CURRENT_STATE:-'UNKNOWN'}. Waiting..."
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
gcloud workstations start antigravity-ide \
    --config=antigravity-ide-config \
    --cluster="$CLUSTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet --no-user-output-enabled
		
while true; do
    WORKSTATION_STATE=$(unset CLOUDSDK_CONFIG && env \
        CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/ \
        CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/ \
        bash -c "gcloud workstations describe antigravity-ide \\
            --cluster=my-cluster \\
            --config=antigravity-ide-config \\
            --region=us-central1 \\
            --project=\"$PROJECT_ID\" \\
            --format=\"value(state)\"")
    if [ "$WORKSTATION_STATE" == "STATE_RUNNING" ]; then
        echo "Workstation started."
        break
    fi
    echo "Current state: ${WORKSTATION_STATE:-'UNKNOWN'}. Waiting..."
    sleep 10
done