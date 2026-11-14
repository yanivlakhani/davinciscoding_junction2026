"""Read copied FallApp timing logs; no device, network, or media access.

Usage: python3 tools/assess_capture_latency.py /path/to/copied/FallApp --output report.json
Disconnect monitoring before copying logs so each JSONL snapshot is complete.
"""
import argparse
import json
import math
from pathlib import Path


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


def read_lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def distribution(values):
    values = sorted(value for value in values if value is not None)
    if not values:
        return None
    return {"count": len(values), "min": values[0], "p50": values[math.ceil(len(values) * .5) - 1],
            "p95": values[math.ceil(len(values) * .95) - 1], "max": values[-1]}


def difference(row, end, start):
    if not row.get(end) or not row.get(start):
        return None
    return (int(row[end]) - int(row[start])) / 1e6


def assess(root):
    sessions = []
    for directory in sorted((root / "sessions").glob("*")):
        raw = read_lines(directory / "motion.jsonl")
        timings = read_lines(directory / "latency.jsonl")
        sessions.append({
            "session_id": directory.name,
            "profile": read_json(directory / "session.json").get("runtime_options", {}),
            "session_end": read_json(directory / "session-end.json"),
            "motion_callback_gap_ms": distribution([(int(b["phone_receipt_ns"]) - int(a["phone_receipt_ns"])) / 1e6
                                                    for a, b in zip(raw, raw[1:])]),
            "acquisition_to_actor_ms": distribution([difference(r, "actorEntryNs", "phoneReceiptNs") for r in timings]),
            "actor_entry_to_processing_ms": distribution([difference(r, "processingStartNs", "actorEntryNs") for r in timings]),
            "detector_compute_ms": distribution([difference(r, "detectorEndNs", "processingStartNs")
                                                  for r in timings if r.get("detectorEndNs")]),
        })
    streams = []
    stream_rows = {}
    for directory in sorted((root / "camera-streams").glob("*")):
        rows = read_lines(directory / "timeline.jsonl")
        stream_rows[directory.name] = rows
        def first(kind):
            return next((r for r in rows if r.get("kind") == kind), {})
        frames = [r for r in rows if r.get("kind") == "frame"]
        def interval(end, start):
            return difference({"end": first(end).get("phoneUptimeNs"), "start": first(start).get("phoneUptimeNs")}, "end", "start")
        streams.append({
            "stream_id": directory.name, "codec": first("camera_attach_begin").get("codec"),
            "session_id": first("camera_attach_begin").get("sessionId"),
            "start_reason": first("camera_start_requested").get("reason"),
            "request_to_attach_ms": interval("camera_attach_begin", "camera_start_requested"),
            "attach_call_ms": interval("camera_attach_end", "camera_attach_begin"),
            "start_call_ms": interval("stream_start_return", "stream_start_begin"),
            "command_to_first_frame_ms": interval("frame", "camera_attach_begin"),
            "frame_callback_work_ms": distribution([difference(r, "callbackEndNs", "phoneUptimeNs") for r in frames]),
            "frame_callback_gap_ms": distribution([(int(b["phoneUptimeNs"]) - int(a["phoneUptimeNs"])) / 1e6
                                                    for a, b in zip(frames, frames[1:])]),
            "trace_end": first("trace_end"),
            "sdk_errors": [r for r in rows if r.get("kind") == "stream_error"],
            "camera_detached": first("camera_detached"),
        })
    captures = []
    for directory in sorted((root / "captures").glob("*")):
        trigger = read_json(directory / "trigger.json")
        timing = read_json(directory / "timing.json")
        rows = stream_rows.get(trigger.get("streamTraceID"), [])
        decision = int(trigger.get("decisionPhoneUptimeNs") or 0)
        next_frame = next((r for r in rows if r.get("kind") == "frame" and int(r["phoneUptimeNs"]) >= decision), None)
        captures.append({
            "event_id": directory.name, "policy": trigger.get("cameraPolicy", "legacy_onRed"),
            "stream_codec": trigger.get("streamCodec", "legacy_raw"),
            "complete": read_json(directory / "capture.json").get("complete", False),
            "camera_command_to_first_saved_frame_ms": difference({"first": timing.get("firstFramePhoneReceiptNs"),
                "command": trigger.get("commandPhoneUptimeNs")}, "first", "command"),
            "red_to_next_live_frame_ms": (int(next_frame["phoneUptimeNs"]) - decision) / 1e6 if next_frame else None,
            "first_saved_frame_relative_to_red_ms": difference({"first": timing.get("firstFramePhoneReceiptNs"),
                "red": trigger.get("decisionPhoneUptimeNs")}, "first", "red"),
            "writer_finalize_ms": difference(timing, "writerFinalizeEndNs", "writerFinalizeStartNs"),
            "jpeg_extraction_ms": difference(timing, "jpegExtractionEndNs", "jpegExtractionStartNs"),
            "buffer": read_json(directory / "buffer.json"),
            "writer_backpressure_drops": timing.get("writerBackpressureDrops"),
            "attempt_failures": [read_json(p) for p in sorted(directory.glob("attempt-*-error.json"))],
        })
    requests = {}
    for row in read_lines(root / "network.jsonl"):
        identifier = row.get("requestID")
        if not identifier:
            continue
        request = requests.setdefault(identifier, {"request_id": identifier, "metrics": []})
        if row.get("kind") == "http_metrics":
            request["metrics"].append(row)
        elif row.get("kind") == "http_begin":
            request.update({"phase": row.get("phase"), "event_id": row.get("eventId"), "start_ns": row.get("phoneUptimeNs")})
        else:
            request.update({"outcome": row.get("kind"), "end_ns": row.get("phoneUptimeNs"),
                            "status": row.get("status"), "error_domain": row.get("errorDomain"), "error_code": row.get("errorCode")})
    for request in requests.values():
        request["duration_ms"] = difference(request, "end_ns", "start_ns")
    return {"sessions": sessions, "streams": streams, "captures": captures, "network_requests": list(requests.values()),
            "limits": ["All computed differences use phone monotonic uptime only.",
                "A buffered first saved frame may precede red; its negative offset is valid pre-roll, not negative latency.",
                "SDK/OS upstream sampling and transport cannot be isolated without additional upstream timestamps.",
                "An absent trace_end or session-end means the snapshot may be incomplete.",
                "No upload duration or full-video server receipt is inferred from these files."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = assess(args.logs)
    value = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(value)
    else:
        print(value, end="")


if __name__ == "__main__":
    main()
