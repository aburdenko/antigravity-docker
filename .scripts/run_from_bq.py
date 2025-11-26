#!/usr/bin/env python3
# Install required libraries first:
# pip install --upgrade google-cloud-aiplatform google-cloud-bigquery

import vertexai
from vertexai.generative_models import GenerativeModel, Tool, grounding
from google.cloud import bigquery
import time

# --- Your Configuration ---
PROJECT_ID = "kallogjeri-project-345114"
LOCATION = "us-central1"
DATASTORE_PATH = "projects/kallogjeri-project-345114/locations/global/collections/default_collection/dataStores/as_hcls_demo"

# BigQuery Details
BQ_SOURCE_TABLE = "kallogjeri-project-345114.test_upload.test"  # Table with prompts
BQ_PROMPT_COLUMN = "GUIDELINE"  # The column in your source table containing the prompts
BQ_DESTINATION_TABLE = "kallogjeri-project-345114.test_upload.test" # Table to store results

# --- Main Functions ---

def get_grounded_response(model, prompt: str) -> str:
    """Calls the Gemini model with a pre-configured grounding tool."""
    try:
        # Add a small delay to avoid hitting rate limits on very fast loops
        time.sleep(1) 
        response = model.generate_content(prompt)
        return response.text
    except Exception as e:
        print(f"Error processing prompt '{prompt[:50]}...': {e}")
        return f"Error: {e}"

def process_prompts_in_batch():
    """Reads prompts from BigQuery, gets grounded responses, and saves them back to BigQuery."""

    print("Initializing Vertex AI and BigQuery clients...")
    vertexai.init(project=PROJECT_ID, location=LOCATION)
    bq_client = bigquery.Client(project=PROJECT_ID)

    # 1. Configure the grounding tool
    grounding_tool = Tool.from_retrieval(
        retrieval=grounding.Retrieval(source=grounding.VertexAISearch(datastore=DATASTORE_PATH))
    )

    # 2. Load the Gemini model once with the tool
    model = GenerativeModel(
        "gemini-2.5-flash",
        tools=[grounding_tool]
    )

    # 3. Read prompts from the source BigQuery table
    print(f"Reading prompts from table: {BQ_SOURCE_TABLE}")
    query = f"SELECT {BQ_PROMPT_COLUMN} FROM `{BQ_SOURCE_TABLE}`"
    query_job = bq_client.query(query)  # API request
    prompts = [row[0] for row in query_job]
    print(f"Found {len(prompts)} prompts to process.")

    # 4. Process each prompt and collect the results
    results_to_insert = []
    for i, prompt_text in enumerate(prompts):
        print(f"Processing prompt {i+1}/{len(prompts)}...")
        response_text = get_grounded_response(model, prompt_text)
        results_to_insert.append({
            "prompt": prompt_text,
            "grounded_response": response_text,
        })
        
    # 5. Write the results to the destination BigQuery table
    if not results_to_insert:
        print("No results to write.")
        return

    print(f"Writing {len(results_to_insert)} results to {BQ_DESTINATION_TABLE}...")
    # This will create the table if it doesn't exist, based on the schema of the first row.
    job_config = bigquery.LoadJobConfig(autodetect=True, write_disposition="WRITE_APPEND")
    
    load_job = bq_client.load_table_from_json(
        results_to_insert,
        BQ_DESTINATION_TABLE,
        job_config=job_config
    )
    load_job.result() # Wait for the job to complete
    print("Batch processing complete.")


# --- Run the script ---
if __name__ == "__main__":
    process_prompts_in_batch()
