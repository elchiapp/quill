"""Build a fixed, reference-backed ASR sample set. Never reads private recordings."""
import argparse
import csv
import hashlib
import io
import json
import random
import tarfile
from pathlib import Path

import numpy as np
import requests
import soundfile as sf
from scipy import signal

REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
SEED = 20261018
ARCHIVES = {
    "en_us": "d9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356",
    "it_it": "97dbaedbfa52f4fa4a7b380be90b343066330b8526e1a88f5ab9f82f71f1758e",
}


def digest(file):
    with open(file, "rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def download(url, target, expected=None):
    if target.exists() and (not expected or digest(target) == expected):
        return
    partial = target.with_suffix(target.suffix + ".partial")
    size = partial.stat().st_size if partial.exists() else 0
    session = requests.Session()
    session.trust_env = False  # Public data needs no .netrc credentials.
    response = session.get(url, headers={"Range": f"bytes={size}-"} if size else {},
                           stream=True, timeout=(20, 90))
    response.raise_for_status()
    append = size > 0 and response.status_code == 206
    with open(partial, "ab" if append else "wb") as handle:
        for chunk in response.iter_content(1024 * 1024):
            handle.write(chunk)
    if expected and digest(partial) != expected:
        raise RuntimeError(f"Checksum mismatch for {target.name}; retained partial")
    partial.replace(target)


def main():
    args = argparse.ArgumentParser()
    args.add_argument("root", type=Path)
    args.add_argument("--per-language", type=int, default=20)
    options = args.parse_args()
    if options.per_language <= 0 or options.per_language % 2:
        args.error('--per-language must be a positive even number')
    root = options.root.resolve()
    sources = root / "sources"
    audio_dir = root / "audio"
    sources.mkdir(parents=True, exist_ok=True)
    audio_dir.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    samples = []
    source_records = []
    clean_by_language = {}

    def save(identifier, audio, reference, language, condition, **details):
        # Every engine receives this same 16 kHz mono PCM16 signal.
        wav = audio_dir / (identifier + ".wav")
        sf.write(wav, audio, 16000, subtype="PCM_16")
        quantized, _ = sf.read(wav, dtype="int16")
        pcm = audio_dir / (identifier + ".pcm")
        quantized.astype("<i2").tofile(pcm)
        sample = {"id": identifier, "wav": str(wav), "pcm": str(pcm),
                  "reference": reference, "language": language, "condition": condition,
                  "durationSeconds": len(quantized) / 16000, "audioSHA256": digest(wav),
                  "pcmSHA256": digest(pcm), **details}
        samples.append(sample)
        return sample

    for language in ("en_us", "it_it"):
        base = f"https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data/{language}"
        tsv = sources / f"{language}-test.tsv"
        download(base + "/test.tsv", tsv)
        rows = []
        for columns in csv.reader(io.StringIO(tsv.read_text()), delimiter="\t"):
            if len(columns) < 7:
                continue
            duration = int(columns[5]) / 16000
            if 4 <= duration <= 25 and len(columns[3].split()) >= 8:
                rows.append({"sourceID": columns[0], "file": columns[1],
                             "rawReference": columns[2], "reference": columns[3],
                             "duration": duration, "gender": columns[6]})
        rng = random.Random(SEED + (0 if language == "en_us" else 1))
        rng.shuffle(rows)
        selected = []
        seen = set()
        for gender in ("MALE", "FEMALE"):
            for row in rows:
                if row["gender"] != gender or row["sourceID"] in seen:
                    continue
                selected.append(row)
                seen.add(row["sourceID"])
                if sum(x["gender"] == gender for x in selected) == options.per_language // 2:
                    break
        if len(selected) != options.per_language:
            raise RuntimeError("Insufficient distinct, gender-balanced test utterances")
        archive = sources / (language + "-test.tar.gz")
        print(f"Downloading verified {language} test archive", flush=True)
        download(base + "/audio/test.tar.gz", archive, ARCHIVES[language])
        wanted = {row["file"] for row in selected}
        originals = {}
        with tarfile.open(archive, "r:gz") as handle:
            for member in handle:
                name = Path(member.name).name
                if member.isfile() and name in wanted:
                    payload = handle.extractfile(member).read()
                    audio, rate = sf.read(io.BytesIO(payload), dtype="float32")
                    if audio.ndim > 1:
                        audio = audio.mean(axis=1)
                    if rate != 16000:
                        from math import gcd
                        common = gcd(rate, 16000)
                        audio = signal.resample_poly(audio, 16000 // common, rate // common)
                    originals[name] = audio
                if len(originals) == len(wanted):
                    break
        if len(originals) != len(wanted):
            raise RuntimeError("Selected audio missing from the verified archive")
        clean_by_language[language] = []
        for index, row in enumerate(selected):
            audio = originals[row["file"]]
            if abs(len(audio) / 16000 - row["duration"]) > 0.1:
                raise RuntimeError(f"Audio duration mismatch: {row['file']}")
            identifier = f"{language}-{index + 1:02d}"
            metadata = {"baseID": identifier, "sourceID": row["sourceID"],
                        "sourceFile": row["file"], "gender": row["gender"],
                        "rawReference": row["rawReference"]}
            clean = save(identifier + "-clean", audio, row["reference"], language, "clean", **metadata)
            clean_by_language[language].append(clean)
            # Seeded, stationary white noise. This is synthetic stress, not a
            # substitute for a recorded noisy meeting or overlapping speech.
            noise = np.random.default_rng(SEED + index + (0 if language == "en_us" else 100)).normal(size=len(audio))
            speech_rms = max(float(np.sqrt(np.mean(audio ** 2))), 1e-9)
            noise *= speech_rms / (10 ** (10 / 20) * np.sqrt(np.mean(noise ** 2)))
            noisy = audio + noise
            peak = np.max(np.abs(noisy))
            if peak > 0.98:
                noisy *= 0.98 / peak
            save(identifier + "-noise10", noisy, row["reference"], language, "noise-10dB", **metadata)
            telephone = signal.sosfilt(signal.butter(6, [300, 3400], "bandpass", fs=16000, output="sos"), audio)
            telephone = signal.resample_poly(signal.resample_poly(telephone, 1, 2), 2, 1)[:len(audio)]
            save(identifier + "-telephone", telephone, row["reference"], language, "telephone-bandwidth", **metadata)
        source_records.append({"dataset": "google/fleurs", "revision": REVISION,
                               "language": language, "split": "test", "license": "CC-BY-4.0",
                               "archiveSHA256": digest(archive), "tsvSHA256": digest(tsv),
                               "url": base, "selected": len(selected)})
        print(f"Prepared {len(selected)} {language} utterances and matched stress variants", flush=True)

    for language, clean in clean_by_language.items():
        for target in (60, 180):
            waves, references, members = [], [], []
            length = 0
            for sample in clean:
                audio, _ = sf.read(sample["wav"], dtype="float32")
                waves.extend([audio, np.zeros(4000, dtype=np.float32)])
                references.append(sample["reference"])
                members.append(sample["id"])
                length += len(audio) + 4000
                if length / 16000 >= target:
                    break
            save(f"{language}-composite-{target}", np.concatenate(waves), " ".join(references),
                 language, "long-composite", members=members,
                 note="Concatenated independent utterances; excluded from headline accuracy.")
    save("silence-10s", np.zeros(160000, dtype=np.float32), "", "none", "silence-control")
    manifest = {"seed": SEED, "datasetSources": source_records,
                "selection": "Seeded shuffle before inference; 10 male and 10 female utterances per language; unique source IDs; 4–25 seconds; at least 8 reference words.",
                "audioFormat": "16 kHz, mono, PCM16 WAV and matching s16le PCM", "samples": samples}
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(json.dumps({"samples": len(samples), "minutes": sum(x["durationSeconds"] for x in samples) / 60}), flush=True)


if __name__ == "__main__":
    main()
