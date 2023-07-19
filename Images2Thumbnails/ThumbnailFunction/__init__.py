import logging
import azure.functions as func
from azure.storage.blob import BlobServiceClient, ContentSettings
from PIL import Image
from io import BytesIO
import os
import imageio

def main(blob: func.InputStream, outputblob: func.Out[bytes]) -> None:
    logging.info(f"Python Blob function processed blob \n Name: {blob.name} \n Size: {blob.length} Bytes")

    container_name = 'thumbnails'
    storage_connection_string = os.environ['AzureWebJobsStorage']
    blob_service_client = BlobServiceClient.from_connection_string(storage_connection_string)

    thumbnail_name = f"thumbnail_{blob.name}"
    
    # Check if the thumbnail already exists
    thumbnail_blob_client = blob_service_client.get_blob_client(container=container_name, blob=thumbnail_name)
    if thumbnail_blob_client.exists():
        logging.info("Thumbnail already exists.")
        return

    # Create a thumbnail using the PIL library
    thumbnail_size = (100, 100)

    # Open the uploaded image
    if blob.name.lower().endswith('.rgb'):
        image_data = imageio.imread(blob)
        image = Image.fromarray(image_data)
    else:
        image = Image.open(blob)

    # Convert the image to RGB mode if it has an alpha channel
    if image.mode == 'RGBA':
        image = image.convert('RGB')

    image.thumbnail(thumbnail_size)

    # Save the thumbnail to the output container
    output_stream = BytesIO()
    image.save(output_stream, format="JPEG")
    output_stream.seek(0)

    outputblob.set(output_stream.getvalue())
    logging.info(f"Thumbnail '{thumbnail_name}' created successfully.")