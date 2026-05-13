# Use an official Python base image
FROM python:3.12-slim

# APT_CACHE_BUST is passed a unique value per CI run so the apt layer is
# re-executed every build. Without it, buildx reuses the cached layer
# indefinitely while python:3.12-slim's tag sits at the same digest, and
# Debian security updates never land.
ARG APT_CACHE_BUST=unused

# pull the latest OS patches
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Create the runtime user. Closes audit-doc P-10 (B1.c chain leg):
# pre-fix the pipeline ran as root inside the container, so any
# successful exploitation of the unauth + path-traversal chain
# (B1.a + B1.b) would land with full container-root privileges.
# Numeric UID 1000 keeps the user stable across image rebuilds and
# avoids host-side UID drift if a volume gets mounted.
RUN groupadd --system --gid 1000 cypfer \
    && useradd --system --uid 1000 --gid cypfer --create-home --shell /usr/sbin/nologin cypfer

# Create and set the working directory in the container
WORKDIR /app

# Copy only requirements first (for efficient caching)
COPY requirements.txt /app/

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of your code into the container, owned by the runtime user.
COPY --chown=cypfer:cypfer . /app/

# /tmp must remain writable for safe_upload.safe_upload_path()'s mkdtemp
# call -- 1777 is the default but make it explicit so a future image
# tweak cannot tighten it accidentally.
RUN chmod 1777 /tmp

# Drop to the non-root runtime user before CMD. Gunicorn binds :5000
# (a non-privileged port) so this works without setcap or sudo.
USER cypfer

# Expose port 5000 to the Docker host
EXPOSE 5000

# By default, run Gunicorn on port 5000
CMD ["gunicorn", "-b", "0.0.0.0:5000", "--access-logfile", "-", "--log-level", "info", "--timeout", "300", "app:app"]
