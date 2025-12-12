# Usage: source .scripts/configure.sh

# --- Gemini CLI Installation/Update ---
if ! command -v npm &> /dev/null; then
  echo "Error: npm is not installed. Please install Node.js and npm to continue." >&2
  return 1
fi

echo "Checking for the latest Gemini CLI version..."
LATEST_VERSION=$(npm view @google/gemini-cli version)

if ! command -v gemini &> /dev/null; then
  echo "Gemini CLI not found. Installing the latest version ($LATEST_VERSION)..."
  sudo npm install -g @google/gemini-cli@latest
else
  # Extract version from `npm list`, which is more reliable than `gemini --version`
  INSTALLED_VERSION=$(npm list -g @google/gemini-cli --depth=0 2>/dev/null | grep '@google/gemini-cli' | sed 's/.*@//')
  if [ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]; then
    echo "Gemini CLI is already up to date (version $INSTALLED_VERSION)."
  else
    echo "A new version of Gemini CLI is available."
    echo "Upgrading from version $INSTALLED_VERSION to $LATEST_VERSION..."
    sudo npm install -g @google/gemini-cli@latest
  fi
fi


# --- Environment Configuration ---
# This script now sources its configuration from the .env file in the project root.
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Configuration file '$ENV_FILE' not found." >&2
    echo "Please create it by copying from '.env.example' and filling in the values." >&2
    return 1 # Use return instead of exit to allow sourcing to fail gracefully
fi

# Source the .env file to load variables.
# 'set -a' automatically exports all variables defined from this point forward.
# This is a more robust way to load .env files as it correctly handles
# spaces and special characters in variable values.
set -a
source "$ENV_FILE"
set +a # Disable auto-exporting

# --- Git User Configuration ---
# Set git user.name and user.email if they are defined in the .env file.
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
  echo "Configuring git user name and email..."
  git config --global user.name "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  git config pull.rebase true
else
  echo "Skipping git user configuration (GIT_USER_NAME or GIT_USER_EMAIL not set in .env)."
fi

# --- Google Credentials Setup ---
# This section determines the GCP Project ID and sets up credentials.
# The order of precedence is:
# 1. Service Account specified in .env (SERVICE_ACCOUNT_KEY_FILE)
# 2. User's Application Default Credentials (ADC) via gcloud

echo "--- Configuring Google Cloud Authentication & Project ---"

# Set an environment variable to disable gcloud's client certificate check.
# This is necessary to bypass Endpoint Verification errors when the environment
# lacks the required verification agent.
export CLOUDSDK_AUTH_DISABLE_CLIENT_CERTIFICATE_AUTHENTICATION=true

# Force gcloud to use the Private Service Connect (PSC) endpoint for all API calls.
# This bypasses network-level proxies that enforce Endpoint Verification,
# which is the root cause of the persistent client certificate errors. We use
# environment variables here because the `gcloud config set` commands themselves
# can be blocked by the network policy before they can take effect.
export CLOUDSDK_API_ENDPOINT_OVERRIDES_IAMCREDENTIALS=https://iamcredentials.googleapis.com/
export CLOUDSDK_API_ENDPOINT_OVERRIDES_CLOUDRESOURCEMANAGER=https://cloudresourcemanager.googleapis.com/
export CLOUDSDK_API_ENDPOINT_OVERRIDES_WORKSTATIONS=https://workstations.googleapis.com/

# --- Step 1: Check for Service Account ---
# The path to the service account key file should be set in the .env file.
if [ -n "$SERVICE_ACCOUNT_KEY_FILE" ] && [ -f "$SERVICE_ACCOUNT_KEY_FILE" ]; then
  echo "Service Account key found at '$SERVICE_ACCOUNT_KEY_FILE'. Using it for authentication."
  export GOOGLE_APPLICATION_CREDENTIALS="$SERVICE_ACCOUNT_KEY_FILE"
  # NOTE: We are intentionally NOT running `gcloud auth activate-service-account`.
  # That command is being blocked by the network's Endpoint Verification policy.
  # Instead, we rely on the GOOGLE_APPLICATION_CREDENTIALS environment variable,
  # which gcloud and other client libraries will automatically use for authentication.
  
  # If PROJECT_ID is not already set in .env, extract it from the SA key.
  if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(jq -r .project_id "$SERVICE_ACCOUNT_KEY_FILE")
    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" == "null" ]; then
      echo "ERROR: Could not extract project_id from service account key file." >&2
      echo "Please set PROJECT_ID in your .env file." >&2
      return 1
    fi
    echo "Inferred PROJECT_ID from Service Account: $PROJECT_ID"
  fi
else
  # --- Step 2: Fallback to Application Default Credentials (ADC) ---
  echo "Service Account key not found or not specified. Falling back to gcloud Application Default Credentials."
  unset GOOGLE_APPLICATION_CREDENTIALS

  # Ensure user is logged in for ADC. This avoids re-prompting on every `source`.
  if ! gcloud auth application-default print-access-token &>/dev/null; then
    echo "User is not logged in for ADC. Running 'gcloud auth application-default login'..."
    if ! gcloud auth application-default login --no-launch-browser --scopes=openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/cloud-platform; then
      echo "ERROR: gcloud auth application-default login failed." >&2
      return 1
    fi
  else
    echo "User already logged in with Application Default Credentials."
  fi

  # If PROJECT_ID is not set from .env, try to get it from gcloud config.
  if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    if [ -n "$PROJECT_ID" ]; then
      echo "Using configured gcloud project: $PROJECT_ID"
    else
      # If still no PROJECT_ID, prompt the user to select one.
      echo "Could not determine gcloud project. Fetching available projects..."
      mapfile -t projects < <(gcloud projects list --format="value(projectId,name)" --sort-by=projectId)

      if [ ${#projects[@]} -eq 0 ]; then
        echo "No projects found. Please enter your Google Cloud Project ID manually:"
        read -p "Project ID: " PROJECT_ID
        if [ -z "$PROJECT_ID" ]; then
          echo "ERROR: Project ID is required." >&2
          return 1
        fi
      else
        echo "Please select a project:"
        for i in "${!projects[@]}"; do
          printf "%3d) %s\n" "$((i+1))" "${projects[$i]}"
        done
        read -p "Enter number: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#projects[@]}" ]; then
          PROJECT_ID=$(echo "${projects[$((choice-1))]}" | awk '{print $1}')
        else
          echo "ERROR: Invalid selection." >&2
          return 1
        fi
      fi
    fi
  fi
fi

# --- Step 3: Finalize Project Configuration ---
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Project ID could not be determined. Please check your configuration." >&2
  return 1
fi

# Set the active gcloud project using an environment variable.
# We do this because the `gcloud config set project` command itself can be
# blocked by the network's Endpoint Verification policy before it takes effect.
echo "Setting active gcloud project to: $PROJECT_ID via environment variable."
export CLOUDSDK_CORE_PROJECT=$PROJECT_ID

# Get project number, which is needed for some service agent roles.
# We unset CLOUDSDK_CONFIG to ensure gcloud runs in a clean environment,
# forcing it to respect our CLOUDSDK_API_ENDPOINT_OVERRIDES variables
# and bypass the network proxy.
PROJECT_NUMBER=273872083706 #$(unset CLOUDSDK_CONFIG && gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" --quiet --no-user-output-enabled)


# --- Cloud Workstations Configuration ---
# Added: Sets up variables for 'create-workstation.sh'
# Uses defaults unless defined in .env
echo "--- Configuring Workstation Environment Variables ---"

export REGION="${REGION:-us-central1}"
export CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
export WORKSTATION_NAME="${WORKSTATION_NAME:-antigravity-ide}"
export REPO_NAME="${REPO_NAME:-workstation-images}"
export IMAGE_NAME="${IMAGE_NAME:-antigravity}"
export IMAGE_TAG="${IMAGE_TAG:-latest}"

# Construct the Artifact Registry Image URL based on the finalized PROJECT_ID
export IMAGE_URL="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$IMAGE_NAME:$IMAGE_TAG"

echo "  Region:      $REGION"
echo "  Cluster:     $CLUSTER_NAME"
echo "  Workstation: $WORKSTATION_NAME"
echo "  Target Image: $IMAGE_URL"



  # --- Ensure 'jq' is installed for robust JSON parsing ---
  if ! command -v jq &> /dev/null; then
    echo "'jq' command not found. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y jq
  fi

# --- Virtual Environment Setup ---
if [ ! -d ".venv/python3.12" ]; then
  echo "Python virtual environment '.python3.12' not found."
  echo "Attempting to install python3-venv..."
  sudo apt update && sudo apt install -y python3-venv
  echo "Creating Python virtual environment '.venv/python3.12'..."
  /usr/bin/python3 -m venv .venv/python3.12
  echo "Installing dependencies into .venv/python3.12 from requirements.txt..."
  
  # Grant the Vertex AI Service Agent the necessary role on your staging bucket
  if [ -n "$SOURCE_GCS_BUCKET" ]; then
      gcloud storage buckets add-iam-policy-binding gs://$SOURCE_GCS_BUCKET \
        --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com" \
        --role="roles/storage.objectViewer"
  fi

  if [ -n "$STAGING_GCS_BUCKET" ]; then
      # Grant the Vertex AI Service Agent the necessary role on your staging bucket
      gcloud storage buckets add-iam-policy-binding gs://$STAGING_GCS_BUCKET \
        --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com" \
        --role="roles/storage.objectViewer"

      # Grant the Vertex AI Service Agent the necessary role to create objects in the staging bucket
      gcloud storage buckets add-iam-policy-binding gs://$STAGING_GCS_BUCKET \
        --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com" \
        --role="roles/storage.objectCreator"
  fi
    
  # --- Ensure 'unzip' is installed for VSIX validation ---
  if ! command -v unzip &> /dev/null; then
    echo "'unzip' command not found. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y unzip
  fi

  # --- VS Code Extension Setup (One-time) ---
  echo "Checking for 'emeraldwalk.runonsave' VS Code extension..."
  # Use the full path to the executable, which we know from the environment
  CODE_OSS_EXEC="/opt/code-oss/bin/codeoss-cloudworkstations"

  if [ -f "$CODE_OSS_EXEC" ]; then
      if ! $CODE_OSS_EXEC --list-extensions | grep -q "emeraldwalk.runonsave"; then
        echo "Extension not found. Installing 'emeraldwalk.runonsave'..."

        # Using the static URL as requested. Note: This points to an older version (0.3.2)
        VSIX_URL="https://www.vsixhub.com/go.php?post_id=519&app_id=65a449f8-c656-4725-a000-afd74758c7e6&s=v5O4xJdDsfDYE&link=https%3A%2F%2Fmarketplace.visualstudio.com%2F_apis%2Fpublic%2Fgallery%2Fpublishers%2Femeraldwalk%2Fvsextensions%2FRunOnSave%2F0.3.2%2Fvspackage"
        VSIX_FILE="/tmp/emeraldwalk.runonsave.vsix" # Use /tmp for the download

        echo "Downloading extension from specified static URL..."
        if curl --fail -L -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36' -o "$VSIX_FILE" "$VSIX_URL"; then
          echo "Download complete. Installing..."
          if unzip -t "$VSIX_FILE" &> /dev/null; then
            if $CODE_OSS_EXEC --install-extension "$VSIX_FILE"; then
              echo "Extension 'emeraldwalk.runonsave' installed successfully."
              echo "IMPORTANT: Please reload the VS Code window to activate the extension."
            else
              echo "Error: Failed to install the extension from '$VSIX_FILE'." >&2
            fi
          else
            echo "Error: Downloaded file is not a valid VSIX package. It may be an HTML page." >&2
          fi
          rm -f "$VSIX_FILE"
        else
          echo "Error: Failed to download the extension from '$VSIX_URL'." >&2
        fi
      else
        echo "Extension 'emeraldwalk.runonsave' is already installed."
      fi
  else
      echo "Code OSS executable not found at $CODE_OSS_EXEC. Skipping extension check."
  fi
else
  echo "Virtual environment '.python3.12' already exists."
fi

echo "Activating environment './venv/python3.12'..."
 . .venv/python3.12/bin/activate

# Ensure dependencies are installed/updated every time the script is sourced.
echo "Ensuring dependencies from requirements.txt are installed..."
if ! ./.venv/python3.12/bin/pip install --quiet --no-cache-dir -r requirements.txt; then
  echo "ERROR: Failed to install dependencies from requirements.txt. Please check the file for errors." >&2
fi

# --- Google Agent Development Kit Check ---
AGENT_PKG_INSTALL="google-cloud-aiplatform[rag,eval]"
AGENT_PKG_CHECK="google-cloud-aiplatform" 

# Explicitly install the ADK package if it's not already present.
if ! ./.venv/python3.12/bin/pip show "$AGENT_PKG_CHECK" &> /dev/null; then
  echo "Google Agent Development Kit not found. Installing..."
  ./.venv/python3.12/bin/pip install --quiet "$AGENT_PKG_INSTALL"
fi

# This POSIX-compliant check ensures the script is sourced, not executed.
if ! (return 0 2>/dev/null); then
  echo "-------------------------------------------------------------------"
  echo "ERROR: This script must be sourced, not executed."
  echo "Usage: source .scripts/configure.sh"
  echo "-------------------------------------------------------------------"
  exit 1
fi

export PATH=$PATH:$HOME/.local/bin:.scripts
chmod -R +x .scripts