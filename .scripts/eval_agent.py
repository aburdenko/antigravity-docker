#!/usr/bin/env python3
import argparse
import base64
import io
import json
import os
import sys
from datetime import datetime, timedelta

import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import vertexai
from google.api_core import exceptions as google_exceptions
from google.cloud import aiplatform, aiplatform_v1, logging, storage
from vertexai.preview.evaluation import AutoraterConfig, CustomMetric, EvalTask

matplotlib.use("Agg")


# Add the 'rag-agent' directory to the Python path
sys.path.insert(
    0,
    os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "agents", "rag-agent")
    ),
)


PROJECT_ID = os.environ.get("PROJECT_ID", "your-gcp-project-id")
LOCATION = os.environ.get("REGION", "us-central1")
BUCKET_NAME = os.environ.get("STAGING_GCS_BUCKET", "your-bucket-name")
SHORT_LOG_NAME = os.environ.get("LOG_NAME", "run_gemini_from_file")
EXPERIMENT_NAME = "gemini-playground-evaluation"
LOG_NAME = f"projects/{PROJECT_ID}/logs/{SHORT_LOG_NAME}"
JUDGEMENT_MODEL_NAME = os.environ.get("JUDGEMENT_MODEL_NAME", "gemini-1.5-flash")

TIMESTAMP_FILE = "last_run_timestamp.txt"


def _contains_words_metric_function(test_case: dict) -> dict:
    response = test_case.get("response", "")
    reference = test_case.get("reference", "")

    if not response or not reference:
        return {"contains_words": 0.0}

    words_to_check = [word.strip() for word in reference.split(" ") if word.strip()]
    contains_all_words = all(word in response for word in words_to_check)

    score = 1.0 if contains_all_words else 0.0
    return {"contains_words": score}


def get_last_run_timestamp():
    try:
        with open(TIMESTAMP_FILE, "r") as f:
            return f.read().strip()
    except FileNotFoundError:
        return (datetime.utcnow() - timedelta(days=1)).isoformat() + "Z"


def save_current_timestamp():
    with open(TIMESTAMP_FILE, "w") as f:
        f.write(datetime.utcnow().isoformat() + "Z")


def get_logs_for_evaluation(
    last_run_timestamp: str | None, filter_session_id: str | None = None
) -> tuple[pd.DataFrame | None, pd.DataFrame | None]:
    logging_client = logging.Client(project=PROJECT_ID)
    base_filter = (
        f'logName="{LOG_NAME}" AND '
        f"(jsonPayload.session_id:* OR jsonPayload.request_id:*)"
    )
    log_filter = (
        f'{base_filter} AND timestamp >= "{last_run_timestamp}"'
        if last_run_timestamp
        else base_filter
    )

    agent_sessions_raw_logs = {}
    simple_sessions_raw_logs = {}

    for entry in logging_client.list_entries(filter_=log_filter):
        payload = {}
        if hasattr(entry, "payload") and isinstance(entry.payload, dict):
            payload = entry.payload
        elif hasattr(entry, "payload") and isinstance(entry.payload, str):
            payload = {"message": entry.payload}
        elif hasattr(entry, "json_payload"):
            payload = entry.json_payload
        elif hasattr(entry, "text_payload"):
            payload = {"message": entry.text_payload}
        else:
            payload = {"message": "Unsupported log entry type"}

        session_id = payload.get("session_id")
        request_id = payload.get("request_id")

        if (
            filter_session_id
            and session_id != filter_session_id
            and request_id != filter_session_id
        ):
            continue

        if payload.get("log_type") in ["user_message", "final_answer"]:
            session_id = payload.get("session_id")
            if session_id:
                if session_id not in agent_sessions_raw_logs:
                    agent_sessions_raw_logs[session_id] = []
                agent_sessions_raw_logs[session_id].append(
                    {"entry": entry, "payload": payload}
                )
        elif request_id and "prompt" in payload and "response" in payload:
            if request_id not in simple_sessions_raw_logs:
                simple_sessions_raw_logs[request_id] = []
            simple_sessions_raw_logs[request_id].append(
                {"entry": entry, "payload": payload}
            )

    agent_sessions_data = []
    simple_sessions_data = []

    for session_id, raw_logs in agent_sessions_raw_logs.items():
        sorted_raw_logs = sorted(raw_logs, key=lambda x: x["entry"].timestamp)
        user_messages = [
            log["payload"]
            for log in sorted_raw_logs
            if log["payload"].get("log_type") == "user_message"
        ]
        final_answers = [
            log["payload"]
            for log in sorted_raw_logs
            if log["payload"].get("log_type") == "final_answer"
        ]

        for i in range(min(len(user_messages), len(final_answers))):
            user_payload = user_messages[i]
            final_answer_payload = final_answers[i]

            user_content = user_payload.get("prompt") or user_payload.get(
                "message", ""
            ).replace("ADK Web Log: Middleware triggered for prompt: ", "")
            agent_response = final_answer_payload.get("final_answer")
            reference = final_answer_payload.get("ground_truth")
            ground_truth_payload = final_answer_payload.get("ground_truth", {})
            metric_type_from_payload = ground_truth_payload.get(
                "metric_type", "default_agent_metric"
            )

            if user_content and agent_response:
                agent_sessions_data.append(
                    {
                        "eval_id": f"{session_id}-{i}",
                        "session_id": session_id,
                        "user_content": user_content,
                        "agent_response": agent_response,
                        "reference": reference,
                        "metric_type": metric_type_from_payload,
                        "metric_value": "",
                        "ground_truth": ground_truth_payload,
                    }
                )

    for request_id, raw_logs in simple_sessions_raw_logs.items():
        prompt, response, reference = "", "", ""
        sorted_raw_logs = sorted(raw_logs, key=lambda x: x["entry"].timestamp)

        for log_item in sorted_raw_logs:
            payload = log_item["payload"]
            if "prompt" in payload:
                prompt = payload["prompt"]
            if "response" in payload:
                response = payload["response"]
            if "ground_truth" in payload:
                reference = payload["ground_truth"]

        if prompt and response:
            simple_sessions_data.append(
                {
                    "eval_id": request_id,
                    "session_id": request_id,
                    "user_content": prompt,
                    "agent_response": response,
                    "reference": reference,
                    "metric_type": "simple",
                    "metric_value": "",
                }
            )

    agent_df = pd.DataFrame(agent_sessions_data) if agent_sessions_data else None
    simple_df = pd.DataFrame(simple_sessions_data) if simple_sessions_data else None

    return agent_df, simple_df


def export_sessions_to_evalset(last_run_timestamp: str | None):
    """Fetches agent logs and exports each session to a separate .evalset.json file."""
    print("Fetching logs from Cloud Logging to export as eval sets...")
    agent_df, simple_df = get_logs_for_evaluation(last_run_timestamp)

    if (agent_df is None or agent_df.empty) and (
        simple_df is None or simple_df.empty
    ):
        print("No new logs found to export.")
        return

    output_dir = os.path.join(
        os.path.dirname(__file__), "..", "agents", "rag-agent", "eval_sets"
    )
    os.makedirs(output_dir, exist_ok=True)
    print(
        f"Found {len(agent_df) if agent_df is not None else 0} agent session(s) and "
        f"{len(simple_df) if simple_df is not None else 0} simple log(s). "
        f"Exporting to: {output_dir}"
    )

    if agent_df is not None and not agent_df.empty:
        for session_id, group_df in agent_df.groupby("session_id"):
            conversation_turns = []
            sorted_group_df = group_df.sort_values(by="eval_id")

            for _, row in sorted_group_df.iterrows():
                turn = {
                    "user_content": {"parts": [{"text": row["user_content"]}]},
                    "final_response": {"parts": [{"text": row["agent_response"]}]},
                }
                if row["reference"]:
                    turn["expected_final_response"] = {
                        "parts": [{"text": row["reference"]}]
                    }
                conversation_turns.append(turn)

            ground_truth_obj = (
                group_df["ground_truth"].iloc[0]
                if "ground_truth" in group_df.columns
                else {}
            )
            eval_set = {
                "eval_set_id": session_id,
                "eval_cases": [
                    {
                        "eval_id": f"case-{session_id}",
                        "conversation": conversation_turns,
                        "ground_truth": ground_truth_obj,
                    }
                ],
            }
            output_filename = os.path.join(
                output_dir, f"rag-agent.evalset.{session_id}.json"
            )
            with open(output_filename, "w") as f:
                json.dump(eval_set, f, indent=2)
            print(
                f"  - Successfully exported agent session {session_id} to {output_filename}"
            )

    if simple_df is not None and not simple_df.empty:
        for _, row in simple_df.iterrows():
            request_id = row["session_id"]
            conversation_turns = [
                {
                    "user_content": {"parts": [{"text": row["user_content"]}]},
                    "final_response": {"parts": [{"text": row["agent_response"]}]},
                }
            ]
            if row["reference"]:
                conversation_turns[-1]["expected_final_response"] = {
                    "parts": [{"text": row["reference"]}]
                }

            ground_truth_obj = {
                "reference": row["reference"],
                "metric_type": row["metric_type"],
            }
            eval_set = {
                "eval_set_id": request_id,
                "eval_cases": [
                    {
                        "eval_id": f"case-{request_id}",
                        "conversation": conversation_turns,
                        "ground_truth": ground_truth_obj,
                    }
                ],
            }
            output_filename = os.path.join(
                output_dir, f"rag-agent.evalset.{request_id}.json"
            )
            with open(output_filename, "w") as f:
                json.dump(eval_set, f, indent=2)
            print(f"  - Successfully exported simple ADK web log to {output_filename}")


def generate_radar_chart(
    all_summary_metrics_data: list[tuple[dict, str]], current_time_str: str
) -> str:
    """Generates a radar chart from multiple sets of summary metrics and returns it as a base64 PNG."""
    if not all_summary_metrics_data:
        return ""

    all_labels = set()
    for summary_metrics, _ in all_summary_metrics_data:
        for key in summary_metrics.keys():
            if "/mean" in key:
                all_labels.add(key.replace("/mean", ""))

    if not all_labels:
        return ""

    clean_labels = sorted(list(all_labels))
    num_vars = len(clean_labels)
    angles = np.linspace(0, 2 * np.pi, num_vars, endpoint=False).tolist()
    angles += angles[:1]

    fig, ax = plt.subplots(figsize=(8, 8), subplot_kw=dict(polar=True))

    for summary_metrics, run_name_suffix in all_summary_metrics_data:
        scores = [
            summary_metrics.get(f"{label}/mean", 0.0) for label in clean_labels
        ]
        scores += scores[:1]

        ax.plot(angles, scores, linewidth=2, label=f"Performance ({run_name_suffix})")
        ax.fill(angles, scores, alpha=0.1)

    ax.set_yticklabels([])
    ax.set_ylim(0, 1)
    ax.set_xticks(angles[:-1])
    ax.set_xticklabels(clean_labels)
    ax.set_title(
        f"Evaluation of Gemini Runs ({current_time_str})",
        size=12,
        color="black",
        va="bottom",
    )
    ax.grid(True)
    ax.legend(loc="upper right", bbox_to_anchor=(1.3, 1.1))

    pic_io = io.BytesIO()
    plt.savefig(pic_io, format="png", bbox_inches="tight", dpi=150)
    plt.close(fig)
    pic_io.seek(0)
    return base64.b64encode(pic_io.read()).decode("utf-8")


def generate_metrics_csv(metrics_df: pd.DataFrame) -> str:
    """Generates a CSV string from a metrics DataFrame."""
    return metrics_df.to_csv(index=False)


def run_evaluation_and_generate_artifacts(
    eval_df: pd.DataFrame | None = None,
    all_time: bool = False,
    session_id: str | None = None,
):
    """
    Runs the main evaluation flow.
    Args:
        all_time: If True, fetches all logs. Otherwise, fetches logs since the last run.
    """
    current_time_str = datetime.now().strftime("%Y%m%d%H%M%S")
    aiplatform.init(
        project=PROJECT_ID, location=LOCATION, experiment=EXPERIMENT_NAME
    )

    storage_client = storage.Client(project=PROJECT_ID)
    bucket = storage_client.bucket(BUCKET_NAME.replace("gs://", ""))

    last_run = None if all_time else get_last_run_timestamp()

    if eval_df is not None:
        if not eval_df.empty:
            agent_df = eval_df[
                eval_df["ground_truth"].apply(
                    lambda x: x.get("metric_type") != "simple"
                )
            ]
            simple_df = eval_df[
                eval_df["ground_truth"].apply(
                    lambda x: x.get("metric_type") == "simple"
                )
            ]
            agent_df = None if agent_df.empty else agent_df
            simple_df = None if simple_df.empty else simple_df
        else:
            agent_df, simple_df = pd.DataFrame(), pd.DataFrame()
    else:
        agent_df, simple_df = get_logs_for_evaluation(last_run, session_id)

    artifacts = []
    all_metrics_dfs = []
    all_summary_metrics_data = []
    final_combined_df = None

    if agent_df is not None and not agent_df.empty:
        storage_client = storage.Client(project=PROJECT_ID)
        bucket = storage_client.bucket(BUCKET_NAME.replace("gs://", ""))

        def get_metric_type(gt):
            return gt.get("metric_type") if isinstance(gt, dict) else None

        agent_df["metric_type"] = agent_df["ground_truth"].apply(get_metric_type)
        agent_df["metric_type"].fillna("simple", inplace=True)

        for metric_type, group_df_original in agent_df.groupby("metric_type"):
            if not metric_type:
                print(
                    f"Skipping evaluation for {len(group_df_original)} rows with no metric_type."
                )
                continue

            if metric_type == "MANUAL":
                print(
                    f"Skipping automatic metric calculation for {len(group_df_original)} rows with MANUAL metric_type."
                )
                continue

            group_df = group_df_original[
                ["response", "reference", "session_id", "prompt"]
            ]
            group_df = group_df.replace("", np.nan)
            essential_columns = (
                ["response", "reference"]
                if metric_type in ["rouge", "bleu", "contains_words"]
                else ["response"]
            )
            group_df = group_df.dropna(subset=essential_columns, how="any")

            if group_df.empty:
                print(
                    f"Skipping evaluation for {metric_type} due to empty DataFrame after dropping NaNs."
                )
                continue

            group_df = group_df.reset_index(drop=True)

            try:
                (
                    summary_metrics,
                    metrics_df,
                    _,
                ) = _execute_evaluation_run_for_artifacts(
                    group_df,
                    metric_type=metric_type,
                    run_name_suffix=f"-{metric_type}",
                    experiment_name=EXPERIMENT_NAME,
                    current_time_str=current_time_str,
                )
            except Exception as e:
                print(f"Error during evaluation for metric_type {metric_type}: {e}")
                continue

            if summary_metrics:
                all_summary_metrics_data.append((summary_metrics, metric_type))
            if metrics_df is not None and "session_id" in metrics_df.columns:
                metrics_df["metric_type"] = metric_type
                all_metrics_dfs.append(metrics_df)
            elif metrics_df is not None:
                print(
                    f"Metrics DataFrame for {metric_type} is missing 'session_id'. Skipping."
                )

    if simple_df is not None and not simple_df.empty:
        simple_df_cleaned = simple_df[
            ["response", "reference", "prompt", "session_id"]
        ]
        simple_df_cleaned = simple_df_cleaned.replace("", np.nan)
        simple_df_cleaned = simple_df_cleaned.dropna(subset=["response"], how="any")

        if simple_df_cleaned.empty:
            print("Skipping simple evaluation due to empty DataFrame after cleaning.")
        else:
            simple_df_cleaned = simple_df_cleaned.reset_index(drop=True)
            try:
                (
                    summary_metrics,
                    metrics_df,
                    _,
                ) = _execute_evaluation_run_for_artifacts(
                    eval_df=simple_df_cleaned,
                    metric_type="simple",
                    run_name_suffix="-simple",
                    experiment_name=EXPERIMENT_NAME,
                    current_time_str=current_time_str,
                )
                if summary_metrics:
                    all_summary_metrics_data.append((summary_metrics, "simple"))
                if metrics_df is not None:
                    all_metrics_dfs.append(metrics_df)
            except Exception as e:
                print(f"Error during simple evaluation: {e}")

    if all_summary_metrics_data:
        combined_radar_chart_base64 = generate_radar_chart(
            all_summary_metrics_data, current_time_str
        )
        if combined_radar_chart_base64:
            combined_radar_chart_filename = (
                f"all_metrics_radar_chart_{current_time_str}.png"
            )
            blob = bucket.blob(
                f"evaluation_artifacts/combined/{combined_radar_chart_filename}"
            )
            blob.upload_from_string(
                base64.b64decode(combined_radar_chart_base64),
                content_type="image/png",
            )
            gcs_uri = f"gs://{bucket.name}/{blob.name}"
            artifacts.append(
                {
                    "id": "all_metrics_radar_chart",
                    "versionId": current_time_str,
                    "mimeType": "image/png",
                    "gcsUrl": gcs_uri,
                    "data": "data:image/png;base64," + combined_radar_chart_base64,
                }
            )
            print(f"Combined radar chart uploaded to: {gcs_uri}")

            eval_sets_dir = os.path.join(
                os.path.dirname(__file__), "..", "agents", "rag-agent", "eval_sets"
            )
            local_path = os.path.join(eval_sets_dir, combined_radar_chart_filename)
            blob.download_to_filename(local_path)
            print(f"Combined radar chart downloaded to: {local_path}")

    if all_metrics_dfs:
        processed_dfs_for_concat = []
        for df in all_metrics_dfs:
            if df.empty or "metric_type" not in df.columns:
                continue

            score_cols = [
                col
                for col in df.columns
                if col
                not in [
                    "session_id",
                    "response",
                    "reference",
                    "metric_type",
                    "prompt",
                    "conversation",
                    "ground_truth",
                ]
            ]
            if score_cols:
                temp_df = df[["session_id"] + score_cols].copy()
                melted_df = temp_df.melt(
                    id_vars=["session_id"],
                    var_name="metric_type",
                    value_name="metric_value",
                )
                melted_df["metric_type"] = melted_df["metric_type"].str.replace(
                    "_score", ""
                )
                processed_dfs_for_concat.append(melted_df)

        if processed_dfs_for_concat:
            final_combined_df = pd.concat(processed_dfs_for_concat, ignore_index=True)
            final_combined_df = final_combined_df[
                ["session_id", "metric_type", "metric_value"]
            ]
        else:
            final_combined_df = pd.DataFrame(
                columns=["session_id", "metric_type", "metric_value"]
            )

    if not all_time:
        save_current_timestamp()

    return artifacts, final_combined_df


def _execute_evaluation_run_for_artifacts(
    eval_df: pd.DataFrame,
    metric_type: str,
    run_name_suffix: str,
    experiment_name: str,
    current_time_str: str,
):
    metric_type = metric_type.strip()
    run_name = (
        f"custom-metric-{current_time_str}"
        if metric_type == "contains_words"
        else f"{metric_type.lower().replace('_', '-')}-{current_time_str}"
    )
    full_judgement_model_name = f"projects/{PROJECT_ID}/locations/{LOCATION}/publishers/google/models/{JUDGEMENT_MODEL_NAME}"
    autorater_config = AutoraterConfig(autorater_model=full_judgement_model_name)

    if metric_type == "contains_words":
        metrics_to_apply = [
            CustomMetric(
                name="contains_words", metric_function=_contains_words_metric_function
            )
        ]
    elif metric_type == "bleu":
        metrics_to_apply = ["bleu"]
    elif metric_type == "rouge":
        metrics_to_apply = ["rouge"]
    elif metric_type == "simple":
        metrics_to_apply = ["fluency", "coherence", "safety"]
        if not eval_df["reference"].replace("", np.nan).dropna().empty:
            metrics_to_apply.extend(["rouge", "bleu"])
    else:
        metrics_to_apply = ["fluency", "coherence", "safety"]
        if not eval_df["reference"].replace("", np.nan).dropna().empty:
            metrics_to_apply.extend(["rouge", "bleu"])

    eval_task = EvalTask(
        dataset=eval_df,
        metrics=metrics_to_apply,
        autorater_config=autorater_config,
    )
    evaluation_result = eval_task.evaluate(experiment_run_name=run_name)
    metrics_table = evaluation_result.metrics_table

    if metrics_table is not None:
        metrics_table["metric_type"] = metric_type
        if "session_id" in eval_df.columns and len(eval_df) == len(metrics_table):
            metrics_table["session_id"] = eval_df["session_id"].reset_index(drop=True)
        else:
            print(
                f"Warning: session_id mismatch for metric_type {metric_type}. Cannot add to metrics_table."
            )

    return evaluation_result.summary_metrics, metrics_table, None


def main():
    parser = argparse.ArgumentParser(
        description="Run evaluation or export agent sessions from logs."
    )
    parser.add_argument(
        "--export-sessions",
        action="store_true",
        help="Export sessions to .evalset.json files.",
    )
    parser.add_argument(
        "--all-time",
        action="store_true",
        help="Process all logs, ignoring the last run timestamp.",
    )
    parser.add_argument(
        "--use-evalset-files",
        action="store_true",
        help="Run evaluation using local .evalset.json files.",
    )
    parser.add_argument(
        "--evalset-file",
        type=str,
        help="Path to a specific .evalset.json file for evaluation.",
    )
    parser.add_argument(
        "--output-csv-path",
        type=str,
        help="Path to save combined evaluation results CSV.",
    )
    parser.add_argument(
        "--session-id",
        type=str,
        help="Filter logs by a specific session ID.",
    )
    parser.add_argument(
        "--export-to-csv", action="store_true", help="Export logs to a CSV file."
    )
    args = parser.parse_args()

    if args.export_to_csv:
        agent_df, simple_df = get_logs_for_evaluation(
            None, filter_session_id=args.session_id
        )
        combined_df_list = []
        if agent_df is not None and not agent_df.empty:
            combined_df_list.append(agent_df)
        if simple_df is not None and not simple_df.empty:
            combined_df_list.append(simple_df)

        if combined_df_list:
            combined_df = pd.concat(combined_df_list, ignore_index=True)
            required_columns = [
                "eval_id",
                "session_id",
                "user_content",
                "agent_response",
                "reference",
                "metric_type",
                "metric_value",
            ]
            for col in required_columns:
                if col not in combined_df.columns:
                    combined_df[col] = ""

            df_to_export = combined_df[required_columns].copy()
            df_to_export = df_to_export[
                df_to_export["user_content"].astype(bool)
                & df_to_export["agent_response"].astype(bool)
            ]
            df_to_export.dropna(
                subset=["user_content", "agent_response"], how="all", inplace=True
            )

            output_path = os.path.join(
                os.path.dirname(__file__),
                "..",
                "agents",
                "rag-agent",
                "eval_sets",
                "eval_test_cases.csv",
            )
            df_to_export.to_csv(output_path, index=False)
            print(f"Successfully exported logs to {output_path}")
        else:
            print("No logs found to export.")
        return

    if args.export_sessions:
        timestamp = None if args.all_time else get_last_run_timestamp()
        export_sessions_to_evalset(timestamp)
        if not args.all_time:
            save_current_timestamp()

    elif args.use_evalset_files:
        print("Moving evalset files to the eval_sets folder...")
        script_dir = os.path.dirname(__file__)
        move_script_path = os.path.join(script_dir, "move_evalsets.sh")
        if not os.path.exists(move_script_path):
            move_script_path = (
                "/home/user/gemini_playground/.scripts/move_evalsets.sh"
            )
        if os.path.exists(move_script_path):
            os.system(move_script_path)
        else:
            print(f"Warning: move_evalsets.sh not found.")

        all_eval_cases = []
        files_to_process = (
            [args.evalset_file]
            if args.evalset_file
            else os.listdir(
                os.path.join(
                    os.path.dirname(__file__), "..", "agents", "rag-agent", "eval_sets"
                )
            )
        )

        for filename in files_to_process:
            if not (filename.endswith(".json") and (".evalset." in filename or "generated_evalset" in filename)):
                continue

            filepath = (
                filename
                if args.evalset_file
                else os.path.join(
                    os.path.dirname(__file__),
                    "..",
                    "agents",
                    "rag-agent",
                    "eval_sets",
                    filename,
                )
            )
            print(f"Processing evalset file: {os.path.basename(filepath)}")
            with open(filepath, "r") as f:
                eval_set = json.load(f)
                for case in eval_set.get("eval_cases", []):
                    conversation = case.get("conversation", [])
                    ground_truth = case.get("ground_truth", {})
                    case_reference = ground_truth.get(
                        "reference", ""
                    ) or conversation[-1].get("expected_final_response", {}).get("parts", [{}])[0].get("text", "")

                    if conversation:
                        all_eval_cases.append(
                            {
                                "conversation": conversation,
                                "session_id": case.get("eval_id"),
                                "response": conversation[-1]
                                .get("final_response", {})
                                .get("parts", [{}])[0]
                                .get("text", ""),
                                "prompt": conversation[0]
                                .get("user_content", {})
                                .get("parts", [{}])[0]
                                .get("text", ""),
                                "reference": case_reference,
                                "ground_truth": ground_truth,
                            }
                        )
        if all_eval_cases:
            eval_df = pd.DataFrame(all_eval_cases).drop_duplicates(
                subset=["session_id"]
            )
            session_id_from_df = (
                eval_df["session_id"].iloc[0] if not eval_df.empty else None
            )
            _, final_combined_df = run_evaluation_and_generate_artifacts(
                eval_df=eval_df, all_time=args.all_time, session_id=session_id_from_df
            )

            if final_combined_df is not None and not final_combined_df.empty:
                if args.output_csv_path:
                    try:
                        original_df = pd.read_csv(args.output_csv_path)
                        original_df.drop_duplicates(subset=["eval_id"], inplace=True)
                    except FileNotFoundError:
                        original_df = pd.DataFrame()

                    final_combined_df_renamed = final_combined_df.rename(
                        columns={"session_id": "eval_id"}
                    )
                    final_combined_df_unique = (
                        final_combined_df_renamed.drop_duplicates(
                            subset=["eval_id"], keep="first"
                        )
                    )

                    if not original_df.empty:
                        merged_df = pd.merge(
                            original_df,
                            final_combined_df_unique,
                            on="eval_id",
                            how="left",
                            suffixes=("_original", "_new"),
                        )
                        merged_df["metric_type"] = merged_df[
                            "metric_type_new"
                        ].fillna(merged_df["metric_type_original"])
                        merged_df["metric_value"] = merged_df[
                            "metric_value_new"
                        ].fillna(merged_df["metric_value_original"])
                        merged_df.drop(
                            columns=[
                                "metric_type_original",
                                "metric_value_original",
                                "metric_type_new",
                                "metric_value_new",
                            ],
                            inplace=True,
                        )
                    else:
                        merged_df = final_combined_df_renamed

                    merged_df.to_csv(args.output_csv_path, index=False)
                    print(
                        f"Combined evaluation results saved to CSV: {args.output_csv_path}"
                    )
    else:
        run_evaluation_and_generate_artifacts(all_time=args.all_time)


if __name__ == "__main__":
    main()
