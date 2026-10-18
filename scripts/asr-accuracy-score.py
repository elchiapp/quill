"""Score identical public-reference samples; speed repeats never select the best text."""
import argparse
import json
import re
import statistics
import unicodedata
from collections import defaultdict
from pathlib import Path

import jiwer
import numpy as np
from num2words import num2words


def normalize(text, language, numbers=False):
    text = unicodedata.normalize("NFKC", text).casefold()
    text = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in text)
    if numbers:
        # Only integer formatting is canonicalized. Decimals, dates, units,
        # and factual disagreements are not silently treated as equivalent.
        def integer(match):
            value = match.group()
            if len(value) > 12:
                return value
            return num2words(int(value), lang="it" if language == "it_it" else "en")
        text = re.sub(r"\b\d+\b", integer, text)
    text = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in text)
    return " ".join(text.split())


def score(reference, hypothesis, language, numbers=False):
    ref = normalize(reference, language, numbers)
    hyp = normalize(hypothesis, language, numbers)
    output = jiwer.process_words(ref, hyp)
    chars = jiwer.process_characters(ref.replace(" ", ""), hyp.replace(" ", ""))
    return {"referenceWords": len(ref.split()), "substitutions": output.substitutions,
            "deletions": output.deletions, "insertions": output.insertions,
            "edits": output.substitutions + output.deletions + output.insertions,
            "wer": output.wer if ref else None, "cer": chars.cer if ref else None,
            "normalizedReference": ref, "normalizedHypothesis": hyp,
            "alignment": jiwer.visualize_alignment(output)}


def totals(rows):
    words = sum(x["referenceWords"] for x in rows)
    edits = sum(x["edits"] for x in rows)
    return {"referenceWords": words, "edits": edits, "wer": edits / words if words else None,
            **{key: sum(x[key] for x in rows) for key in ("substitutions", "deletions", "insertions")}}


def bootstrap(rows):
    # Each group has one condition and one language, with unique source IDs.
    if len(rows) < 10:
        return None
    rng = np.random.default_rng(20261018)
    words = np.array([row["referenceWords"] for row in rows])
    errors = np.array([row["edits"] for row in rows])
    indices = rng.integers(0, len(rows), size=(2000, len(rows)))
    denominator = words[indices].sum(axis=1)
    rates = errors[indices].sum(axis=1) / denominator
    return np.percentile(rates, [2.5, 97.5]).tolist()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = json.loads((root / "manifest.json").read_text())
    samples = {sample["id"]: sample for sample in manifest["samples"]}
    report = {"method": {
        "accuracyPass": "First measured pass; no best-of-three selection.",
        "speed": "Per-sample median of three warm API calls. Model load and one warmup are separate.",
        "primaryMetric": "Corpus word error rate (S+D+I)/reference words; lower is better.",
        "normalization": "Unicode NFKC, casefold, punctuation/symbols to spaces, whitespace collapse. Accents retained.",
        "numberNormalizedMetric": "Same, with standalone integers expanded with num2words (en/it). Also report raw orthographic WER.",
        "confidence": "2000 utterance-bootstrap resamples per language/condition. Small-sample exploratory result, not a population accuracy guarantee.",
        "timingBoundary": "Pre-normalized WAV for native; matching PCM for SDK. Standard API processing, not isolated GPU kernel time. Long SDK inputs use the app's 60-second batches.",
        "limits": "Read speech, not spontaneous meetings. Synthetic white noise and telephone bandwidth are controlled stress, not a recorded noisy meeting. Long composites reuse clean utterances and are excluded from headline accuracy. No diarization accuracy score.",
    }, "sampleCount": len(samples), "lanes": {}, "comparisons": []}
    for lane in ("native", "qvac-transcribepsy", "qvac-parakeet"):
        raw = json.loads((root / lane / "result.json").read_text())
        by_sample = defaultdict(list)
        for row in raw["runs"]:
            by_sample[row["sampleID"]].append(row)
        if set(by_sample) != set(samples):
            raise RuntimeError(f"Incomplete sample coverage: {lane}")
        detailed = []
        for identifier, sample in samples.items():
            runs = sorted(by_sample[identifier], key=lambda row: row["run"])
            if len(runs) != 3 or [x["run"] for x in runs] != [1, 2, 3]:
                raise RuntimeError(f"Missing repetition: {lane}/{identifier}")
            first = runs[0]
            scores = [score(sample["reference"], row.get("text", ""), sample["language"], True) for row in runs]
            valid_times = [x["seconds"] for x in runs if not x.get("error")]
            item = {"sampleID": identifier, "language": sample["language"], "condition": sample["condition"],
                    "durationSeconds": sample["durationSeconds"], "baseID": sample.get("baseID"),
                    "seconds": statistics.median(valid_times) if valid_times else None,
                    "allSeconds": [x["seconds"] for x in runs], "errors": [x.get("error") for x in runs if x.get("error")],
                    "hypothesis": first.get("text", ""), "textStable": len({x.get("text", "") for x in runs}) == 1,
                    "orthographic": score(sample["reference"], first.get("text", ""), sample["language"]),
                    "numberNormalized": scores[0], "repeatWER": [x["wer"] for x in scores]}
            item["realTimeFactor"] = item["seconds"] / item["durationSeconds"] if item["seconds"] is not None else None
            detailed.append(item)
        grouped = defaultdict(list)
        for row in detailed:
            grouped[(row["language"], row["condition"])].append(row)
        groups = []
        for (language, condition), rows in grouped.items():
            duration = sum(row["durationSeconds"] for row in rows)
            complete = not any(row["errors"] for row in rows)
            elapsed = sum(row["seconds"] for row in rows) if complete else None
            normalized_rows = [row["numberNormalized"] for row in rows]
            groups.append({"language": language, "condition": condition, "samples": len(rows),
                           "durationSeconds": duration, "seconds": elapsed,
                           "realTimeFactor": elapsed / duration if complete else None,
                           "speedMultiple": duration / elapsed if complete and elapsed else None,
                           "speedComplete": complete, "numberNormalized": totals(normalized_rows),
                           "orthographic": totals([row["orthographic"] for row in rows]),
                           "wer95CI": bootstrap(normalized_rows), "unstableTexts": sum(not row["textStable"] for row in rows),
                           "errorRuns": sum(len(row["errors"]) for row in rows)})
        report["lanes"][lane] = {"label": raw["label"], "prepareSeconds": raw["prepareSeconds"],
                                 "warmupSeconds": raw["warmupSeconds"], "groups": groups, "samples": detailed,
                                 "mappedModelFiles": raw.get("mappedModelFiles"),
                                 "modelSHA256": raw.get("modelSHA256"), "source": str(root / lane / "result.json")}
    for language in ("en_us", "it_it"):
        for condition in ("clean", "noise-10dB", "telephone-bandwidth", "long-composite"):
            report["comparisons"].append({"language": language, "condition": condition,
                "lanes": {name: next(row for row in lane["groups"] if row["language"] == language and row["condition"] == condition)
                          for name, lane in report["lanes"].items()}})
    report["ablations"] = []
    for chunk_seconds in (15, 30):
        for lane in ("qvac-transcribepsy", "qvac-parakeet"):
            file = root / f"ablation-{chunk_seconds}" / lane / "result.json"
            if not file.exists():
                continue
            raw = json.loads(file.read_text())
            for language in ("en_us", "it_it"):
                details = []
                for identifier, sample in samples.items():
                    if sample["condition"] != "long-composite" or sample["language"] != language:
                        continue
                    runs = sorted((r for r in raw["runs"] if r["sampleID"] == identifier), key=lambda r: r["run"])
                    if len(runs) != 3 or any(r.get("error") for r in runs):
                        raise RuntimeError(f"Incomplete chunk ablation: {file}/{identifier}")
                    details.append({"sampleID": identifier,
                                    "seconds": statistics.median(r["seconds"] for r in runs),
                                    "score": score(sample["reference"], runs[0]["text"], language, True)})
                report["ablations"].append({"lane": lane, "language": language,
                                            "chunkSeconds": chunk_seconds,
                                            "seconds": sum(x["seconds"] for x in details),
                                            "numberNormalized": totals([x["score"] for x in details]),
                                            "samples": details})
    (root / "accuracy-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    for comparison in report["comparisons"]:
        print(comparison["language"], comparison["condition"],
              {name: {"WER": round(row["numberNormalized"]["wer"] * 100, 2),
                       "seconds": round(row["seconds"], 3) if row["seconds"] is not None else None} for name, row in comparison["lanes"].items()})
    for row in report["ablations"]:
        print("ABLATION", row["chunkSeconds"], row["lane"], row["language"],
              round(row["numberNormalized"]["wer"] * 100, 2), round(row["seconds"], 3))


if __name__ == "__main__":
    main()
