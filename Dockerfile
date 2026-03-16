# Use an official Python base image
FROM python:3.12-slim

# pull the latest OS patches
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Create and set the working directory in the container
WORKDIR /app

# Copy only requirements first (for efficient caching)
COPY requirements.txt /app/

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of your code into the container
COPY . /app/

# Expose port 5000 to the Docker host
EXPOSE 5000

# By default, run Gunicorn on port 5000
CMD ["gunicorn", "-b", "0.0.0.0:5000", "--access-logfile", "-", "--log-level", "info", "--timeout", "300", "app:app"]
