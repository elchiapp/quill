"""Score all measured speech lanes without best-of-repeat accuracy selection."""
import json
import runpy
import statistics
import sys
from collections import defaultdict
from pathlib import Path

helpers = runpy.run_path(str(Path(__file__).with_name("asr-accuracy-score.py")))
score, totals, bootstrap = (helpers[key] for key in ("score", "totals", "bootstrap"))
root = Path(sys.argv[1]).resolve()
manifest = json.loads((root / "data/manifest.json").read_text())
samples = {sample["id"]: sample for sample in manifest["samples"]}
result = {"sampleCount": len(samples), "maximumDurationSeconds": max(s["durationSeconds"] for s in samples.values()),
          "method": "First measured pass for WER. Median of three warm runs through 300 seconds; one run above 300 seconds. No best-of-repeat selection. Model preparation and warmup are separate. Core ML routing is not ANE hardware proof.",
          "limits": ["English and Italian public FLEURS read speech only; not spontaneous private calls.",
                     "Noise, telephone filtering, and repeated-utterance long composites are controlled stress tests.",
                     "Published MLS/OpenASR WER targets do not apply directly to this different dataset, quantization, or normalizer.",
                     "Partial utterances have no word-aligned reference and are excluded from WER.",
                     "Zero-frame native input may be rejected safely; this is not a speech recognition failure."], "lanes": {}}
result["limits"].append("QVAC exact-zero PCM controls use an explicit bypass. This is not proof of model-level voice activity detection or noise-only rejection.")
result["limits"].append("Native FluidAudio requires at least 300 ms. Its 10/100-ms fixtures are safely rejected negative controls; they are not supported transcription lengths.")
baseline_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None
baseline = json.loads(baseline_path.read_text()) if baseline_path else None
for file in sorted((root / "lanes").glob("*/result.json")):
    raw = json.loads(file.read_text())
    if not isinstance(raw, dict):
        continue
    if raw.get("action") and raw["action"] != "samples":
        continue
    runs = defaultdict(list)
    for row in raw.get("runs", []):
        runs[row["sampleID"]].append(row)
    detailed = []
    for identifier, rows in runs.items():
        sample = samples[identifier]
        rows.sort(key=lambda row: row["run"])
        first = rows[0]
        valid = [row["seconds"] for row in rows if not row.get("error")]
        item = {"sampleID": identifier, "condition": sample["condition"], "language": sample["language"],
                "durationSeconds": sample["durationSeconds"], "repeatCount": len(rows),
                "seconds": statistics.median(valid) if valid else None,
                "errors": [row["error"] for row in rows if row.get("error")],
                "expectedInputRejection": any(row.get("error") for row in rows) and
                    (sample["durationSeconds"] == 0 or raw.get("requestedCompute") is not None and sample["durationSeconds"] < 0.3),
                "backendMismatchRuns": sum(bool(row.get("backendMismatches")) for row in rows),
                "invalidTimestamps": sum(row.get("invalidTimestamps", 0) for row in rows),
                "textStable": len({row.get("text", "") for row in rows}) == 1,
                "falseSpeech": sample.get("reference") == "" and bool(first.get("text", "").strip())}
        if raw.get("acceleration"):
            item["reportedBackendMismatchRuns"] = item["backendMismatchRuns"]
            def mismatch(row):
                for call in row.get("engineStats", []):
                    diagnostics, stats = call.get("diagnostics", {}), call.get("stats", {})
                    if diagnostics.get("bypassReason") == "digital-silence":
                        continue
                    actual = "coreml" if stats.get("encoderUsedCoreml") == 1 else diagnostics.get("selectedBackend")
                    if actual != raw["acceleration"]:
                        return True
                return False
            # Older SDK diagnostics label the ggml CPU decoder in a hybrid run.
            # Keep that original judgment, but adjudicate encoder routing using
            # the native per-call flag rather than the decoder's backend label.
            item["backendMismatchRuns"] = sum(mismatch(row) for row in rows)
        if sample.get("reference"):
            item["normalized"] = score(sample["reference"], first.get("text", ""), sample["language"], True)
            item["orthographic"] = score(sample["reference"], first.get("text", ""), sample["language"])
        detailed.append(item)
    grouped = defaultdict(list)
    for row in detailed:
        grouped[(row["language"], row["condition"])].append(row)
    groups = []
    for (language, condition), rows in grouped.items():
        duration = sum(row["durationSeconds"] for row in rows)
        complete = all(row["seconds"] is not None for row in rows)
        elapsed = sum(row["seconds"] for row in rows) if complete else None
        scored = [row["normalized"] for row in rows if "normalized" in row]
        groups.append({"language": language, "condition": condition, "samples": len(rows),
                       "audioSeconds": duration, "seconds": elapsed,
                       "speedMultiple": duration / elapsed if elapsed and duration else None,
                       "normalized": totals(scored), "orthographic": totals([row["orthographic"] for row in rows if "orthographic" in row]),
                       "wer95CI": bootstrap(scored) if scored and condition in ("clean", "noise-10dB", "telephone-bandwidth") else None,
                       "errorRuns": sum(len(row["errors"]) for row in rows if not row["expectedInputRejection"]),
                       "expectedInputRejections": sum(len(row["errors"]) for row in rows if row["expectedInputRejection"]),
                       "falseSpeech": sum(row["falseSpeech"] for row in rows),
                       "backendMismatchRuns": sum(row["backendMismatchRuns"] for row in rows)})
    expected_runs = sum(1 if sample["durationSeconds"] > 300 else 3 for sample in samples.values())
    result["lanes"][file.parent.name] = {"label": raw.get("label"), "prepareSeconds": raw.get("prepareSeconds"),
        "warmupSeconds": raw.get("warmupSeconds"), "finishedAt": raw.get("finishedAt"), "error": raw.get("error"),
        "peakRSSBytes": raw.get("peakEngineRSSBytes"), "modelSHA256": raw.get("modelSHA256"),
        "measuredRuns": len(raw.get("runs", [])), "expectedRuns": expected_runs,
        "coverageComplete": set(runs) == set(samples) and len(raw.get("runs", [])) == expected_runs,
        "groups": groups, "samples": detailed}
    if baseline and file.parent.name in ("sdk-parakeet-metal", "sdk-transcribepsy-metal", "native-default"):
        old_name = {"sdk-parakeet-metal": "qvac-parakeet", "sdk-transcribepsy-metal": "qvac-transcribepsy", "native-default": "native"}[file.parent.name]
        comparisons = []
        for group in groups:
            old = next((row for row in baseline["lanes"][old_name]["groups"]
                        if row["language"] == group["language"] and row["condition"] == group["condition"]), None)
            if old and old["numberNormalized"]["wer"] is not None and group["normalized"]["wer"] is not None:
                delta = group["normalized"]["wer"] - old["numberNormalized"]["wer"]
                comparisons.append({"language": group["language"], "condition": group["condition"],
                                    "werDelta": delta, "higherThanFixedBaseline": delta > 1e-12})
        result["lanes"][file.parent.name]["baselineComparisons"] = comparisons
out = root / "report/metrics.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(result, indent=2))
print(json.dumps({name: {"runs": lane["measuredRuns"], "complete": lane["coverageComplete"],
    "clean": [{"lang": g["language"], "wer": g["normalized"]["wer"], "speed": g["speedMultiple"]}
              for g in lane["groups"] if g["condition"] == "clean"]} for name, lane in result["lanes"].items()}, indent=2))
