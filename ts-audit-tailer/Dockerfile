FROM python:3.12-slim

# psycopg2-binary avoids needing build tools in the final image.
RUN pip install --no-cache-dir psycopg2-binary==2.9.10

COPY tailer.py /tailer.py
RUN mkdir -p /state

# Unbuffered so stdout lines reach Promtail's Docker SD immediately.
ENV PYTHONUNBUFFERED=1

CMD ["python", "/tailer.py"]
