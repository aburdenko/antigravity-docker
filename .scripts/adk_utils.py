import json
import logging

from opentelemetry.sdk.trace.export import SpanExporter, SpanExportResult
from opentelemetry.trace import Span


class CloudTraceLoggingSpanExporter(SpanExporter):
    """
    An OpenTelemetry SpanExporter that logs spans to Google Cloud Logging.

    This allows trace data to be captured and viewed within Cloud Logging,
    which is useful for debugging and analysis alongside regular application logs.
    """

    def __init__(self, project_id: str):
        self.project_id = project_id

    def export(self, spans: list[Span]) -> SpanExportResult:
        for span in spans:
            # The ADK uses this specific log name for its trace data.
            logging.info("ADK Trace", extra={"json_fields": json.loads(span.to_json())})
        return SpanExportResult.SUCCESS

    def shutdown(self) -> None:
        pass