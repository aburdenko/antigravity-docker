#!/bin/bash

# Define the source and destination directories
SOURCE_DIR="/home/user/gemini_playground/agents/rag-agent"
DEST_DIR="/home/user/gemini_playground/agents/rag-agent/eval_sets"

# Create the destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Find and move .evalset.json files
find "$SOURCE_DIR" -maxdepth 1 -type f -name "*.evalset.json" -exec mv {} "$DEST_DIR" \;

if [ $? -eq 0 ]; then
    echo "Successfully moved .evalset.json files from $SOURCE_DIR to $DEST_DIR"
else
    echo "Error moving .evalset.json files."
fi