FROM python:3.12-alpine
RUN apk add --no-cache ffmpeg
RUN pip install --no-cache-dir edge-tts==7.3.1 aiohttp==3.12.15
COPY tts.py /app/tts.py
WORKDIR /app
CMD ["python", "tts.py"]
