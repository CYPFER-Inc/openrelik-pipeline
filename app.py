import os
import uuid
import json
import zipfile
import tempfile
import shutil
import re
from timesketch_api_client import client as timesketch_client
import sys 

from flask import Flask, request, jsonify

from openrelik_api_client.api_client import APIClient
from openrelik_api_client.folders import FoldersAPI
from openrelik_api_client.workflows import WorkflowsAPI

from safe_upload import safe_upload_path as _safe_upload_path

# --------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------
API_KEY = os.getenv("OPENRELIK_API_KEY", "")
API_URL = os.getenv("OPENRELIK_API_URL", "")
TIMESKETCH_PASSWORD = os.getenv("TIMESKETCH_PASSWORD", "")
TIMESKETCH_URL = os.getenv("TIMESKETCH_URL", "")

# Initialize API clients
api_client = APIClient(API_URL, API_KEY)
folders_api = FoldersAPI(api_client)
workflows_api = WorkflowsAPI(api_client)

# --------------------------------------------------------------------------------
# Initialize Flask app
# --------------------------------------------------------------------------------
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 50 * 1024 * 1024 * 1024  # 50 GB limit
# Upper bound chosen for the NETWORK_ pipeline (large firewall / VPC flow
# logs can run multi-GB). HOST_ triage zips are typically much smaller.
# Werkzeug enforces this globally for all routes; per-endpoint enforcement
# is up to each handler if it wants a tighter cap.
ts_client = timesketch_client.TimesketchApi(
    host_uri=TIMESKETCH_URL, username="admin", password=TIMESKETCH_PASSWORD
)


# --------------------------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------------------------        
def create_folder(folder_name):
    """
    Create a new root folder with the given folder name.
    """
    response = folders_api.create_root_folder(folder_name)
    return response


# Default group + role granted read access when a new case folder is created
# by /api/triage/timesketch?case_id=... . Exposed as env vars so the deployment
# can tune without a code change. Valid OpenRelik roles per the API:
# Owner, Editor, Viewer, No Access. The folder's creator (the pipeline's API
# key user, typically admin) is Owner automatically; we only need to grant
# read access to the rest of the team via Viewer.
CASE_FOLDER_READ_GROUP = os.getenv("CASE_FOLDER_READ_GROUP", "Everyone")
CASE_FOLDER_READ_ROLE = os.getenv("CASE_FOLDER_READ_ROLE", "Viewer")


def find_or_create_case_folder(case_id):
    """
    Return the folder_id of a top-level folder named case_id.

    If no such folder exists, create it as a root folder and grant the
    configured group (default: Everyone) read access. On reuse, permissions
    are left as-is — if an admin has since hand-tuned the ACL in the UI,
    we don't re-flatten it on every POST.

    Returns the folder_id, or None if creation failed.
    """
    roots = folders_api.list_root_folders(1000) or []
    for f in roots:
        if f.get("display_name") == case_id:
            return f["id"]

    new_id = folders_api.create_root_folder(case_id)
    if new_id is None:
        return None

    # share_folder prints to stdout and returns None on error rather than
    # raising; treat None as failure so the warning gets logged correctly.
    share_result = None
    try:
        share_result = folders_api.share_folder(
            new_id,
            group_names=[CASE_FOLDER_READ_GROUP],
            group_role=CASE_FOLDER_READ_ROLE,
        )
    except Exception as exc:
        app.logger.warning(
            "Case folder %s (id=%s) created but share_folder raised: %s",
            case_id, new_id, exc,
        )
    else:
        if share_result is None:
            app.logger.warning(
                "Case folder %s (id=%s) created but share to group %s with role %s "
                "returned None (likely invalid role/group). Valid OpenRelik roles: "
                "Owner, Editor, Viewer, No Access. Admin can share manually via the "
                "OpenRelik UI, or set CASE_FOLDER_READ_ROLE env var.",
                case_id, new_id, CASE_FOLDER_READ_GROUP, CASE_FOLDER_READ_ROLE,
            )

    return new_id


def upload_file(file_path, folder_id):
    """
    Upload a file to the specified folder.
    """
    response = api_client.upload_file(file_path, folder_id)
    return response


def create_workflow(folder_id, file_ids):
    """
    Create a new workflow in the specified folder with the given file IDs.
    Returns the workflow ID and the workflow's folder ID.
    """
    response = workflows_api.create_workflow(folder_id, file_ids)
    workflow_id = response
    workflow = workflows_api.get_workflow(folder_id, workflow_id)
    return workflow_id, workflow["folder"]["id"]


def rename_folder(folder_id, new_name):
    """
    Rename an existing folder.
    """
    return folders_api.update_folder(folder_id, {"display_name": new_name})


def rename_workflow(folder_id, workflow_id, new_name):
    """
    Rename an existing workflow.
    """
    return workflows_api.update_workflow(
        folder_id, workflow_id, {"display_name": new_name}
    )


def add_plaso_tasks_to_workflow(folder_id, workflow_id):
    """
    Add tasks to an existing workflow, including a Plaso task and a Timesketch task.
    """
    plaso_task_uuid = str(uuid.uuid4()).replace("-", "")
    timesketch_task_uuid = str(uuid.uuid4()).replace("-", "")

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-plaso.tasks.log2timeline",
                            "queue_name": "openrelik-worker-plaso",
                            "display_name": "Plaso: Log2Timeline",
                            "description": "Super timelining",
                            "task_config": [
                                {
                                    "name": "artifacts",
                                    "label": "Select artifacts to parse",
                                    "description": (
                                        "Select one or more forensic artifact definitions "
                                        "from the ForensicArtifacts project. These definitions "
                                        "specify files and data relevant to digital forensic "
                                        "investigations. Only the selected artifacts will be "
                                        "parsed."
                                    ),
                                    "type": "artifacts",
                                    "required": False,
                                },
                                {
                                    "name": "parsers",
                                    "label": "Select parsers to use",
                                    "description": (
                                        "Select one or more Plaso parsers. These parsers specify "
                                        "how to interpret files and data. Only data identified by "
                                        "the selected parsers will be processed."
                                    ),
                                    "type": "autocomplete",
                                    "items": [
                                        "winreg/amcache",
                                        "sqlite/dropbox",
                                        "text/skydrive_log_v2",
                                        "winreg/ccleaner",
                                        "sqlite/twitter_android",
                                        "plist/macos_login_window_plist",
                                        "text/cri_log",
                                        "text/powershell_transcript",
                                        "winevt",
                                        "olecf/olecf_automatic_destinations",
                                        "text/viminfo",
                                        "plist/ipod_device",
                                        "czip/oxml",
                                        "plist/airport",
                                        "plist/time_machine",
                                        "wincc_sys",
                                        "text",
                                        "text/xchatscrollback",
                                        "utmpx",
                                        "jsonl/aws_cloudtrail_log",
                                        "plist/macos_install_history",
                                        "pls_recall",
                                        "plist/macos_bluetooth",
                                        "sqlite/chrome_8_history",
                                        "sqlite/hangouts_messages",
                                        "winreg/bam",
                                        "text/android_logcat",
                                        "text/setupapi",
                                        "winreg/mrulist_shell_item_list",
                                        "winreg/windows_task_cache",
                                        "winpca_dic",
                                        "winreg/mrulistex_shell_item_list",
                                        "winreg/mstsc_rdp",
                                        "winreg/microsoft_outlook_mru",
                                        "sqlite/android_calls",
                                        "sqlite/windows_push_notification",
                                        "winreg/windows_run",
                                        "text/winfirewall",
                                        "spotlight_storedb",
                                        "sqlite/safari_historydb",
                                        "text/gdrive_synclog",
                                        "esedb",
                                        "text/teamviewer_connections_incoming",
                                        "text/mac_appfirewall_log",
                                        "sqlite/ios_screentime",
                                        "winevtx",
                                        "sqlite/appusage",
                                        "text/confluence_access",
                                        "mft",
                                        "winreg/windows_version",
                                        "onedrive_log",
                                        "text/popularity_contest",
                                        "winreg/windows_services",
                                        "windefender_history",
                                        "winreg/windows_usbstor_devices",
                                        "plist/ios_identityservices",
                                        "usnjrnl",
                                        "trendmicro_vd",
                                        "prefetch",
                                        "text/aws_elb_access",
                                        "mac_keychain",
                                        "sqlite/edge_load_statistics",
                                        "filestat",
                                        "jsonl/azure_activity_log",
                                        "sqlite/android_webviewcache",
                                        "sqlite/imessage",
                                        "sqlite/chrome_17_cookies",
                                        "plist/safari_history",
                                        "msiecf",
                                        "sqlite/ios_powerlog",
                                        "sqlite/firefox_history",
                                        "locate_database",
                                        "text/snort_fastlog",
                                        "esedb/msie_webcache",
                                        "jsonl/docker_container_log",
                                        "trendmicro_url",
                                        "sqlite/mac_document_versions",
                                        "text/ios_lockdownd",
                                        "winreg/bagmru",
                                        "chrome_preferences",
                                        "sqlite/ls_quarantine",
                                        "sqlite/ios_datausage",
                                        "sqlite",
                                        "simatic_s7",
                                        "czip",
                                        "plist/macos_login_items_plist",
                                        "plist/plist_default",
                                        "winreg/mrulist_string",
                                        "sqlite/firefox_118_downloads",
                                        "text/teamviewer_application_log",
                                        "firefox_cache",
                                        "sqlite/android_webview",
                                        "winreg",
                                        "winpca_db0",
                                        "text/teamviewer_connections_outgoing",
                                        "sqlite/twitter_ios",
                                        "olecf",
                                        "bsm_log",
                                        "opera_global",
                                        "text/googlelog",
                                        "android_app_usage",
                                        "mcafee_protection",
                                        "winreg/microsoft_office_mru",
                                        "sqlite/windows_eventtranscript",
                                        "asl_log",
                                        "fish_history",
                                        "winreg/explorer_mountpoints2",
                                        "sqlite/kodi",
                                        "winreg/mrulistex_string",
                                        "winreg/networks",
                                        "text/winiis",
                                        "sqlite/android_sms",
                                        "cups_ipp",
                                        "winreg/winrar_mru",
                                        "lnk",
                                        "bencode/bencode_utorrent",
                                        "jsonl",
                                        "plist/launchd_plist",
                                        "winreg/windows_sam_users",
                                        "plist/macuser",
                                        "text/skydrive_log_v1",
                                        "text/mac_wifi",
                                        "plist/spotlight",
                                        "symantec_scanlog",
                                        "text/ios_sysdiag_log",
                                        "winreg/msie_zone",
                                        "winreg/userassist",
                                        "jsonl/ios_application_privacy",
                                        "sqlite/chrome_27_history",
                                        "text/vsftpd",
                                        "bencode/bencode_transmission",
                                        "fseventsd",
                                        "olecf/olecf_default",
                                        "jsonl/microsoft_audit_log",
                                        "unified_logging",
                                        "java_idx",
                                        "sqlite/chrome_extension_activity",
                                        "sqlite/kik_ios",
                                        "opera_typed_history",
                                        "sqlite/windows_timeline",
                                        "text/sccm",
                                        "sqlite/tango_android_profile",
                                        "sqlite/firefox_10_cookies",
                                        "sqlite/macostcc",
                                        "text/macos_launchd_log",
                                        "chrome_cache",
                                        "custom_destinations",
                                        "winreg/network_drives",
                                        "plist/ios_carplay",
                                        "olecf/olecf_summary",
                                        "sqlite/tango_android_tc",
                                        "utmp",
                                        "sqlite/chrome_autofill",
                                        "sqlite/firefox_downloads",
                                        "bodyfile",
                                        "sqlite/android_app_usage",
                                        "text/selinux",
                                        "plist/macos_software_update",
                                        "pe",
                                        "plist/apple_id",
                                        "text/syslog_traditional",
                                        "winreg/windows_boot_execute",
                                        "systemd_journal",
                                        "firefox_cache2",
                                        "text/apache_access",
                                        "plist/macos_background_items_plist",
                                        "jsonl/docker_layer_config",
                                        "winreg/windows_boot_verify",
                                        "text/ios_logd",
                                        "networkminer_fileinfo",
                                        "winreg/mrulistex_string_and_shell_item",
                                        "esedb/file_history",
                                        "sqlite/mac_notes",
                                        "sqlite/chrome_66_cookies",
                                        "text/sophos_av",
                                        "esedb/srum",
                                        "bencode",
                                        "winreg/winreg_default",
                                        "text/xchatlog",
                                        "sqlite/zeitgeist",
                                        "text/postgresql",
                                        "sqlite/firefox_2_cookies",
                                        "winreg/windows_usb_devices",
                                        "winreg/windows_timezone",
                                        "binary_cookies",
                                        "winjob",
                                        "recycle_bin_info2",
                                        "plist/safari_downloads",
                                        "sqlite/ios_netusage",
                                        "text/apt_history",
                                        "plist/spotlight_volume",
                                        "sqlite/skype",
                                        "sqlite/google_drive",
                                        "winreg/windows_typed_urls",
                                        "jsonl/docker_container_config",
                                        "text/dpkg",
                                        "text/zsh_extended_history",
                                        "text/syslog",
                                        "sqlite/mackeeper_cache",
                                        "winreg/mstsc_rdp_mru",
                                        "winreg/windows_shutdown",
                                        "olecf/olecf_document_summary",
                                        "winreg/appcompatcache",
                                        "winreg/mrulistex_string_and_shell_item_list",
                                        "text/santa",
                                        "winreg/winlogon",
                                        "text/bash_history",
                                        "text/mac_securityd",
                                        "recycle_bin",
                                        "sqlite/android_turbo",
                                        "jsonl/azure_application_gateway_access_log",
                                        "rplog",
                                        "winreg/explorer_programscache",
                                        "esedb/user_access_logging",
                                        "jsonl/gcp_log",
                                        "sqlite/mac_knowledgec",
                                        "plist/macos_startup_item_plist",
                                        "plist",
                                    ],
                                    "required": False,
                                },
                                {
                                    "name": "archives",
                                    "label": "Archives",
                                    "description": (
                                        "Select one or more Plaso archive types. "
                                        "Files inside these archive types will be processed."
                                    ),
                                    "type": "autocomplete",
                                    "items": ["iso9660", "modi", "tar", "vhdi", "zip"],
                                    "required": False,
                                },
                            ],
                            "type": "task",
                            "uuid": f"{plaso_task_uuid}",
                            "tasks": [],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def add_plaso_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name):
    """
    Add tasks to an existing workflow, including a Plaso task and a Timesketch task.
    """
    plaso_task_uuid = str(uuid.uuid4()).replace("-", "")
    timesketch_task_uuid = str(uuid.uuid4()).replace("-", "")

    task_config = [
        {
            "name": "sketch_name",
            "label": "Create a new sketch",
            "description": "Create a new sketch",
            "type": "text",
            "required": False,
            "value": f"{sketch_name}",
        },
        {
            "name": "timeline_name",
            "label": "Name of the timeline to create",
            "description": "Timeline name",
            "type": "text",
            "required": False,
            "value": f"{timeline_name}"
        }
    ]
    if sketch_id != "":
        task_config = [
            {
                "name": "sketch_id",
                "label": "Add to existing sketch",
                "description": "Add to existing sketch",
                "type": "text",
                "required": False,
                "value": f"{sketch_id}",
            },
            {
                "name": "timeline_name",
                "label": "Name of the timeline to create",
                "description": "Timeline name",
                "type": "text",
                "required": False,
                "value": f"{timeline_name}"
            }
        ]
        
    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-plaso.tasks.log2timeline",
                            "queue_name": "openrelik-worker-plaso",
                            "display_name": "Plaso: Log2Timeline",
                            "description": "Super timelining",
                            "task_config": [
                                {
                                    "name": "artifacts",
                                    "label": "Select artifacts to parse",
                                    "description": (
                                        "Select one or more forensic artifact definitions "
                                        "from the ForensicArtifacts project. These definitions "
                                        "specify files and data relevant to digital forensic "
                                        "investigations. Only the selected artifacts will be "
                                        "parsed."
                                    ),
                                    "type": "artifacts",
                                    "required": False,
                                },
                                {
                                    "name": "parsers",
                                    "label": "Select parsers to use",
                                    "description": (
                                        "Select one or more Plaso parsers. These parsers specify "
                                        "how to interpret files and data. Only data identified by "
                                        "the selected parsers will be processed."
                                    ),
                                    "type": "autocomplete",
                                    "items": [
                                        "winreg/amcache",
                                        "sqlite/dropbox",
                                        "text/skydrive_log_v2",
                                        "winreg/ccleaner",
                                        "sqlite/twitter_android",
                                        "plist/macos_login_window_plist",
                                        "text/cri_log",
                                        "text/powershell_transcript",
                                        "winevt",
                                        "olecf/olecf_automatic_destinations",
                                        "text/viminfo",
                                        "plist/ipod_device",
                                        "czip/oxml",
                                        "plist/airport",
                                        "plist/time_machine",
                                        "wincc_sys",
                                        "text",
                                        "text/xchatscrollback",
                                        "utmpx",
                                        "jsonl/aws_cloudtrail_log",
                                        "plist/macos_install_history",
                                        "pls_recall",
                                        "plist/macos_bluetooth",
                                        "sqlite/chrome_8_history",
                                        "sqlite/hangouts_messages",
                                        "winreg/bam",
                                        "text/android_logcat",
                                        "text/setupapi",
                                        "winreg/mrulist_shell_item_list",
                                        "winreg/windows_task_cache",
                                        "winpca_dic",
                                        "winreg/mrulistex_shell_item_list",
                                        "winreg/mstsc_rdp",
                                        "winreg/microsoft_outlook_mru",
                                        "sqlite/android_calls",
                                        "sqlite/windows_push_notification",
                                        "winreg/windows_run",
                                        "text/winfirewall",
                                        "spotlight_storedb",
                                        "sqlite/safari_historydb",
                                        "text/gdrive_synclog",
                                        "esedb",
                                        "text/teamviewer_connections_incoming",
                                        "text/mac_appfirewall_log",
                                        "sqlite/ios_screentime",
                                        "winevtx",
                                        "sqlite/appusage",
                                        "text/confluence_access",
                                        "mft",
                                        "winreg/windows_version",
                                        "onedrive_log",
                                        "text/popularity_contest",
                                        "winreg/windows_services",
                                        "windefender_history",
                                        "winreg/windows_usbstor_devices",
                                        "plist/ios_identityservices",
                                        "usnjrnl",
                                        "trendmicro_vd",
                                        "prefetch",
                                        "text/aws_elb_access",
                                        "mac_keychain",
                                        "sqlite/edge_load_statistics",
                                        "filestat",
                                        "jsonl/azure_activity_log",
                                        "sqlite/android_webviewcache",
                                        "sqlite/imessage",
                                        "sqlite/chrome_17_cookies",
                                        "plist/safari_history",
                                        "msiecf",
                                        "sqlite/ios_powerlog",
                                        "sqlite/firefox_history",
                                        "locate_database",
                                        "text/snort_fastlog",
                                        "esedb/msie_webcache",
                                        "jsonl/docker_container_log",
                                        "trendmicro_url",
                                        "sqlite/mac_document_versions",
                                        "text/ios_lockdownd",
                                        "winreg/bagmru",
                                        "chrome_preferences",
                                        "sqlite/ls_quarantine",
                                        "sqlite/ios_datausage",
                                        "sqlite",
                                        "simatic_s7",
                                        "czip",
                                        "plist/macos_login_items_plist",
                                        "plist/plist_default",
                                        "winreg/mrulist_string",
                                        "sqlite/firefox_118_downloads",
                                        "text/teamviewer_application_log",
                                        "firefox_cache",
                                        "sqlite/android_webview",
                                        "winreg",
                                        "winpca_db0",
                                        "text/teamviewer_connections_outgoing",
                                        "sqlite/twitter_ios",
                                        "olecf",
                                        "bsm_log",
                                        "opera_global",
                                        "text/googlelog",
                                        "android_app_usage",
                                        "mcafee_protection",
                                        "winreg/microsoft_office_mru",
                                        "sqlite/windows_eventtranscript",
                                        "asl_log",
                                        "fish_history",
                                        "winreg/explorer_mountpoints2",
                                        "sqlite/kodi",
                                        "winreg/mrulistex_string",
                                        "winreg/networks",
                                        "text/winiis",
                                        "sqlite/android_sms",
                                        "cups_ipp",
                                        "winreg/winrar_mru",
                                        "lnk",
                                        "bencode/bencode_utorrent",
                                        "jsonl",
                                        "plist/launchd_plist",
                                        "winreg/windows_sam_users",
                                        "plist/macuser",
                                        "text/skydrive_log_v1",
                                        "text/mac_wifi",
                                        "plist/spotlight",
                                        "symantec_scanlog",
                                        "text/ios_sysdiag_log",
                                        "winreg/msie_zone",
                                        "winreg/userassist",
                                        "jsonl/ios_application_privacy",
                                        "sqlite/chrome_27_history",
                                        "text/vsftpd",
                                        "bencode/bencode_transmission",
                                        "fseventsd",
                                        "olecf/olecf_default",
                                        "jsonl/microsoft_audit_log",
                                        "unified_logging",
                                        "java_idx",
                                        "sqlite/chrome_extension_activity",
                                        "sqlite/kik_ios",
                                        "opera_typed_history",
                                        "sqlite/windows_timeline",
                                        "text/sccm",
                                        "sqlite/tango_android_profile",
                                        "sqlite/firefox_10_cookies",
                                        "sqlite/macostcc",
                                        "text/macos_launchd_log",
                                        "chrome_cache",
                                        "custom_destinations",
                                        "winreg/network_drives",
                                        "plist/ios_carplay",
                                        "olecf/olecf_summary",
                                        "sqlite/tango_android_tc",
                                        "utmp",
                                        "sqlite/chrome_autofill",
                                        "sqlite/firefox_downloads",
                                        "bodyfile",
                                        "sqlite/android_app_usage",
                                        "text/selinux",
                                        "plist/macos_software_update",
                                        "pe",
                                        "plist/apple_id",
                                        "text/syslog_traditional",
                                        "winreg/windows_boot_execute",
                                        "systemd_journal",
                                        "firefox_cache2",
                                        "text/apache_access",
                                        "plist/macos_background_items_plist",
                                        "jsonl/docker_layer_config",
                                        "winreg/windows_boot_verify",
                                        "text/ios_logd",
                                        "networkminer_fileinfo",
                                        "winreg/mrulistex_string_and_shell_item",
                                        "esedb/file_history",
                                        "sqlite/mac_notes",
                                        "sqlite/chrome_66_cookies",
                                        "text/sophos_av",
                                        "esedb/srum",
                                        "bencode",
                                        "winreg/winreg_default",
                                        "text/xchatlog",
                                        "sqlite/zeitgeist",
                                        "text/postgresql",
                                        "sqlite/firefox_2_cookies",
                                        "winreg/windows_usb_devices",
                                        "winreg/windows_timezone",
                                        "binary_cookies",
                                        "winjob",
                                        "recycle_bin_info2",
                                        "plist/safari_downloads",
                                        "sqlite/ios_netusage",
                                        "text/apt_history",
                                        "plist/spotlight_volume",
                                        "sqlite/skype",
                                        "sqlite/google_drive",
                                        "winreg/windows_typed_urls",
                                        "jsonl/docker_container_config",
                                        "text/dpkg",
                                        "text/zsh_extended_history",
                                        "text/syslog",
                                        "sqlite/mackeeper_cache",
                                        "winreg/mstsc_rdp_mru",
                                        "winreg/windows_shutdown",
                                        "olecf/olecf_document_summary",
                                        "winreg/appcompatcache",
                                        "winreg/mrulistex_string_and_shell_item_list",
                                        "text/santa",
                                        "winreg/winlogon",
                                        "text/bash_history",
                                        "text/mac_securityd",
                                        "recycle_bin",
                                        "sqlite/android_turbo",
                                        "jsonl/azure_application_gateway_access_log",
                                        "rplog",
                                        "winreg/explorer_programscache",
                                        "esedb/user_access_logging",
                                        "jsonl/gcp_log",
                                        "sqlite/mac_knowledgec",
                                        "plist/macos_startup_item_plist",
                                        "plist",
                                    ],
                                    "required": False,
                                },
                                {
                                    "name": "archives",
                                    "label": "Archives",
                                    "description": (
                                        "Select one or more Plaso archive types. "
                                        "Files inside these archive types will be processed."
                                    ),
                                    "type": "autocomplete",
                                    "items": ["iso9660", "modi", "tar", "vhdi", "zip"],
                                    "required": False,
                                },
                            ],
                            "type": "task",
                            "uuid": f"{plaso_task_uuid}",
                            "tasks": [
                                {
                                    "task_name": "openrelik-worker-timesketch.tasks.upload",
                                    "queue_name": "openrelik-worker-timesketch",
                                    "display_name": "Upload to Timesketch",
                                    "description": "Upload resulting file to Timesketch",
                                    "task_config": task_config,
                                    "type": "task",
                                    "uuid": f"{timesketch_task_uuid}",
                                    "tasks": [],
                                }
                            ],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def add_extract_plaso_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name):
    """
    Add tasks to an existing workflow: Extract → Plaso → Timesketch.
    Used when the uploaded file is an archive (zip, tar, etc.) that needs
    extraction before Plaso processing.
    """
    extraction_task_uuid = str(uuid.uuid4()).replace("-", "")
    plaso_task_uuid = str(uuid.uuid4()).replace("-", "")
    timesketch_task_uuid = str(uuid.uuid4()).replace("-", "")

    ts_task_config = [
        {
            "name": "sketch_name",
            "label": "Create a new sketch",
            "description": "Create a new sketch",
            "type": "text",
            "required": False,
            "value": f"{sketch_name}",
        },
        {
            "name": "timeline_name",
            "label": "Name of the timeline to create",
            "description": "Timeline name",
            "type": "text",
            "required": False,
            "value": f"{timeline_name}"
        }
    ]
    if sketch_id != "":
        ts_task_config = [
            {
                "name": "sketch_id",
                "label": "Add to existing sketch",
                "description": "Add to existing sketch",
                "type": "text",
                "required": False,
                "value": f"{sketch_id}",
            },
            {
                "name": "timeline_name",
                "label": "Name of the timeline to create",
                "description": "Timeline name",
                "type": "text",
                "required": False,
                "value": f"{timeline_name}"
            }
        ]

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-extraction.tasks.extract_archive",
                            "queue_name": "openrelik-worker-extraction",
                            "display_name": "Extract Archives",
                            "description": "Extract files from archive",
                            "task_config": [],
                            "type": "task",
                            "uuid": f"{extraction_task_uuid}",
                            "tasks": [
                                {
                                    "task_name": "openrelik-worker-plaso.tasks.log2timeline",
                                    "queue_name": "openrelik-worker-plaso",
                                    "display_name": "Plaso: Log2Timeline",
                                    "description": "Super timelining",
                                    "task_config": [],
                                    "type": "task",
                                    "uuid": f"{plaso_task_uuid}",
                                    "tasks": [
                                        {
                                            "task_name": "openrelik-worker-timesketch.tasks.upload",
                                            "queue_name": "openrelik-worker-timesketch",
                                            "display_name": "Upload to Timesketch",
                                            "description": "Upload resulting file to Timesketch",
                                            "task_config": ts_task_config,
                                            "type": "task",
                                            "uuid": f"{timesketch_task_uuid}",
                                            "tasks": [],
                                        }
                                    ],
                                }
                            ],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def add_hayabusa_tasks_to_workflow(folder_id, workflow_id):
    """
    Add tasks to an existing workflow, including a Plaso task and a Timesketch task.
    """
    hayabusa_task_uuid = str(uuid.uuid4()).replace("-", "")
    timesketch_task_uuid = str(uuid.uuid4()).replace("-", "")

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-hayabusa.tasks.csv_timeline",
                            "queue_name": "openrelik-worker-hayabusa",
                            "display_name": "Hayabusa CSV timeline",
                            "description": "Windows event log triage",
                            "type": "task",
                            "uuid": f"{hayabusa_task_uuid}",
                            "tasks": [],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def add_hayabusa_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name):
    """
    Add tasks to an existing workflow, including a Plaso task and a Timesketch task.
    """
    hayabusa_task_uuid = str(uuid.uuid4()).replace("-", "")
    timesketch_task_uuid = str(uuid.uuid4()).replace("-", "")

    task_config = [
        {
            "name": "sketch_name",
            "label": "Create a new sketch",
            "description": "Create a new sketch",
            "type": "text",
            "required": False,
            "value": f"{sketch_name}",
        },
        {
            "name": "timeline_name",
            "label": "Name of the timeline to create",
            "description": "Timeline name",
            "type": "text",
            "required": False,
            "value": f"{timeline_name}"
        }
    ]
    if sketch_id != "":
        task_config = [
            {
                "name": "sketch_id",
                "label": "Add to existing sketch",
                "description": "Add to existing sketch",
                "type": "text",
                "required": False,
                "value": f"{sketch_id}",
            },
            {
                "name": "timeline_name",
                "label": "Name of the timeline to create",
                "description": "Timeline name",
                "type": "text",
                "required": False,
                "value": f"{timeline_name}"
            }
        ]

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-hayabusa.tasks.csv_timeline",
                            "queue_name": "openrelik-worker-hayabusa",
                            "display_name": "Hayabusa CSV timeline",
                            "description": "Windows event log triage",
                            "type": "task",
                            "uuid": f"{hayabusa_task_uuid}",
                            "tasks": [
                                {
                                    "task_name": "openrelik-worker-timesketch.tasks.upload",
                                    "queue_name": "openrelik-worker-timesketch",
                                    "display_name": "Upload to Timesketch",
                                    "description": "Upload resulting file to Timesketch",
                                    "task_config": task_config,
                                    "type": "task",
                                    "uuid": f"{timesketch_task_uuid}",
                                    "tasks": [],
                                }
                            ],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def add_hayabusa_extract_tasks_to_workflow(folder_id, workflow_id):
    """
    Add tasks to an existing workflow, including a Plaso task and a Timesketch task.
    """
    hayabusa_task_uuid = str(uuid.uuid4()).replace("-", "")
    extraction_task_uuid = str(uuid.uuid4()).replace("-", "")

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-extraction.tasks.extract_archive",
                            "queue_name": "openrelik-worker-extraction",
                            "display_name": "Extract Archives",
                            "description": "Extract different types of archives",
                            "task_config": [
                                {
                                    "name": "file_filter",
                                    "label": "Select files (glob patterns) to extract",
                                    "description": "A comma separated list of filenames to extract. Glob patterns are supported. Example: *.txt, *.evtx",
                                    "type": "text",
                                    "required": True,
                                    "value": "*.evtx",
                                }
                            ],
                            "type": "task",
                            "uuid": f"{extraction_task_uuid}",
                            "tasks": [
                                {
                                    "task_name": "openrelik-worker-hayabusa.tasks.csv_timeline",
                                    "queue_name": "openrelik-worker-hayabusa",
                                    "display_name": "Hayabusa CSV timeline",
                                    "description": "Windows event log triage",
                                    "type": "task",
                                    "uuid": f"{hayabusa_task_uuid}",
                                    "tasks": [],
                                }
                            ],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def add_hayabusa_extract_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name):
    """
    Add tasks to an existing workflow, including a Plaso task and a Timesketch task.
    """
    hayabusa_task_uuid = str(uuid.uuid4()).replace("-", "")
    timesketch_task_uuid = str(uuid.uuid4()).replace("-", "")
    extraction_task_uuid = str(uuid.uuid4()).replace("-", "")

    task_config = [
        {
            "name": "sketch_name",
            "label": "Create a new sketch",
            "description": "Create a new sketch",
            "type": "text",
            "required": False,
            "value": f"{sketch_name}",
        }
    ]
    if sketch_id != "":
        task_config = [
            {
                "name": "sketch_id",
                "label": "Add to existing sketch",
                "description": "Add to existing sketch",
                "type": "text",
                "required": False,
                "value": f"{sketch_id}",
            }
        ]

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": [
                        {
                            "task_name": "openrelik-worker-extraction.tasks.extract_archive",
                            "queue_name": "openrelik-worker-extraction",
                            "display_name": "Extract Archives",
                            "description": "Extract different types of archives",
                            "task_config": [
                                {
                                    "name": "file_filter",
                                    "label": "Select files (glob patterns) to extract",
                                    "description": "A comma separated list of filenames to extract. Glob patterns are supported. Example: *.txt, *.evtx",
                                    "type": "text",
                                    "required": True,
                                    "value": "*.evtx",
                                }
                            ],
                            "type": "task",
                            "uuid": f"{extraction_task_uuid}",
                            "tasks": [
                                {
                                    "task_name": "openrelik-worker-hayabusa.tasks.csv_timeline",
                                    "queue_name": "openrelik-worker-hayabusa",
                                    "display_name": "Hayabusa CSV timeline",
                                    "description": "Windows event log triage",
                                    "type": "task",
                                    "uuid": f"{hayabusa_task_uuid}",
                                    "tasks": [
                                        {
                                            "task_name": "openrelik-worker-timesketch.tasks.upload",
                                            "queue_name": "openrelik-worker-timesketch",
                                            "display_name": "Upload to Timesketch",
                                            "description": "Upload resulting file to Timesketch",
                                            "task_config": task_config,
                                            "type": "task",
                                            "uuid": f"{timesketch_task_uuid}",
                                            "tasks": [],
                                        }
                                    ],
                                }
                            ],
                        }
                    ],
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def _ts_task_config(sketch_name, sketch_id, timeline_name):
    """Build a Timesketch-upload task_config list, preferring sketch_id over sketch_name."""
    base = [
        {
            "name": "timeline_name",
            "label": "Name of the timeline to create",
            "description": "Timeline name",
            "type": "text",
            "required": False,
            "value": f"{timeline_name}",
        }
    ]
    if sketch_id != "":
        return [
            {
                "name": "sketch_id",
                "label": "Add to existing sketch",
                "description": "Add to existing sketch",
                "type": "text",
                "required": False,
                "value": f"{sketch_id}",
            },
            *base,
        ]
    return [
        {
            "name": "sketch_name",
            "label": "Create a new sketch",
            "description": "Create a new sketch",
            "type": "text",
            "required": False,
            "value": f"{sketch_name}",
        },
        *base,
    ]


def _ts_leaf(sketch_name, sketch_id, timeline_name):
    """Return a Timesketch-upload task dict suitable for use as a leaf node in a workflow tree."""
    return {
        "task_name": "openrelik-worker-timesketch.tasks.upload",
        "queue_name": "openrelik-worker-timesketch",
        "display_name": "Upload to Timesketch",
        "description": "Upload resulting file to Timesketch",
        "task_config": _ts_task_config(sketch_name, sketch_id, timeline_name),
        "type": "task",
        "uuid": str(uuid.uuid4()).replace("-", ""),
        "tasks": [],
    }


def _stamp_then_ts(stamp_task_name, sketch_name, sketch_id, timeline_name):
    """Return a stamp_X -> ts.upload sub-tree.

    Inserts the host-fingerprint stamper between an analyser branch and
    the Timesketch upload, so every event in the resulting timeline
    carries the full ECS host.* set (host.id + host.fqdn + host.name +
    host.machine_guid + host.vr_client_id + host.mac, where populated)
    propagated from the sidecar emitted by the derive_id sibling task.

    The stamper finds the sidecar at runtime via the OR file API
    (data_type=openrelik:host-fingerprint:sidecar). If no sidecar is
    available -- e.g. derive_id failed, or this workflow isn't a
    triage-from-VR shape -- the stamper passes the analyser output
    through verbatim and the ts.upload step still runs.

    Used by the Hayabusa (CSV) and Plaso / Chainsaw (JSONL) branches.
    """
    return {
        "task_name": stamp_task_name,
        "queue_name": "openrelik-worker-host-fingerprint",
        "display_name": (
            "Host Fingerprint: stamp host.* on CSV"
            if "stamp_csv" in stamp_task_name
            else "Host Fingerprint: stamp host.* on JSONL"
        ),
        "description": (
            "Append ECS host.* columns / fields from the derive_id sidecar "
            "to every event before Timesketch upload."
        ),
        "task_config": [],
        "type": "task",
        "uuid": str(uuid.uuid4()).replace("-", ""),
        "tasks": [
            _ts_leaf(sketch_name, sketch_id, timeline_name),
        ],
    }


def _stamp_csv_then_ts(sketch_name, sketch_id, timeline_name):
    return _stamp_then_ts(
        "openrelik-worker-host-fingerprint.tasks.stamp_csv",
        sketch_name, sketch_id, timeline_name,
    )


def _stamp_jsonl_then_ts(sketch_name, sketch_id, timeline_name):
    return _stamp_then_ts(
        "openrelik-worker-host-fingerprint.tasks.stamp_jsonl",
        sketch_name, sketch_id, timeline_name,
    )


# Phase B of the high-value-artefacts ticket: surface each of these
# Plaso parsers as its own TS timeline instead of leaving them buried
# in the super-timeline. Order: (plaso_parser, analyst-facing label).
#
# Adding an entry here adds a new sibling branch under Plaso. The
# split task filters Plaso's super-timeline JSONL down to one
# parser, then the shared stamp_jsonl -> ts.upload chain stamps the
# ECS host.* set and uploads as a named timeline. Mirror in
# openrelik-worker-host-fingerprint's PLASO_SPLIT_TIMELINES dict so
# the two stay in sync (worker only cares about the parser-name key;
# pipeline owns the timeline label here).
_PLASO_SPLIT_PARSERS = [
    ("amcache",            "AmCache (Program Execution)"),
    ("appcompatcache",     "ShimCache"),
    ("bam",                "BAM / DAM (Background Activity)"),
    ("winjob",             "Scheduled Tasks"),
    ("powershell_console", "PowerShell History"),
    ("activities_cache",   "Windows Timeline (Activities Cache)"),
    ("userassist",         "UserAssist / Recent Apps"),
]


def _plaso_split_then_stamp_then_ts(
    sketch_name, sketch_id, timeline_name_base, parser, parser_label,
):
    """Return a split_jsonl_by_parser -> stamp_jsonl -> ts.upload
    sub-tree for one Phase B parser. Used as a sibling of Plaso's
    direct ts.upload branch so the super-timeline still lands AND the
    split timeline lands."""
    timeline_name = f"{timeline_name_base} - {parser_label}"
    return {
        "task_name": "openrelik-worker-host-fingerprint.tasks.split_jsonl_by_parser",
        "queue_name": "openrelik-worker-host-fingerprint",
        "display_name": f"Plaso split: {parser_label}",
        "description": (
            f"Filter Plaso super-timeline JSONL to events from parser "
            f"`{parser}` for the {parser_label} TimeSketch timeline."
        ),
        "task_config": [
            {
                "name": "parser",
                "type": "string",
                "required": True,
                "value": parser,
            }
        ],
        "type": "task",
        "uuid": str(uuid.uuid4()).replace("-", ""),
        "tasks": [
            _stamp_jsonl_then_ts(sketch_name, sketch_id, timeline_name),
        ],
    }


def add_triage_ts_tasks_to_workflow(
    folder_id,
    workflow_id,
    sketch_name,
    sketch_id,
    timeline_name,
    chainsaw_min_level="high",
    is_archive=True,
    source_archive_name=None,
):
    """
    Catchall triage workflow: optional extract -> fan out to every known
    analyser -> each branch uploads its own timeline to Timesketch.

    Two layouts depending on input shape:

        is_archive=True (.zip / .tar.gz / .7z / ...):
            extract_archive
              ├── derive_id (host-fingerprint)   -> sidecar JSON in workflow
              ├── parse_cache (rdp-cache)        -> tile / collage / manifest artefacts
              ├── parse_onedrive (onedrive)      -> per-tenant report JSON + manifest
              ├── hayabusa csv_timeline   -> stamp_csv   -> ts (timeline: "<base> - Hayabusa")
              ├── chainsaw hunt_evtx      -> stamp_jsonl -> ts (timeline: "<base> - Chainsaw Sigma")
              ├── chainsaw builtin_only   -> stamp_jsonl -> ts (timeline: "<base> - Chainsaw Built-in")
              ├── chainsaw analyse_srum   -> stamp_jsonl -> ts (timeline: "<base> - Chainsaw SRUM")
              └── plaso log2timeline
                    ├── stamp_jsonl -> ts ("<base> - Plaso" -- the super-timeline)
                    ├── split[amcache]            -> stamp_jsonl -> ts ("<base> - AmCache ...")
                    ├── split[appcompatcache]     -> stamp_jsonl -> ts ("<base> - ShimCache")
                    ├── split[bam]                -> stamp_jsonl -> ts ("<base> - BAM / DAM ...")
                    ├── split[winjob]             -> stamp_jsonl -> ts ("<base> - Scheduled Tasks")
                    ├── split[powershell_console] -> stamp_jsonl -> ts ("<base> - PowerShell History")
                    ├── split[activities_cache]   -> stamp_jsonl -> ts ("<base> - Windows Timeline ...")
                    └── split[userassist]         -> stamp_jsonl -> ts ("<base> - UserAssist ...")

        is_archive=False (.evtx / .log / .pf / loose registry hive / ...):
            Same shape, no extract_archive parent.

    The plain-input branch skips extract_archive because the extraction
    worker invokes 7zip then tar and raises on non-archive input
    ("7zip or tar execution error."). Mirrors the same conditional that
    PR #73 added to the network endpoint -- typical analyst use case is
    a single loose .evtx or .pf dropped in for ad-hoc inspection.

    Each worker's compatible-input filter picks up only what it knows
    and silently no-ops on everything else -- so a bare .log fed to
    triage will fan out to all five analysers but only plaso (which
    parses many text-log shapes) will likely produce events. That's
    consistent with how the network endpoint behaves and never
    hard-errors.

    Host-fingerprint integration (PR 3 + PR 4 of the rollout):
    `derive_id` is added as a SIBLING branch (parallel to the
    analysers, not a parent), so it runs alongside without gating
    fan-out. It produces a sidecar JSON tagged
    `data_type=openrelik:host-fingerprint:sidecar` that's visible in
    the OR UI and queryable by analysts.

    `stamp_csv` (between hayabusa and ts.upload) and `stamp_jsonl`
    (between plaso / chainsaw branches and ts.upload) propagate the
    full ECS host.* set onto every event:
        host.id, host.fqdn, host.name, host.machine_guid,
        host.vr_client_id, host.mac (where populated).
    Sidecar is canonical -- if any analyser already wrote one of those
    fields (e.g. chainsaw self-derives host.id via PR #8 of its repo),
    the stamper overwrites it for single-source-of-truth across all
    triage branches.

    RDP cache (Phase C #1) is also a SIBLING branch with no children:
    parse_cache picks up `bcache*.bmc` / `Cache????.bin` files from the
    extracted set and emits per-tile + collage BMP artefacts plus a
    manifest JSON, all visible in the workflow folder. Not TS-bound --
    the tiles have no event timestamps.
    """
    hayabusa_uuid = str(uuid.uuid4()).replace("-", "")
    chainsaw_hunt_uuid = str(uuid.uuid4()).replace("-", "")
    chainsaw_builtin_uuid = str(uuid.uuid4()).replace("-", "")
    chainsaw_srum_uuid = str(uuid.uuid4()).replace("-", "")
    plaso_uuid = str(uuid.uuid4()).replace("-", "")
    host_fingerprint_uuid = str(uuid.uuid4()).replace("-", "")
    rdp_cache_uuid = str(uuid.uuid4()).replace("-", "")
    onedrive_uuid = str(uuid.uuid4()).replace("-", "")

    analyser_branches = [
        {
            "task_name": "openrelik-worker-hayabusa.tasks.csv_timeline",
            "queue_name": "openrelik-worker-hayabusa",
            "display_name": "Hayabusa CSV timeline",
            "description": "Windows event log triage",
            "task_config": [],
            "type": "task",
            "uuid": f"{hayabusa_uuid}",
            "tasks": [
                # Hayabusa output is CSV -> stamp_csv -> ts.upload.
                # Stamper appends ECS host.* columns to every row from
                # the derive_id sidecar before TS ingestion.
                _stamp_csv_then_ts(
                    sketch_name,
                    sketch_id,
                    f"{timeline_name} - Hayabusa",
                )
            ],
        },
        {
            "task_name": "openrelik-worker-chainsaw.tasks.hunt_evtx",
            "queue_name": "openrelik-worker-chainsaw",
            "display_name": "Chainsaw: Hunt EVTX (Sigma + built-ins)",
            "description": "Run SigmaHQ + Chainsaw built-in rules against EVTX",
            "task_config": [
                {
                    "name": "min_level",
                    "label": "Minimum detection level",
                    "description": "Restrict loaded Sigma rules to this level or higher",
                    "type": "select",
                    "required": False,
                    "value": f"{chainsaw_min_level}",
                }
            ],
            "type": "task",
            "uuid": f"{chainsaw_hunt_uuid}",
            "tasks": [
                # Chainsaw outputs JSONL via timesketch_mapper. Stamper
                # overwrites chainsaw's self-derived host.id (PR #8 of
                # chainsaw worker) with the sidecar value -- single
                # source of truth across all triage branches.
                _stamp_jsonl_then_ts(
                    sketch_name,
                    sketch_id,
                    f"{timeline_name} - Chainsaw Sigma",
                )
            ],
        },
        {
            "task_name": "openrelik-worker-chainsaw.tasks.builtin_only",
            "queue_name": "openrelik-worker-chainsaw",
            "display_name": "Chainsaw: Built-in rules only",
            "description": "Chainsaw built-in rules (AV alerts, log-clearing) without Sigma",
            "task_config": [],
            "type": "task",
            "uuid": f"{chainsaw_builtin_uuid}",
            "tasks": [
                _stamp_jsonl_then_ts(
                    sketch_name,
                    sketch_id,
                    f"{timeline_name} - Chainsaw Built-in",
                )
            ],
        },
        {
            "task_name": "openrelik-worker-chainsaw.tasks.analyse_srum",
            "queue_name": "openrelik-worker-chainsaw",
            "display_name": "Chainsaw: Analyse SRUM database",
            "description": "Parse SRUDB.dat (requires SOFTWARE hive in the same input set)",
            "task_config": [],
            "type": "task",
            "uuid": f"{chainsaw_srum_uuid}",
            "tasks": [
                _stamp_jsonl_then_ts(
                    sketch_name,
                    sketch_id,
                    f"{timeline_name} - Chainsaw SRUM",
                )
            ],
        },
        {
            "task_name": "openrelik-worker-plaso.tasks.log2timeline",
            "queue_name": "openrelik-worker-plaso",
            "display_name": "Plaso: Log2Timeline",
            "description": "Super timelining",
            # Disable Plaso's filestat parser. Without this, every Plaso
            # timeline carries thousands of fs:stat events whose `filename`
            # is the worker's UUID-named internal storage path
            # (OS:/usr/share/openrelik/data/artifacts/.../...) -- not the
            # original artefact path. fs:stat is normally 80-95% of a
            # Plaso timeline; with the OR-scratch-path issue, that's pure
            # noise that pollutes every analyst's sketch. Verified on
            # case-2104 (2026-05-01).
            #
            # Trade-off: this disables filestat globally for the triage
            # workflow. We lose legitimate fs:stat events that would
            # come from raw disk images (where Plaso could see real
            # filesystem paths via TSK). Today our triage input is always
            # a KAPE-style triage zip extracted to OR scratch -- there
            # are no real disk images, so no genuine fs:stat events to
            # preserve. If we ever ingest raw .E01 / .dd / .vmdk via this
            # workflow, revisit this filter (per-workflow task_config or
            # a smarter post-process filter).
            "task_config": [
                {
                    "name": "parsers",
                    "label": "Plaso parsers",
                    "description": "List of parser names with optional `!` negation. Defaults to all parsers minus filestat.",
                    "type": "text",
                    "required": False,
                    # Must be a list, not a string: openrelik-worker-plaso
                    # does `",".join(task_config["parsers"])` -- a bare
                    # string is iterated char-by-char and emitted as
                    # `--parsers !,f,i,l,e,s,t,a,t`, which plaso rejects
                    # and silently processes zero events. Caught on
                    # case-1005 (2026-05-12): 8 missing Plaso timelines.
                    "value": ["!filestat"],
                }
            ],
            "type": "task",
            "uuid": f"{plaso_uuid}",
            "tasks": [
                # log2timeline outputs a binary .plaso storage file;
                # downstream stamp_jsonl / split_jsonl_by_parser tasks
                # only consume JSONL. psort with output_format=json_line
                # is the conversion step that turns the .plaso into a
                # TS-shaped JSONL stream that the rest of the chain can
                # work with. Without this task, every stamp_jsonl in
                # the Plaso branch sees zero JSONL files and emits
                # zero output -- super-timeline + all 7 split
                # timelines land empty in TimeSketch. Caught on
                # case-1006 (2026-05-12): 811 MB .plaso produced,
                # 8 stamp_jsonl tasks all reported
                # `jsonl_files_seen: 0, events_stamped: 0`.
                {
                    "task_name": "openrelik-worker-plaso.tasks.psort",
                    "queue_name": "openrelik-worker-plaso",
                    "display_name": "Plaso: Psort (JSONL)",
                    "description": "Convert .plaso storage to JSONL for downstream stamping + per-parser splits.",
                    "task_config": [
                        {
                            "name": "output_format",
                            "type": "select",
                            "required": False,
                            "value": "json_line",
                        }
                    ],
                    "type": "task",
                    "uuid": str(uuid.uuid4()).replace("-", ""),
                    "tasks": [
                        # Plaso super-timeline: JSONL -> stamp_jsonl -> ts.
                        # Stamper propagates the ECS host.* set from
                        # derive_id's sidecar onto every event so the
                        # super-timeline is queryable by host.id like
                        # every other triage branch.
                        _stamp_jsonl_then_ts(
                            sketch_name,
                            sketch_id,
                            f"{timeline_name} - Plaso",
                        ),
                        # Phase B of the high-value-artefacts ticket:
                        # surface each high-value parser-class as its
                        # own TS timeline alongside the super-timeline.
                        # Each split task filters psort's JSONL down to
                        # one parser; the result flows through
                        # stamp_jsonl -> ts.upload like every other
                        # branch, so split timelines carry the same ECS
                        # host.* set.
                        #
                        # Adding a parser here adds a new timeline.
                        # Keep the list in sync with
                        # PLASO_SPLIT_TIMELINES in
                        # openrelik-worker-host-fingerprint's
                        # host_id_helpers.
                        *[
                            _plaso_split_then_stamp_then_ts(
                                sketch_name, sketch_id, timeline_name,
                                parser=parser, parser_label=parser_label,
                            )
                            for parser, parser_label in _PLASO_SPLIT_PARSERS
                        ],
                    ],
                }
            ],
        },
        # Host-fingerprint sibling (PR 3 of the rollout). Runs in
        # parallel with the analysers; produces a sidecar JSON that
        # downstream stamper tasks (PR 4) will consume to add host.id
        # to upstream worker output. No `tasks: [...]` -- this branch
        # has no children today; sidecar is its only artefact and
        # lands in the workflow folder.
        #
        # source_archive_name passes the original upload filename
        # through to derive_id's Tier-4 filename heuristic. Without it,
        # the worker only sees OR-renamed UUID basenames and Tier-4
        # never fires -- caught during case-2133 sidecar inspection
        # where every host.* field came back null. The worker's
        # Tier-4-VR regex parses HOST_<fqdn>_<8hex>_<label>.zip into
        # host.fqdn / host.vr_client_id; the legacy regex handles
        # vr_kapefiles_<fqdn>_<label>.zip for pre-cutover collections.
        {
            "task_name": "openrelik-worker-host-fingerprint.tasks.derive_id",
            "queue_name": "openrelik-worker-host-fingerprint",
            "display_name": "Host Fingerprint: derive host.id",
            "description": "Derive a per-collection host.id (MachineGuid + filename heuristics) from extracted forensic input; emit sidecar JSON for cross-pipeline correlation.",
            "task_config": (
                [
                    {
                        "name": "source_archive_name",
                        "type": "string",
                        "required": False,
                        "value": source_archive_name,
                    }
                ]
                if source_archive_name
                else []
            ),
            "type": "task",
            "uuid": f"{host_fingerprint_uuid}",
            "tasks": [],
        },
        # RDP bitmap cache sibling (Phase C #1 of the high-value-
        # artefacts ticket). Picks up `bcache*.bmc` / `Cache????.bin`
        # files from the extracted set and reconstructs the cached
        # tiles via ANSSI bmc-tools. Output is per-tile + collage
        # BMP artefacts plus a manifest JSON, all surfaced in the
        # workflow folder for analyst download. No TS upload --
        # tiles are pixel data with no event timestamps.
        #
        # Worker filters on filename pattern internally; if the
        # input set has no cache files (most cases won't), the
        # task no-ops cleanly and emits a manifest noting zero
        # matches. Same fan-out tolerance as the other analysers.
        {
            "task_name": "openrelik-worker-rdp-cache.tasks.parse_cache",
            "queue_name": "openrelik-worker-rdp-cache",
            "display_name": "RDP Bitmap Cache: extract tiles",
            "description": "Reconstruct RDP session screen tiles from Windows mstsc bcache*.bmc / Cache????.bin via ANSSI bmc-tools. Output: per-tile + collage BMPs + manifest JSON. Not TS-bound.",
            "task_config": [],
            "type": "task",
            "uuid": f"{rdp_cache_uuid}",
            "tasks": [],
        },
        # OneDrive Explorer sibling (Phase C #2 of the high-value-
        # artefacts ticket). Picks up OneDrive client artefacts
        # (<UserCid>.dat, SyncEngine SQLite DBs, ODL logs) from the
        # extracted set and parses them via Beercow OneDriveExplorer
        # in --LIVE mode. Output is per-tenant report JSON + a
        # manifest, surfaced as workflow artefacts. No TS upload in
        # v1 -- OneDriveExplorer emits nested-folder JSON, not an
        # event stream. A v2 transformer task will fan reports out
        # into TS-shaped JSONL events for timeline ingestion.
        #
        # Worker filters internally on filename pattern + path hint
        # ("AppData\\Local\\Microsoft\\OneDrive\\..."), so cases
        # without OneDrive artefacts no-op cleanly and emit a
        # manifest reporting zero matches -- same fan-out tolerance
        # as the other analysers.
        {
            "task_name": "openrelik-worker-onedrive.tasks.parse_onedrive",
            "queue_name": "openrelik-worker-onedrive",
            "display_name": "OneDrive Explorer: parse OneDrive artefacts",
            "description": "Parse OneDrive client artefacts (<UserCid>.dat, SyncEngine SQLite, ODL logs) via Beercow OneDriveExplorer in --LIVE mode. Output: per-tenant report JSON + manifest. Not TS-bound (v1).",
            "task_config": [],
            "type": "task",
            "uuid": f"{onedrive_uuid}",
            "tasks": [],
        },
    ]

    if is_archive:
        extraction_uuid = str(uuid.uuid4()).replace("-", "")
        root_tasks = [
            {
                "task_name": "openrelik-worker-extraction.tasks.extract_archive",
                "queue_name": "openrelik-worker-extraction",
                "display_name": "Extract Archives",
                "description": "Extract files from archive for downstream analysers",
                "task_config": [],
                "type": "task",
                "uuid": f"{extraction_uuid}",
                "tasks": analyser_branches,
            }
        ]
    else:
        root_tasks = analyser_branches

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": root_tasks,
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


# Archive extensions handled by openrelik-worker-extraction's
# extract_archive_task (7zip + tar). Anything outside this set is
# treated as a plain file and bypasses extraction entirely — feeding a
# bare .log into the extraction worker raises
# RuntimeError("7zip or tar execution error.") because neither tool
# recognises it as an archive.
#
# Used by both the network endpoint (PR #73) and the triage endpoint --
# the archive-detection logic is generic, not pipeline-specific.
_ARCHIVE_SUFFIXES = (
    ".zip", ".7z", ".rar",
    ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
    ".gz", ".bz2", ".xz",
)


def _is_archive(filename):
    """True if `filename` looks like an archive that the extraction
    worker can unpack. Plain files (.log, .txt, .syslog, .json, .csv,
    .ndjson, no-extension, .evtx, etc.) return False so the calling
    workflow skips extract_archive and feeds the file straight into
    the analyser chain.
    """
    name = (filename or "").lower()
    return any(name.endswith(suf) for suf in _ARCHIVE_SUFFIXES)


# Host-artefact extensions that have no business on the network endpoint.
# Without an upfront reject, the network-normalizer pipeline would happily
# accept the upload, feed binary EVTX bytes into Logstash as text, and
# silently produce empty/junk timelines -- the worst kind of failure
# (data lost, no alarm). Better to fail loud at the route boundary.
#
# Conservative list: only formats that ARE actively supported elsewhere
# in our pipeline (i.e. on /api/triage/timesketch via chainsaw + hayabusa)
# and whose rejection has a clear "send it over there instead" remediation.
# Adding more host-artefact extensions later (.pf, .lnk, registry hives,
# etc.) is fine if they show up as analyst foot-guns; today only EVTX has
# been observed in this misroute.
_NETWORK_REJECT_SUFFIXES = (".evtx", ".evtx.gz")


def _network_reject_reason(filename):
    """If `filename` is an obvious host-artefact type that doesn't belong
    on the network endpoint, return a short error code suitable for the
    JSON response. Otherwise return None.
    """
    name = (filename or "").lower()
    for suf in _NETWORK_REJECT_SUFFIXES:
        if name.endswith(suf):
            return "evtx_not_supported_here"
    return None


def add_network_ts_tasks_to_workflow(
    folder_id,
    workflow_id,
    sketch_name,
    sketch_id,
    timeline_name,
    is_archive=False,
):
    """
    NETWORK_ ingestion workflow.

    Two layouts depending on input shape:

        is_archive=True  (.zip / .tar.gz / .7z / ...):
            extract_archive
              └── openrelik-worker-network-normalizer.normalize
                    └── timesketch upload (timeline: "<base> - Network")

        is_archive=False (.log / .txt / .syslog / .json / ...):
            openrelik-worker-network-normalizer.normalize
              └── timesketch upload (timeline: "<base> - Network")

    The plain-input branch skips extract_archive because the extraction
    worker invokes 7zip then tar and raises on non-archive input
    ("7zip or tar execution error."). Network logs commonly arrive
    bare (an analyst pulls a single .log off a firewall appliance) and
    only sometimes as a multi-file archive from a SIEM/syslog server
    export — both shapes need to flow through the same endpoint.

    Single-branch DAG by design: the normalizer worker hosts every
    supported log format internally (Logstash configs from SOF-ELK), so
    fan-out happens inside the worker rather than at the workflow layer.
    Per-format Logstash configs are added in the network-normalizer
    repo's NET-7 / NET-8 / NET-9 / NET-11 / NET-12 / NET-13 / NET-14
    PRs.
    """
    normalize_uuid = str(uuid.uuid4()).replace("-", "")

    normalize_task = {
        "task_name": "openrelik-worker-network-normalizer.tasks.normalize",
        "queue_name": "openrelik-worker-network-normalizer",
        "display_name": "Network: Normalize to ECS",
        "description": (
            "Run network log files through SOF-ELK Logstash configs; "
            "emit ECS-shaped Timesketch JSONL"
        ),
        "task_config": [],
        "type": "task",
        "uuid": f"{normalize_uuid}",
        "tasks": [
            _ts_leaf(sketch_name, sketch_id, f"{timeline_name} - Network")
        ],
    }

    if is_archive:
        extraction_uuid = str(uuid.uuid4()).replace("-", "")
        root_tasks = [
            {
                "task_name": "openrelik-worker-extraction.tasks.extract_archive",
                "queue_name": "openrelik-worker-extraction",
                "display_name": "Extract Archives",
                "description": "Extract files from archive for the network normalizer",
                "task_config": [],
                "type": "task",
                "uuid": f"{extraction_uuid}",
                "tasks": [normalize_task],
            }
        ]
    else:
        root_tasks = [normalize_task]

    workflow_spec = {
        "spec_json": json.dumps(
            {
                "workflow": {
                    "type": "chain",
                    "isRoot": True,
                    "tasks": root_tasks,
                }
            }
        )
    }

    return workflows_api.update_workflow(folder_id, workflow_id, workflow_spec)


def run_workflow(folder_id, workflow_id):
    """
    Trigger the workflow execution.
    """
    return workflows_api.run_workflow(folder_id, workflow_id)


def extract_fqdn_and_label(filename):
    # Check if the filename starts with "vr_kapefiles"
    if filename.startswith("vr_kapefiles"):
        # vr_kapefiles_<fqdn>_<label>.zip
        pattern = r"^vr_kapefiles_([^_]+)_(.+)\.zip$"
        match = re.match(pattern, filename)
        if match:
            fqdn = match.group(1)
            label = match.group(2)
            return fqdn, label
    
    return None, None


# --------------------------------------------------------------------------------
# Error handlers
# --------------------------------------------------------------------------------
@app.errorhandler(400)
def bad_request(error):
    """
    Return a 400 error for a Bad Request.
    """
    return "Bad Request!", 400


@app.errorhandler(401)
def unauthorized(error):
    """
    Return a 401 error for an Unauthorized request.
    """
    return "Unauthorized!", 401


@app.errorhandler(403)
def forbidden(error):
    """
    Return a 403 error for a Forbidden request.
    """
    return "Forbidden!", 403


@app.errorhandler(404)
def page_not_found(error):
    """
    Return a 404 error for a Page Not Found.
    """
    return "Page Not Found!", 404


@app.errorhandler(405)
def method_not_allowed(error):
    """
    Return a 405 error for Method Not Allowed.
    """
    return "Method Not Allowed!", 405


@app.errorhandler(413)
def request_entity_too_large(error):
    """
    Return a 413 error if the file or payload exceeds the maximum allowed size.
    """
    return "File is too large!", 413


@app.errorhandler(500)
def internal_server_error(error):
    """
    Return a 500 error for Internal Server Error.
    """
    return "Internal Server Error!", 500


@app.errorhandler(503)
def service_unavailable(error):
    """
    Return a 503 error for Service Unavailable.
    """
    return "Service Unavailable!", 503


# --------------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------------
@app.route("/api/hayabusa/timesketch", methods=["POST"])
def api_hayabusa_timesketch():
    """
    Endpoint to handle file uploads, create a workflow, and run it.
    """
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    filename = file.filename
    timeline_name, extension = os.path.splitext(filename)
    file_path = _safe_upload_path(file)
    fqdn, label = extract_fqdn_and_label(filename)

    # Always send to sketch 1 (created by ts-config on install)
    # All timelines go into one sketch per deployment
    sketch_id = 1
    timeline_name = fqdn if fqdn else timeline_name
    sketch_name = ""  # not used when sketch_id is set

    folder_id = create_folder(f"{filename} Hayabusa Timelines")
    file_id = upload_file(file_path, folder_id)
    workflow_id, workflow_folder_id = create_workflow(folder_id, [file_id])

    rename_folder(
        workflow_folder_id, f"{filename} Hayabusa to Timesketch Workflow Folder"
    )
    rename_workflow(
        folder_id, workflow_id, f"{filename} Hayabusa to Timesketch Workflow"
    )

    if zipfile.is_zipfile(file_path):
        add_hayabusa_extract_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name)
    else:
        add_hayabusa_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name)
    run = run_workflow(folder_id, workflow_id)

    return jsonify(
        {
            "message": "Hayabusa to Timesketch Workflow(s) started successfully",
        }
    )


@app.route("/api/hayabusa", methods=["POST"])
def api_hayabusa():
    """
    Endpoint to handle file uploads, create a workflow, and run it.
    """
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    filename = file.filename

    file_path = _safe_upload_path(file)

    folder_id = create_folder(f"{filename} Hayabusa Timelines")
    file_id = upload_file(file_path, folder_id)
    workflow_id, workflow_folder_id = create_workflow(folder_id, [file_id])

    rename_folder(workflow_folder_id, f"{filename} Hayabusa Workflow Folder")
    rename_workflow(folder_id, workflow_id, f"{filename} Hayabusa Workflow")

    if zipfile.is_zipfile(file_path):
        add_hayabusa_extract_tasks_to_workflow(folder_id, workflow_id, filename)
    else:
        add_hayabusa_tasks_to_workflow(folder_id, workflow_id)
    run = run_workflow(folder_id, workflow_id)

    return jsonify(
        {
            "message": "Hayabusa Workflow(s) started successfully",
        }
    )


@app.route("/api/triage/timesketch", methods=["POST"])
def api_triage_timesketch():
    """
    Catchall triage endpoint. Accepts a single archive (typically a
    Velociraptor KAPE collection zip), extracts it, fans out in parallel
    to every known analyser (Hayabusa, Chainsaw x3, Plaso), and uploads
    each analyser's output to Timesketch as a separately named timeline
    in the same sketch.

    Each worker's compatible-input filter decides whether to process
    the extracted files or no-op, so a single endpoint handles triage
    zips regardless of the specific artefacts inside. No per-worker
    hunts required in Velociraptor — one server-event artefact POSTs
    to this endpoint and the rest is automatic.

    Parameters:
      file     (required, multipart) — the archive to triage
      case_id  (optional) — resolved in this preference order:
                              1. form data (curl -F "case_id=...")
                              2. query string (?case_id=...)
                              3. CASE_ID env var on the pipeline container
                            If provided through any path, the triage workflow
                            is created inside a top-level case folder named
                            case_id (e.g. "Case-2079"). If that folder doesn't
                            exist, it's created and granted read access for
                            CASE_FOLDER_READ_GROUP.
                            If case_id is omitted everywhere, the legacy
                            behaviour is preserved: a fresh root folder per
                            zip.
                            For per-case container deployments
                            (<case-id>-or.dev.cypfer.io), the env-var path
                            is the canonical source -- VR callers don't need
                            to label clients to drive case-folder routing.
    """
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    filename = file.filename
    timeline_name, _extension = os.path.splitext(filename)
    fqdn, _label = extract_fqdn_and_label(filename)

    # Accept case_id from form data, query string, or the deployment's own
    # CASE_ID env var. The env var is the right answer for our per-case
    # container deployments: each OpenRelik instance lives at
    # <case-id>-or.dev.cypfer.io and serves exactly one case. install.sh
    # writes CASE_ID into docker-compose.yml at provisioning time.
    # POST-supplied case_id still wins so per-call testing overrides
    # remain possible.
    case_id = (
        request.form.get("case_id")
        or request.args.get("case_id")
        or os.getenv("CASE_ID", "")
    ).strip()

    sketch_id = 1
    timeline_name = fqdn if fqdn else timeline_name
    sketch_name = ""

    file_path = _safe_upload_path(file)

    if case_id:
        folder_id = find_or_create_case_folder(case_id)
        if folder_id is None:
            return jsonify({"error": f"Failed to find or create case folder {case_id!r}"}), 500
    else:
        folder_id = create_folder(f"{filename} Triage")

    file_id = upload_file(file_path, folder_id)
    workflow_id, workflow_folder_id = create_workflow(folder_id, [file_id])

    # Always name the workflow's subfolder and the workflow itself. Skipping
    # the folder rename in the case-folder flow left it showing as
    # "Untitled Workflow" in the OpenRelik UI.
    rename_folder(workflow_folder_id, f"{filename} Triage Workflow Folder")
    rename_workflow(folder_id, workflow_id, f"{filename} Triage Workflow")

    is_archive = _is_archive(filename)
    add_triage_ts_tasks_to_workflow(
        folder_id, workflow_id, sketch_name, sketch_id, timeline_name,
        is_archive=is_archive,
        # Pass the original upload filename through to derive_id so its
        # Tier-4 filename heuristic can extract FQDN + VR client_id from
        # the HOST_<fqdn>_<8hex>_<label>.zip pattern. Without this,
        # derive_id only sees OR-renamed UUID basenames and Tier-4
        # never fires.
        source_archive_name=filename,
    )
    run = run_workflow(folder_id, workflow_id)

    return jsonify(
        {
            "message": "Triage to Timesketch Workflow started successfully",
            "case_id": case_id or None,
            "case_folder_id": folder_id if case_id else None,
            "workflow_id": workflow_id,
            "extracted": is_archive,
            "run_details": run,
        }
    )


@app.route("/api/network/timesketch", methods=["POST"])
def api_network_timesketch():
    """
    Network-log ingestion endpoint. Sibling of /api/triage/timesketch
    but feeds the openrelik-worker-network-normalizer worker (Logstash +
    SOF-ELK) instead of the per-tool host analyser fan-out.

    Use this for vendor network logs:
      * Firewall (Palo Alto, Fortinet, Cisco ASA, ...)
      * IDS/Network monitoring (Zeek, Suricata)
      * Cloud audit (CloudTrail, Entra sign-in, Azure NSG, GWS, Okta)
      * EDR (CrowdStrike, SentinelOne, Defender)
      * pcap (passes through openrelik-worker-zeek first, future)

    Outputs land in the same case sketch as the HOST_ pipeline so
    analysts can pivot across both via shared ECS fields.

    Parameters mirror /api/triage/timesketch:
      file     (required, multipart) — log file or archive
      case_id  (optional) — same resolution order as the triage route:
                              1. form data (curl -F "case_id=...")
                              2. query string (?case_id=...)
                              3. CASE_ID env var on the pipeline container
                            If omitted everywhere, falls back to a fresh
                            root folder per upload.

    Status: NET-2 ships the route + workflow construction. End-to-end
    parsing requires at least one format-specific Logstash config in the
    network-normalizer worker (NET-7 onwards). Until then, calling this
    endpoint creates a workflow that completes extraction but stalls at
    network_normalize. This is by design for staged delivery.
    """
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    filename = file.filename

    # Reject obvious host-artefact uploads at the route boundary. Without
    # this, an EVTX file would flow into the network-normalizer worker,
    # Logstash would treat the binary bytes as text, and a near-empty
    # timeline would land in TS with no error. Worst-of-all-worlds:
    # data lost, no alarm. Fail loud here instead, with a remediation
    # pointing at the right endpoint.
    reject_reason = _network_reject_reason(filename)
    if reject_reason:
        return jsonify({
            "error": reject_reason,
            "message": (
                f"{filename!r} is a Windows event log -- not a network log. "
                "EVTX uploads belong on /api/triage/timesketch, which fans "
                "out to chainsaw + hayabusa for Sigma rule hunting and "
                "EVTX-aware parsing. The network endpoint feeds the SOF-ELK "
                "Logstash pipeline, which can't parse Windows binary event "
                "logs and would silently produce an empty timeline."
            ),
        }), 400

    timeline_name, _extension = os.path.splitext(filename)
    fqdn, _label = extract_fqdn_and_label(filename)

    case_id = (
        request.form.get("case_id")
        or request.args.get("case_id")
        or os.getenv("CASE_ID", "")
    ).strip()

    sketch_id = 1
    timeline_name = fqdn if fqdn else timeline_name
    sketch_name = ""

    file_path = _safe_upload_path(file)

    if case_id:
        folder_id = find_or_create_case_folder(case_id)
        if folder_id is None:
            return jsonify({"error": f"Failed to find or create case folder {case_id!r}"}), 500
    else:
        folder_id = create_folder(f"{filename} Network")

    file_id = upload_file(file_path, folder_id)
    workflow_id, workflow_folder_id = create_workflow(folder_id, [file_id])

    rename_folder(workflow_folder_id, f"{filename} Network Workflow Folder")
    rename_workflow(folder_id, workflow_id, f"{filename} Network Workflow")

    is_archive = _is_archive(filename)
    add_network_ts_tasks_to_workflow(
        folder_id, workflow_id, sketch_name, sketch_id, timeline_name,
        is_archive=is_archive,
    )
    run = run_workflow(folder_id, workflow_id)

    return jsonify(
        {
            "message": "Network to Timesketch Workflow started successfully",
            "case_id": case_id or None,
            "case_folder_id": folder_id if case_id else None,
            "workflow_id": workflow_id,
            "extracted": is_archive,
            "run_details": run,
        }
    )


@app.route("/api/plaso/timesketch", methods=["POST"])
def api_plaso_timesketch():
    """
    Endpoint to handle file uploads, create a workflow, and run it.
    """
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    filename = file.filename
    timeline_name, extension = os.path.splitext(filename)
    fqdn, label = extract_fqdn_and_label(filename)

    # Always send to sketch 1 (created by ts-config on install)
    # All timelines go into one sketch per deployment
    sketch_id = 1
    timeline_name = fqdn if fqdn else timeline_name
    sketch_name = ""  # not used when sketch_id is set

    file_path = _safe_upload_path(file)

    folder_id = create_folder(f"{filename} Plaso Timeline")
    file_id = upload_file(file_path, folder_id)
    workflow_id, workflow_folder_id = create_workflow(folder_id, [file_id])

    rename_folder(workflow_folder_id, f"{filename} Plaso to Timesketch Workflow Folder")
    rename_workflow(folder_id, workflow_id, f"{filename} Plaso to Timesketch Workflow")

    # Auto-detect archives — add extraction step before Plaso
    archive_extensions = {".zip", ".tar", ".tar.gz", ".tgz", ".gz", ".7z", ".rar"}
    if extension.lower() in archive_extensions:
        add_extract_plaso_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name)
    else:
        add_plaso_ts_tasks_to_workflow(folder_id, workflow_id, sketch_name, sketch_id, timeline_name)
    run = run_workflow(folder_id, workflow_id)

    return jsonify(
        {
            "message": "Plaso to Timesketch Workflow started successfully",
            "workflow_id": workflow_id,
            "run_details": run,
        }
    )


@app.route("/api/plaso", methods=["POST"])
def api_plaso():
    """
    Endpoint to handle file uploads, create a workflow, and run it.
    """
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    filename = file.filename

    file_path = _safe_upload_path(file)

    folder_id = create_folder(f"{filename} Plaso Timeline")
    file_id = upload_file(file_path, folder_id)
    workflow_id, workflow_folder_id = create_workflow(folder_id, [file_id])

    rename_folder(workflow_folder_id, f"{filename} Plaso Workflow Folder")
    rename_workflow(folder_id, workflow_id, f"{filename} Plaso Workflow")

    add_plaso_tasks_to_workflow(folder_id, workflow_id)
    run = run_workflow(folder_id, workflow_id)

    return jsonify(
        {
            "message": "Plaso Workflow started successfully",
            "workflow_id": workflow_id,
            "run_details": run,
        }
    )


# --------------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="localhost", debug=True)
