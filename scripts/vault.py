#!/usr/bin/env python3
"""
CYPFER Vault — Push and pull config.env to/from Azure Key Vault.

Usage:
    python vault.py --pull --config azure-dev.cfg
    python vault.py --push --config azure-dev.cfg --file config.env

Dependencies:
    pip install azure-keyvault-secrets azure-identity
"""

import argparse
import configparser
import os
import sys

try:
    from azure.identity import ClientSecretCredential
    from azure.keyvault.secrets import SecretClient
    from azure.core.exceptions import (
        ClientAuthenticationError,
        ResourceNotFoundError,
        HttpResponseError,
    )
except ImportError:
    print("ERROR: Azure SDK not installed.")
    print("       pip install azure-keyvault-secrets azure-identity")
    sys.exit(1)


def load_config(config_path):
    """Load Azure credentials from a .cfg file."""
    if not os.path.exists(config_path):
        print(f"ERROR: Config file not found: {config_path}")
        sys.exit(1)

    cfg = configparser.ConfigParser()
    cfg.read(config_path)

    try:
        vault_cfg = cfg["vault"]
        return {
            "tenant_id": vault_cfg["AZURE_TENANT_ID"],
            "client_id": vault_cfg["AZURE_CLIENT_ID"],
            "client_secret": vault_cfg["AZURE_CLIENT_SECRET"],
            "vault_url": vault_cfg["VAULT_URL"],
            "secret_name": vault_cfg["SECRET_NAME"],
        }
    except KeyError as e:
        print(f"ERROR: Missing key in config file: {e}")
        print("       Required: AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, VAULT_URL, SECRET_NAME")
        sys.exit(1)


def get_client(cfg):
    """Create an authenticated SecretClient."""
    try:
        credential = ClientSecretCredential(
            tenant_id=cfg["tenant_id"],
            client_id=cfg["client_id"],
            client_secret=cfg["client_secret"],
        )
        return SecretClient(vault_url=cfg["vault_url"], credential=credential)
    except Exception as e:
        print(f"ERROR: Failed to create Azure client: {e}")
        sys.exit(1)


def pull(cfg):
    """Pull config.env from Azure Key Vault."""
    client = get_client(cfg)
    try:
        secret = client.get_secret(cfg["secret_name"])
    except ClientAuthenticationError:
        print("ERROR: Authentication failed — check AZURE_TENANT_ID, AZURE_CLIENT_ID, and AZURE_CLIENT_SECRET")
        sys.exit(1)
    except ResourceNotFoundError:
        print(f"ERROR: Secret not found: {cfg['secret_name']}")
        sys.exit(1)
    except HttpResponseError as e:
        print(f"ERROR: Azure API error: {e.message}")
        sys.exit(1)

    output_path = os.path.join(os.getcwd(), "config.env")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(secret.value)

    print(f"OK: config.env written to {output_path}")
    print(f"    Source: {cfg['vault_url']} / {cfg['secret_name']}")


def push(cfg, file_path):
    """Push a file to Azure Key Vault as a secret."""
    if not os.path.exists(file_path):
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    client = get_client(cfg)
    try:
        client.set_secret(cfg["secret_name"], content)
    except ClientAuthenticationError:
        print("ERROR: Authentication failed — check AZURE_TENANT_ID, AZURE_CLIENT_ID, and AZURE_CLIENT_SECRET")
        sys.exit(1)
    except HttpResponseError as e:
        print(f"ERROR: Azure API error: {e.message}")
        sys.exit(1)

    print(f"OK: Pushed to {cfg['vault_url']} / {cfg['secret_name']}")
    print(f"    Source file: {file_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Push and pull config.env to/from Azure Key Vault"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--push", action="store_true", help="Push file to vault")
    group.add_argument("--pull", action="store_true", help="Pull config.env from vault")
    parser.add_argument("--config", required=True, help="Path to azure-*.cfg file")
    parser.add_argument("--file", help="File to push (required with --push)")
    parser.add_argument("--secret", help="Override SECRET_NAME from cfg (push to a specific secret)")

    args = parser.parse_args()

    if args.push and not args.file:
        print("ERROR: --file is required when using --push")
        sys.exit(1)

    cfg = load_config(args.config)

    # Allow --secret to override the secret name from cfg
    if args.secret:
        cfg["secret_name"] = args.secret

    if args.pull:
        pull(cfg)
    elif args.push:
        push(cfg, args.file)


if __name__ == "__main__":
    main()
