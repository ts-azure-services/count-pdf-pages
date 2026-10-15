import argparse
import os
import random
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from time import perf_counter

import fitz  # PyMuPDF
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from tqdm import tqdm

UPLOAD_THREADS = 32


def build_pdf_bytes(source: bytes, num_pages: int) -> bytes:
    """Create one multi-page PDF by repeating the source's first page."""
    # select() repeats one page reference num_pages times, so the page content is
    # stored once per file. This is far faster than copying page by page.
    # Parsing from in-memory bytes avoids re-reading the file for every PDF.
    with fitz.open(stream=source, filetype="pdf") as doc:
        doc.select([0] * num_pages)
        return doc.tobytes(garbage=3, deflate=True)


def generate_random_pdfs(
    source_pdf: str,
    num_docs: int,
    min_pages: int,
    max_pages: int,
    account: str,
    container: str,
):
    """
    Generate PDFs with a random number of pages each, straight into Blob Storage.
    Runs in the Container Apps generator job. Generation is sequential (PyMuPDF
    does not support multithreaded use); blob uploads overlap with it on a
    thread pool. Blob names are random so parallel job replicas never collide.
    """
    container_client = BlobServiceClient(
        f"https://{account}.blob.core.windows.net", DefaultAzureCredential()
    ).get_container_client(container)
    target = f"{account}/{container}"
    with open(source_pdf, "rb") as f:
        source = f.read()

    def store(data: bytes):
        # analyze_pdfs.py partitions by this doc_<hex> prefix; keep them in sync.
        name = f"doc_{uuid.uuid4().hex[:12]}.pdf"
        container_client.upload_blob(name, data, overwrite=True)

    start_time = perf_counter()
    print(f"🚀 Generating {num_docs} PDFs...")

    total_pages = 0
    failures = 0
    pending = []

    def drain():
        nonlocal failures
        for future in pending:
            try:
                future.result()
            except Exception as e:
                failures += 1
                print(f"❌ Error storing file: {e}")
        pending.clear()

    with ThreadPoolExecutor(max_workers=UPLOAD_THREADS) as pool:
        for _ in tqdm(range(num_docs), desc="Progress", ncols=80):
            pages = random.randint(min_pages, max_pages)
            pending.append(pool.submit(store, build_pdf_bytes(source, pages)))
            total_pages += pages
            # Bound memory: wait for uploads after each chunk of files.
            if len(pending) >= UPLOAD_THREADS * 4:
                drain()
        drain()

    elapsed = perf_counter() - start_time
    print(f"\n✅ Completed: {num_docs - failures} files, {total_pages} total pages in {elapsed:.2f}s")
    print(f"📂 Output: {target}")
    if failures:
        sys.exit(f"{failures} file(s) failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate randomly sized PDFs.")
    parser.add_argument(
        "--num-docs",
        type=int,
        default=int(os.getenv("NUM_DOCS", "100")),
        help="number of PDFs",
    )
    parser.add_argument("--min-pages", type=int, default=5)
    parser.add_argument("--max-pages", type=int, default=500)
    parser.add_argument("--source", default="sample.pdf", help="single-page PDF")
    parser.add_argument(
        "--account",
        default=os.getenv("STORAGE_ACCOUNT"),
        help="storage account to write to (required)",
    )
    parser.add_argument("--container", default=os.getenv("STORAGE_CONTAINER", "pdfs"))
    args = parser.parse_args()
    if not args.account:
        parser.error("set --account or STORAGE_ACCOUNT")
    if args.num_docs < 1 or not 1 <= args.min_pages <= args.max_pages:
        parser.error("need num-docs >= 1 and 1 <= min-pages <= max-pages")

    generate_random_pdfs(
        args.source,
        args.num_docs,
        args.min_pages,
        args.max_pages,
        args.account,
        args.container,
    )
