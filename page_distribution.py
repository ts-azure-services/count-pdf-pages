import os
from azure.core.credentials import AzureKeyCredential
from azure.search.documents import SearchClient
from collections import defaultdict
from dotenv import load_dotenv

# Configuration
load_dotenv()

# Initialize the search client
credential = AzureKeyCredential(os.getenv("SEARCH_KEY"))
search_client = SearchClient(
    endpoint=os.getenv("SEARCH_SERVICE"),
    index_name=os.getenv("SEARCH_INDEX"),
    credential=credential
)

# Define page ranges
PAGE_RANGES = [
    (1, 5),
    (6, 10),
    (11, 20),
    (21, 50),
    (51, 100),
    (101, float('inf'))
]

def get_range_label(min_pages, max_pages):
    """Create a label for the page range."""
    if max_pages == float('inf'):
        return f"{min_pages}+ pages"
    return f"{min_pages}-{max_pages} pages"

def categorize_page_count(page_count, ranges):
    """Categorize a page count into a range."""
    for min_pages, max_pages in ranges:
        if min_pages <= page_count <= max_pages:
            return get_range_label(min_pages, max_pages)
    return "Unknown"

# Retrieve all results
print("Fetching all documents from Azure Cognitive Search...")
results = search_client.search(
    search_text="*",
    include_total_count=True,
    top=1000  # Adjust if you have more documents
)

# Count documents by page range
distribution = defaultdict(int)
all_docs = []

for result in results:
    page_count = result.get('page_count', 0)
    category = categorize_page_count(page_count, PAGE_RANGES)
    distribution[category] += 1
    all_docs.append({
        'file_name': result.get('file_name'),
        'page_count': page_count,
        'category': category
    })

# Sort distribution by page ranges
sorted_distribution = {}
for min_pages, max_pages in PAGE_RANGES:
    label = get_range_label(min_pages, max_pages)
    if label in distribution:
        sorted_distribution[label] = distribution[label]

# Display results
print(f"\nTotal documents found: {len(all_docs)}")
print("\nDocument Distribution by Page Count:")
print("-" * 50)

for range_label, count in sorted_distribution.items():
    print(f"{range_label:20} : {count:4} documents")

# # Export to JSON
# output = {
#     "total_documents": len(all_docs),
#     "distribution": sorted_distribution,
#     "documents": all_docs
# }
#
# with open('document_distribution.json', 'w') as f:
#     json.dump(output, f, indent=2)
#
# print("\nResults exported to 'document_distribution.json'")
