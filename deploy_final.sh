#!/bin/bash
IMAGE_URL="us-central1-docker.pkg.dev/kallogjeri-project-345114/workstation-images/antigravity:2.0"

echo "Submitting Cloud Build..."
gcloud builds submit --project "kallogjeri-project-345114" --config cloudbuild.yaml . --substitutions _IMAGE_URL="${IMAGE_URL}"

IMAGE_DIGEST=$(gcloud artifacts docker images describe "${IMAGE_URL}" --format="value(image_summary.digest)")
DEPLOY_IMAGE_URL="us-central1-docker.pkg.dev/kallogjeri-project-345114/workstation-images/antigravity@${IMAGE_DIGEST}"
echo "Pushed Image with Digest: ${DEPLOY_IMAGE_URL}"

echo "Updating Workstation Config..."
gcloud workstations configs update antigravity-ide-config \
    --cluster=my-cluster \
    --region=us-central1 \
    --project=kallogjeri-project-345114 \
    --container-custom-image="${DEPLOY_IMAGE_URL}" \
    --allowed-ports="first=22,last=22" \
    --allowed-ports="first=80,last=80" \
    --allowed-ports="first=8080,last=8080" \
    --allowed-ports="first=1024,last=65535" \
    --quiet

echo "Deleting old workstation..."
gcloud workstations delete antigravity-2-0-dev \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 \
    --project=kallogjeri-project-345114 \
    --quiet

echo "Creating new workstation..."
gcloud workstations create antigravity-2-0-dev \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 \
    --project=kallogjeri-project-345114 \
    --quiet

echo "Updating IAM policy..."
gcloud workstations get-iam-policy antigravity-2-0-dev \
    --project=kallogjeri-project-345114 \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 --format=json > policy.json

python3 -c "
import json
with open('policy.json', 'r') as f:
    policy = json.load(f)
user_to_add = 'user:aburdenko@kallogjeri.altostrat.com'
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

gcloud workstations set-iam-policy antigravity-2-0-dev \
    --project=kallogjeri-project-345114 \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 \
    new_policy.json

rm -f policy.json new_policy.json

echo "Starting workstation..."
gcloud workstations start antigravity-2-0-dev \
    --cluster=my-cluster \
    --config=antigravity-ide-config \
    --region=us-central1 \
    --project=kallogjeri-project-345114 \
    --quiet
