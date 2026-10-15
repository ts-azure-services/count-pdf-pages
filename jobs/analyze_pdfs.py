import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from time import monotonic, perf_counter

import fitz  # PyMuPDF
import pyarrow as pa
import pyarrow.parquet as pq
from tqdm import tqdm

THREADS = 32
# Generated blobs are named doc_<12 hex>.pdf (see create_pdfs.py). Partitions
# split the 4096 three-hex-digit name prefixes, so each one lists only its own
# blobs instead of the whole container.
NAME_PREFIX = "doc_"
PREFIX_DIGITS = 3
MAX_PARTITIONS = 16**PREFIX_DIGITS
# How often each execution reports progress for `make analyze-pdfs-azure`.
PROGRESS_SECONDS = 10

SCHEMA = pa.schema(
    [
        ("blob_name", pa.string()),
        ("size_bytes", pa.int64()),
        ("page_count", pa.int32()),
        ("pdf_version", pa.string()),
        ("encrypted", pa.bool_()),
        ("title", pa.string()),
        ("author", pa.string()),
        ("producer", pa.string()),
        ("created", pa.string()),
        ("error", pa.string()),
    ]
)


# Bad files are reported per row, so MuPDF's own stderr messages are just noise.
fitz.TOOLS.mupdf_display_errors(False)


def analyze_bytes(name: str, data: bytes) -> dict:
    """Extract page count and header attributes; never raise for a bad file.
    PyMuPDF is not thread-safe, so call this from one thread only."""
    row = dict.fromkeys(SCHEMA.names)
    row.update(blob_name=name, size_bytes=len(data))
    try:
        with fitz.open(stream=data, filetype="pdf") as doc:
            if doc.needs_pass and not doc.authenticate(""):
                row["encrypted"] = True
                row["error"] = "encrypted: password required"
                return row
            meta = doc.metadata or {}
            row["pdf_version"] = meta.get("format", "").removeprefix("PDF ") or None
            row["encrypted"] = bool(meta.get("encryption"))
            row["page_count"] = doc.page_count
            row["title"] = meta.get("title") or None
            row["author"] = meta.get("author") or None
            row["producer"] = meta.get("producer") or None
            row["created"] = meta.get("creationDate") or None
    except Exception as e:
        row["error"] = f"{type(e).__name__}: {e}"[:200]
    return row


def partition_prefixes(partition: int, partitions: int) -> list[str]:
    """Name prefixes owned by one partition; partitions never overlap."""
    return [
        f"{NAME_PREFIX}{k:0{PREFIX_DIGITS}x}"
        for k in range(partition, MAX_PARTITIONS, partitions)
    ]


def write_results(rows: list[dict], path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(pa.Table.from_pylist(rows, schema=SCHEMA), path, compression="zstd")


def analyze(args) -> int:
    run_id = args.run_id
    part_file = f"run={run_id}/part-{args.partition:04d}.parquet"
    start = perf_counter()

    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    service = BlobServiceClient(
        f"https://{args.account}.blob.core.windows.net", DefaultAzureCredential()
    )
    source = service.get_container_client(args.container)

    def list_prefix(prefix: str) -> list[str]:
        return [
            n for n in source.list_blob_names(name_starts_with=prefix)
            if n.lower().endswith(".pdf")
        ]

    with ThreadPoolExecutor(max_workers=THREADS) as pool:
        prefixes = partition_prefixes(args.partition, args.partitions)
        names = [n for batch in pool.map(list_prefix, prefixes) for n in batch]

    def download(name: str) -> bytes:
        return source.download_blob(name).readall()

    results = service.get_container_client(args.results_container)
    progress_blob = f"_progress/run={run_id}/part-{args.partition:04d}.json"

    def report_progress(done: int):
        # Best effort: a failed progress write must not fail the analysis.
        try:
            results.upload_blob(
                progress_blob, json.dumps({"done": done, "total": len(names)}), overwrite=True
            )
        except Exception as e:
            print(f"⚠️  Progress update failed: {e}")

    print(f"🔎 Partition {args.partition}/{args.partitions}: {len(names)} PDFs")
    report_progress(0)
    rows = []
    last = monotonic()
    # Downloads overlap on a thread pool; parsing stays on this thread.
    with ThreadPoolExecutor(max_workers=THREADS) as pool:
        for name, data in tqdm(
            zip(names, pool.map(download, names)), total=len(names), ncols=80
        ):
            rows.append(analyze_bytes(name, data))
            if monotonic() - last >= PROGRESS_SECONDS:
                report_progress(len(rows))
                last = monotonic()

    local = Path("/tmp") / part_file
    write_results(rows, local)
    results.upload_blob(part_file, local.read_bytes(), overwrite=True)
    report_progress(len(rows))
    target = f"{args.account}/{args.results_container}/{part_file}"

    errors = sum(1 for r in rows if r["error"])
    elapsed = perf_counter() - start
    rate = len(rows) / elapsed if elapsed else 0
    print(f"✅ {len(rows)} files ({errors} with errors) in {elapsed:.1f}s, {rate:.0f}/s")
    print(f"📂 Results: {target}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Extract attributes from PDFs in Blob Storage.")
    parser.add_argument(
        "--account",
        default=os.getenv("STORAGE_ACCOUNT"),
        help="storage account to analyze (required)",
    )
    parser.add_argument("--container", default=os.getenv("STORAGE_CONTAINER", "pdfs"))
    parser.add_argument(
        "--results-container", default=os.getenv("RESULTS_CONTAINER", "results")
    )
    parser.add_argument("--partition", type=int, default=int(os.getenv("PARTITION", "0")))
    parser.add_argument(
        "--partitions", type=int, default=int(os.getenv("PARTITIONS", "1"))
    )
    parser.add_argument(
        "--run-id",
        default=os.getenv("RUN_ID") or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S"),
        help="shared by every partition of one analysis so results group together",
    )
    args = parser.parse_args()
    if not args.account:
        parser.error("set --account or STORAGE_ACCOUNT")
    if not 0 <= args.partition < args.partitions <= MAX_PARTITIONS:
        parser.error(f"need 0 <= partition < partitions <= {MAX_PARTITIONS}")
    sys.exit(analyze(args))
