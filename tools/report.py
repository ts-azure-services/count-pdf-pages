import argparse
import os
import sys
from pathlib import Path

import duckdb


def latest_run_download(account: str, container: str, dest: Path) -> Path:
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    client = BlobServiceClient(
        f"https://{account}.blob.core.windows.net", DefaultAzureCredential()
    ).get_container_client(container)
    blobs = [b.name for b in client.list_blobs(name_starts_with="run=")]
    if not blobs:
        sys.exit(f"No results found in {account}/{container}")
    run = max({n.split("/")[0] for n in blobs})
    folder = dest / run
    folder.mkdir(parents=True, exist_ok=True)
    for name in (n for n in blobs if n.startswith(run + "/")):
        (dest / name).write_bytes(client.download_blob(name).readall())
    return folder


def show(con, title: str, sql: str):
    print(f"\n== {title} ==")
    rel = con.sql(sql)
    rows = [[str(v) for v in r] for r in rel.fetchall()]
    widths = [max(len(c), *(len(r[i]) for r in rows), 0) for i, c in enumerate(rel.columns)]
    print("  ".join(c.ljust(w) for c, w in zip(rel.columns, widths)))
    for r in rows:
        print("  ".join(v.ljust(w) for v, w in zip(r, widths)))


def report(folder: Path):
    con = duckdb.connect()
    con.sql(
        f"CREATE VIEW pdfs AS SELECT * FROM read_parquet('{folder}/*.parquet')"
    )
    print(f"Report for {folder.name}")
    show(
        con,
        "Overview",
        """SELECT count(*) AS files,
                  coalesce(sum(page_count), 0) AS total_pages,
                  round(avg(page_count), 1) AS avg_pages,
                  round(sum(size_bytes) / 1e9, 3) AS total_gb,
                  count(*) FILTER (WHERE error IS NOT NULL) AS errors
           FROM pdfs""",
    )
    show(
        con,
        "Page-count distribution",
        """SELECT CASE WHEN page_count <= 5 THEN '1-5'
                      WHEN page_count <= 10 THEN '6-10'
                      WHEN page_count <= 20 THEN '11-20'
                      WHEN page_count <= 50 THEN '21-50'
                      WHEN page_count <= 100 THEN '51-100'
                      ELSE '101+' END AS pages,
                  count(*) AS files
           FROM pdfs WHERE page_count IS NOT NULL
           GROUP BY ALL ORDER BY min(page_count)""",
    )
    show(
        con,
        "File size (bytes)",
        """SELECT min(size_bytes) AS min,
                  median(size_bytes)::BIGINT AS median,
                  quantile_cont(size_bytes, 0.95)::BIGINT AS p95,
                  max(size_bytes) AS max
           FROM pdfs""",
    )
    show(
        con,
        "PDF versions",
        """SELECT coalesce(pdf_version, 'unknown') AS version, count(*) AS files
           FROM pdfs GROUP BY ALL ORDER BY files DESC""",
    )
    show(
        con,
        "Encryption",
        "SELECT encrypted, count(*) AS files FROM pdfs GROUP BY ALL",
    )
    show(
        con,
        "Top producers",
        """SELECT coalesce(producer, 'unknown') AS producer, count(*) AS files
           FROM pdfs GROUP BY ALL ORDER BY files DESC LIMIT 10""",
    )
    show(
        con,
        "Errors by type",
        """SELECT split_part(error, ':', 1) AS error_type, count(*) AS files
           FROM pdfs WHERE error IS NOT NULL
           GROUP BY ALL ORDER BY files DESC""",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Summarize PDF analysis results.")
    parser.add_argument(
        "--results-dir", default="./results", help="where the downloaded run is saved"
    )
    parser.add_argument(
        "--account",
        default=os.getenv("STORAGE_ACCOUNT"),
        help="storage account holding the analysis results (required)",
    )
    parser.add_argument(
        "--results-container", default=os.getenv("RESULTS_CONTAINER", "results")
    )
    args = parser.parse_args()
    if not args.account:
        parser.error("set --account or STORAGE_ACCOUNT")
    report(latest_run_download(args.account, args.results_container, Path(args.results_dir)))
