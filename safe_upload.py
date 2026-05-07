"""Safe-upload helper for the /api/* multipart routes in app.py.

Lives in its own module so unit tests don't pull all of app.py
(which initialises OpenRelik / Timesketch API clients at import time).
"""
from __future__ import annotations

import os
import tempfile

from werkzeug.utils import secure_filename


def safe_upload_path(uploaded_file) -> str:
    """Save an uploaded file to a per-request temp directory under /tmp.

    Sanitises the client-supplied filename via werkzeug.secure_filename
    so path-traversal payloads (e.g. "../../etc/passwd",
    "/etc/cron.d/x") cannot escape the upload root. Returns the
    on-disk path the caller should pass to OpenRelik / Timesketch.
    The directory persists across the request lifetime; container
    restart clears /tmp.
    """
    safe_name = secure_filename(uploaded_file.filename) or "upload"
    upload_dir = tempfile.mkdtemp(prefix="pipeline-upload-", dir="/tmp")
    file_path = os.path.join(upload_dir, safe_name)
    uploaded_file.save(file_path)
    return file_path
