# Count PDF pages in Azure Blob Storage

Generate a large number of random PDFs in Blob Storage, then extract their
attributes (mainly page count) and summarize them. All PDF generation and
analysis runs in Azure; only the final summary runs locally.

## How it works

```
 +-------------------+   PDFs    +--------------------------+  Parquet
 | Generator job     |---------->| Analyzer job executions  |-----------+
 | N parallel        |  (pdfs    | one per partition, each  |           |
 | replicas          | container)| reads its slice of blobs |           v
 +-------------------+           +--------------------------+   +-------------+
                                                                  | results     |
                                                                  | container   |
                                                                  +------+------+
                                                                         |
                                                       download latest run
                                                                         v
                                                              DuckDB summary (local)
```

1. **Generate:** each generator replica builds PDFs by repeating the single page
   of `sample.pdf` a random number of times (5–500) and uploads them straight to
   the `pdfs` container under random names.
2. **Analyze:** each analyzer execution reads its partition of the blobs and
   writes one Parquet file of attributes to the `results` container. While it
   runs, it also keeps a small progress file there (`_progress/`).
3. **Report:** the latest run's Parquet files are downloaded and summarized with
   DuckDB.

Both jobs share one image built in Azure Container Registry (no local Docker).
Each job sets its own command; the image has no working default, so a job
started without a command fails instead of silently succeeding.

## Layout

| Path | Runs | Contents |
|---|---|---|
| `jobs/` | In Azure | The container image: Dockerfile, generator, analyzer, `sample.pdf` |
| `tools/` | Locally | Report, plus storage helpers (count, clean, progress) |
| `terraform/` | Locally | Infrastructure, including the image build |
| `tests/` | Locally | Analyzer tests, no Azure access needed |

## Attributes extracted

| Attribute | Why it is useful |
|---|---|
| Page count | The primary question: billing, capacity and processing estimates |
| File size (bytes) | Pairs with page count to find unusually heavy files |
| PDF version | Spots legacy or non-standard producers |
| Encrypted flag | Encrypted files may block downstream processing |
| Title, author, producer, created | Provenance and quality signals |
| Read error | Flags corrupt files instead of failing the whole run |

## Scaling model

- **Generator:** parallel replicas of one job, each making an equal share of the
  documents. Random blob names mean replicas never collide. Building a PDF takes
  milliseconds; upload throughput is the real limit.
- **Analyzer:** blob names are `doc_<hex>.pdf`, and each partition owns a fixed
  share of the 4096 three-digit hex prefixes. It lists only those prefixes, so
  no execution scans the whole container and none overlap. Downloads run in
  parallel; parsing uses PyMuPDF (C, well under a millisecond per file). Each
  partition writes its own Parquet file, so a failed one can be re-run alone.
  Blobs not named `doc_<hex>.pdf` are not analyzed.
- **Limits:** storage throughput and the vCPU quota of the Container Apps
  environment. Defaults are sized for roughly 600k documents.

### Threads per container

Each container runs 32 transfer threads: `THREADS` in `jobs/analyze_pdfs.py` and
`UPLOAD_THREADS` in `jobs/create_pdfs.py`. These are fixed in code, so changing
them means rebuilding the image.

32 threads work on 1 vCPU because they mostly wait on the network. Raising the
number helps little, because the container's single CPU is the limit:

- **CPU:** every request costs some Python CPU, all on one core. In the
  generator, uploads also compete with the PDF builder. Past some point, extra
  threads just queue.
- **Connection pool:** threads beyond the SDK's connection pool open new HTTPS
  connections, which costs more CPU. Job logs then show "Connection pool is
  full" warnings.
- **Memory:** not a concern. Each in-flight PDF is about 100 KB.

Blob Storage is not the bottleneck at these volumes. A standard account allows
about 20,000 requests/s and tens of Gbps. 50 partitions at about 90 PDFs/s each
is about 4,500 requests/s and 3–4 Gbps. Past the limits, Storage answers "server
busy" and the SDK retries with backoff, so throughput levels off rather than
failing. The generator reports a file as failed only if its retries run out.
Random `doc_<hex>` names spread the load evenly, because Storage splits load by
blob name.

To go faster, add partitions or replicas rather than threads, because each
container brings its own CPU. Containers can also go up to 2 vCPU and 4 GiB
from the current 1 and 2. To test more threads, make the count an environment
variable, run once at 64, and compare the per-partition rate. Going above 32 is
unmeasured.

## Why a job instead of a search indexer

| Approach | Strengths | Trade-offs |
|---|---|---|
| **Container Apps job (this repo)** | No extra service; pay only while running; scales by partition; results are plain Parquet | Runs are triggered manually and re-scan everything |
| Azure AI Search indexer + custom skill | Managed, scheduled and incremental | Slow to provision, costs while idle, needs a skill endpoint, throughput bounded by tier |

For a one-time or occasional report the job is simpler and faster; an indexer
suits documents that keep arriving.

## Storage access

Storage requires Entra ID and RBAC (shared keys are disabled); the jobs
authenticate with managed identities. Public network access stays on because IP
allow lists do not apply to same-region Azure services.
