import os
import random
import fitz  # PyMuPDF
from concurrent.futures import ThreadPoolExecutor, as_completed
from tqdm import tqdm
import multiprocessing
from time import perf_counter

def create_single_pdf(source_pdf: str, output_folder: str, idx: int, num_pages: int):
    """Worker function to create a single multi-page PDF efficiently."""
    out_path = os.path.join(output_folder, f"doc_{idx:03d}.pdf")

    # Use context managers for both source and new file
    with fitz.open(source_pdf) as src, fitz.open() as new_pdf:
        # Insert the first page once
        new_pdf.insert_pdf(src, from_page=0, to_page=0)

        # Efficiently clone it using show_pdf_page()
        for _ in range(1, num_pages):
            new_pdf.insert_page(-1)
            new_pdf[-1].show_pdf_page(new_pdf[-1].rect, src, 0)

        # Fastest save: no compression, no cleanup
        new_pdf.save(out_path, deflate=False, garbage=0, clean=False)

    return idx, num_pages, out_path


def generate_random_pdfs(
    source_pdf: str,
    output_folder: str,
    num_docs: int,
    min_pages: int,
    max_pages: int,
    max_workers: int = None,
):
    """
    High-performance parallel PDF generator using PyMuPDF.
    - Each PDF has a random number of duplicated pages.
    - Uses show_pdf_page for fast cloning.
    - Parallelized across CPU cores.
    """
    os.makedirs(output_folder, exist_ok=True)

    start_time = perf_counter()

    # Determine optimal thread count (defaults to # of logical CPUs)
    if max_workers is None:
        max_workers = min(8, multiprocessing.cpu_count())

    print(f"🚀 Generating {num_docs} PDFs using {max_workers} workers...")

    # Prepare job list
    jobs = [
        (source_pdf, output_folder, i, random.randint(min_pages, max_pages))
        for i in range(1, num_docs + 1)
    ]

    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(create_single_pdf, *job) for job in jobs]
        for f in tqdm(as_completed(futures), total=len(futures), desc="Progress", ncols=80):
            try:
                results.append(f.result())
            except Exception as e:
                print(f"❌ Error generating file: {e}")

    elapsed = perf_counter() - start_time
    total_pages = sum(r[1] for r in results)
    print(f"\n✅ Completed: {len(results)} files, {total_pages} total pages in {elapsed:.2f}s")
    print(f"📂 Output folder: {os.path.abspath(output_folder)}")


if __name__ == "__main__":
    # ---- USER SETTINGS ----
    SOURCE_PDF = "sample.pdf"             # Your single-page PDF
    OUTPUT_FOLDER = "./pdfs"    # Folder for output
    NUM_DOCS = 100                        # Number of PDFs to generate
    MIN_PAGES = 5                         # Minimum pages per PDF
    MAX_PAGES = 100                       # Maximum pages per PDF
    MAX_WORKERS = None                    # Defaults to CPU count (use 4, 8, etc. to cap)

    generate_random_pdfs(
        SOURCE_PDF,
        OUTPUT_FOLDER,
        NUM_DOCS,
        MIN_PAGES,
        MAX_PAGES,
        MAX_WORKERS,
    )
