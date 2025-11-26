#!/usr/bin/env python3

import os
import sys
import uvicorn
import logging as python_logging



import google.auth
from starlette.middleware.base import BaseHTTPMiddleware
import json
import google.cloud.logging

# --- Configuration & Custom Logger ---
PROJECT_ID = os.environ.get("PROJECT_ID")
if not PROJECT_ID:
    _, PROJECT_ID = google.auth.default()

if not PROJECT_ID:
    raise ValueError("Could not determine GCP project ID.")

print(f"--- Using PROJECT_ID: {PROJECT_ID} ---")

LOCATION = os.environ.get("REGION", "us-central1")
SHORT_LOG_NAME = os.environ.get("LOG_NAME", "run_gemini_from_file")
print(f"--- Using LOG_NAME: {SHORT_LOG_NAME} ---")
from starlette.requests import Request

class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        print(f"DEBUG: LoggingMiddleware entered for path: {request.url.path}")
        
        if "/invoke" in request.url.path or "/run_sse" in request.url.path:
            # Read the request body
            body = await request.body()
            print(f"DEBUG: LoggingMiddleware received body: {body.decode()}")
            
            # Let the request proceed to get the response
            response = await call_next(request)
            
            # Read response body
            response_body = b""
            async for chunk in response.body_iterator:
                response_body += chunk
            print(f"DEBUG: Raw response body: {response_body.decode()}") # Added debug print

            # Recreate response to send to client
            from starlette.responses import Response
            response = Response(content=response_body, status_code=response.status_code, headers=dict(response.headers), media_type=response.media_type)

            # Now, log the relevant information
            try:
                request_data = json.loads(body)
                print(f"DEBUG: LoggingMiddleware parsed request_data: {request_data}")
                prompt = request_data.get("newMessage", {}).get("parts", [{}])[0].get("text", "")
                session_id = request_data.get('sessionId')
                user_id = request_data.get('userId')

                cloud_logger = request.app.state.cloud_logger # Access the logger from app.state

                if prompt:
                    print(f"DEBUG: LoggingMiddleware triggered for prompt: {prompt}")
                    cloud_logger.log_struct(
                        {
                            'prompt': prompt,
                            'session_id': session_id,
                            'user_id': user_id,
                            'request_id': session_id,
                            'log_type': 'user_message'
                        },
                        severity='INFO'
                    )

                # Log agent's final answer
                # Strip "data: " prefix if present, as it's not valid JSON
                response_str = response_body.decode()
                if response_str.startswith("data: "):
                    response_str = response_str[len("data: "):]
                
                response_data = json.loads(response_str)
                agent_response_text = ""
                # Assuming the response structure from ADK's /run_sse or /invoke endpoint
                # This might need adjustment based on actual ADK response format
                if "events" in response_data:
                    for event in response_data["events"]:
                        if event.get("isFinalResponse"):
                            agent_response_text = event.get("content", {}).get("parts", [{}])[0].get("text", "")
                            break
                elif "content" in response_data: # For /invoke endpoint directly
                    agent_response_text = response_data.get("content", {}).get("parts", [{}])[0].get("text", "")

                if agent_response_text:
                    cloud_logger.log_struct(
                        {
                            'final_answer': agent_response_text,
                            'session_id': session_id,
                            'user_id': user_id,
                            'request_id': session_id,
                            'log_type': 'final_answer'
                        },
                        severity='INFO'
                    )

            except (json.JSONDecodeError, KeyError) as e:
                print(f"DEBUG: LoggingMiddleware: Failed to parse JSON body or find data: {e}")
                pass
            return response
        else:
            # If the path does not match, just pass the request through
            return await call_next(request)

# --- App Initialization ---
# We no longer need to set up logging here; it will be passed to uvicorn.run()
from google.adk.cli.fast_api import get_fast_api_app
from fastapi import FastAPI # Import FastAPI for type hinting in lifespan
from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup event: Initialize CloudLoggingHandler
    import google.auth
    from google.cloud import logging as google_cloud_logging
    from google.cloud.logging.handlers import CloudLoggingHandler # Use CloudLoggingHandler

    current_project_id = PROJECT_ID
    if not current_project_id:
        _, current_project_id = google.auth.default()

    if current_project_id:
        client = google_cloud_logging.Client(project=current_project_id)
        app.state.cloud_logging_client = client # Store client in app.state
        app.state.cloud_logger = client.logger(SHORT_LOG_NAME) # Store logger in app.state
        
        # Keep the python_logging handler for other internal logs if needed, but it won't be used by middleware
        cloud_handler = CloudLoggingHandler(client=client, name=SHORT_LOG_NAME)
        root_logger = python_logging.getLogger()
        root_logger.addHandler(cloud_handler)
        root_logger.setLevel(python_logging.DEBUG)
        cloud_handler.setLevel(python_logging.INFO)
        python_logging.info("CloudLoggingHandler attached in worker process.")
    else:
        python_logging.warning("PROJECT_ID not found, CloudLoggingHandler not attached in worker process.")

    yield

    # Shutdown event: Close CloudLoggingHandler
    root_logger = python_logging.getLogger()
    for handler in root_logger.handlers:
        if isinstance(handler, CloudLoggingHandler): # Check for CloudLoggingHandler
            handler.close()
            root_logger.removeHandler(handler)
            python_logging.info("CloudLoggingHandler closed in worker process.")

app = get_fast_api_app(
    agents_dir=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'agents')),
    web=True,
    lifespan=lifespan,
)
app.add_middleware(LoggingMiddleware)

if __name__ == "__main__":
    print("--- Starting ADK Web Server with custom logging ---")
    print("ADK will manage its own internal OpenTelemetry tracing.")
    uvicorn.run(
        "run_adk_web_with_logging:app",
        host="127.0.0.1",
        port=8001,
        reload=True, # This enables auto-reloading
    )