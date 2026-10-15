"""Local helpers for the job storage: count generated PDFs, render generator
and analyzer progress, and delete every PDF between runs."""

import argparse
import json
import os
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from itertools import batched
from time import perf_counter

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

# Blob batch requests accept at most 256 sub-requests.
BATCH_SIZE = 256
THREADS = 16
# Generated blobs are named doc_<hex>.pdf, so these prefixes cover all of them
# and can be listed in parallel.
PREFIXES = [f"doc_{h}" for h in "0123456789abcdef"]
BAR_WIDTH = 30


def container_client(account: str, container: str):
    return BlobServiceClient(
        f"https://{account}.blob.core.windows.net", DefaultAzureCredential()
    ).get_container_client(container)


def count(client) -> int:
    """Count generated PDFs, listing each name prefix in parallel."""

    def one(prefix: str) -> int:
        return sum(1 for _ in client.list_blob_names(name_starts_with=prefix))

    with ThreadPoolExecutor(max_workers=len(PREFIXES)) as pool:
        return sum(pool.map(one, PREFIXES))


def analyzed(client, run_id: str) -> int:
    """PDFs analyzed so far in one run, from each partition's progress file."""
    blobs = client.list_blob_names(name_starts_with=f"_progress/run={run_id}/")
    return sum(json.loads(client.download_blob(b).readall())["done"] for b in blobs)


def progress_line(state: str, done: int, target: int, elapsed: float) -> str:
    """One status line: bar, count, rate and ETA."""
    done = max(done, 0)
    frac = min(done / target, 1) if target else 0
    filled = int(frac * BAR_WIDTH)
    bar = "█" * filled + "░" * (BAR_WIDTH - filled)
    rate = done / elapsed if elapsed > 0 else 0
    if rate and done < target:
        eta = f"ETA {int((target - done) / rate) // 60}m{int((target - done) / rate) % 60:02d}s"
    elif done == 0:
        eta = "starting"
    else:
        eta = ""
    mins, secs = divmod(int(elapsed), 60)
    return (
        f"{state:<12} {bar} {done:>{len(str(target))}}/{target} ({int(frac * 100):3d}%)"
        f"  {rate:5.1f}/s  {mins}m{secs:02d}s  {eta}"
    )


def clean(client):
    """Delete every blob in the container, keeping the container itself."""
    start = perf_counter()

    def delete(names: tuple[str, ...]) -> int:
        client.delete_blobs(*names, delete_snapshots="include")
        return len(names)

    with ThreadPoolExecutor(max_workers=THREADS) as pool:
        deleted = sum(pool.map(delete, batched(client.list_blob_names(), BATCH_SIZE)))
    print(f"🗑️  Deleted {deleted} blobs from {client.account_name}/{client.container_name} in {perf_counter() - start:.1f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Helpers for the job storage.")
    parser.add_argument("--account", default=os.getenv("STORAGE_ACCOUNT"))
    parser.add_argument("--container", default="pdfs")
    parser.add_argument("--results-container", default="results")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("count", help="print the number of generated PDFs")
    sub.add_parser("clean", help="delete every blob in the container")
    p = sub.add_parser("progress", help="print one progress line for a running job")
    p.add_argument("--state", required=True)
    p.add_argument("--target", type=int, required=True)
    p.add_argument("--start", type=float, required=True, help="run start, epoch seconds")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--base", type=int, help="generator: PDF count before the run")
    source.add_argument("--run", help="analyzer: RUN_ID of the analysis")
    args = parser.parse_args()
    if not args.account:
        parser.error("set --account or STORAGE_ACCOUNT")

    client = container_client(args.account, args.container)
    if args.cmd == "count":
        print(count(client))
    elif args.cmd == "clean":
        clean(client)
    else:
        if args.run:
            done = analyzed(container_client(args.account, args.results_container), args.run)
        else:
            done = count(client) - args.base
        line = progress_line(args.state, done, args.target, time.time() - args.start)
        # \r plus clear-to-end redraws one line in place on a terminal; the line
        # must fit the width, or it wraps and each redraw leaves a fragment.
        if sys.stdout.isatty():
            width = shutil.get_terminal_size().columns
            sys.stdout.write("\r\033[K  " + line[: width - 3])
        else:
            sys.stdout.write("  " + line + "\n")
        sys.stdout.flush()
