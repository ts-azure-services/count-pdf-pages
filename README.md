Goal of this repo is to be able to count pdf pages for approximating which docs should be processed for a processing pipeline.
This is meant to help simulate the scenario of a customer with a large number of docs, and needing methods to figure out how to
understand the page characteristics for sending in doc requests.

As per the basic [document extraction](https://learn.microsoft.com/en-us/azure/search/cognitive-search-skill-document-extraction)
we can obtain some metadata. But for pdf, this does not include [page
counts](https://learn.microsoft.com/en-us/azure/search/search-blob-metadata-properties). To get page counts, we have to actually
open the file and process the content/metadata. This is orchestrated through a container app with open-source libraries.
