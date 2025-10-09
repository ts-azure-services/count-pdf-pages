from flask import Flask, request, jsonify
import logging
from PyPDF2 import PdfReader
from io import BytesIO
from azure.storage.blob import BlobServiceClient
from azure.identity import DefaultAzureCredential

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

@app.route('/api/PageCounter', methods=['POST'])
def page_counter():
    logging.info('Page Counter custom skill triggered.')
    
    try:
        # Parse request body
        body = request.get_json()
        
        if not body or 'values' not in body:
            return jsonify({"errors": [{"message": "Invalid request format"}]}), 400
        
        results = {"values": []}
        
        for value in body['values']:
            record_id = value['recordId']
            data = value['data']
            
            try:
                # Get the blob URL
                blob_url = data.get('metadata_storage_path')
                
                if not blob_url:
                    results['values'].append({
                        "recordId": record_id,
                        "errors": [{"message": "No blob URL provided"}]
                    })
                    continue
                
                # Download the PDF
                logging.info(f"Downloading PDF from: {blob_url}")
                
                # Use managed identity to authenticate
                credential = DefaultAzureCredential()
                
                # Parse blob URL to get account, container and blob name
                url_parts = blob_url.replace('https://', '').split('/')
                account_name = url_parts[0].split('.')[0]
                container_name = url_parts[1]
                blob_name = '/'.join(url_parts[2:])
                
                account_url = f"https://{account_name}.blob.core.windows.net"
                
                blob_service_client = BlobServiceClient(
                    account_url=account_url,
                    credential=credential
                )
                
                blob_client = blob_service_client.get_blob_client(
                    container=container_name,
                    blob=blob_name
                )
                
                # Download blob content
                blob_data = blob_client.download_blob().readall()
                
                # Count pages using PyPDF2
                pdf_file = BytesIO(blob_data)
                pdf_reader = PdfReader(pdf_file)
                page_count = len(pdf_reader.pages)
                
                logging.info(f"PDF has {page_count} pages")
                
                results['values'].append({
                    "recordId": record_id,
                    "data": {
                        "page_count": page_count
                    }
                })
                
            except Exception as e:
                logging.error(f"Error processing record {record_id}: {str(e)}")
                results['values'].append({
                    "recordId": record_id,
                    "errors": [{"message": str(e)}]
                })
        
        return jsonify(results), 200
        
    except Exception as e:
        logging.error(f"API error: {str(e)}")
        return jsonify({"errors": [{"message": str(e)}]}), 500

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
