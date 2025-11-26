#!/usr/bin/env python3

import os
import subprocess
import argparse
import json
import sys

def run_evaluation(use_evalset_files: bool, all_time: bool, session_id: str | None = None) -> dict:
    """
    Runs the evaluation script with specified arguments.
    Returns a dictionary with status and output/error messages.
    """
    script_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "eval_agent.py"))
    configure_script_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "configure.sh"))

    command = [
        "bash", "-c",
        f". {configure_script_path} && {script_path}"
    ]

    if use_evalset_files:
        command.append("--use-evalset-files")
    if all_time:
        command.append("--all-time")
    # If a specific session_id is provided, we would need to modify eval_agent.py
    # to accept a session_id argument for filtering, or filter the evalset files here.
    # For now, we assume --use-evalset-files will process all available evalsets.

    try:
        # Run the command and capture output
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return {
            "status": "success",
            "stdout": result.stdout,
            "stderr": result.stderr
        }
    except subprocess.CalledProcessError as e:
        return {
            "status": "error",
            "stdout": e.stdout,
            "stderr": e.stderr,
            "message": f"Evaluation script failed with exit code {e.returncode}"
        }
    except Exception as e:
        return {
            "status": "error",
            "stdout": "",
            "stderr": str(e),
            "message": "An unexpected error occurred while running the evaluation script."
        }

def main():
    parser = argparse.ArgumentParser(description="API wrapper for running evaluation script.")
    parser.add_argument(
        "--use-evalset-files",
        action="store_true",
        help="Run evaluation using local .evalset.json files."
    )
    parser.add_argument(
        "--all-time",
        action="store_true",
        help="Process all logs, ignoring the last run timestamp."
    )
    parser.add_argument(
        "--session-id",
        type=str,
        default=None,
        help="Optional: Evaluate a specific session ID."
    )
    args = parser.parse_args()

    result = run_evaluation(args.use_evalset_files, args.all_time, args.session_id)
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
