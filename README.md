# Shijian Agent distribution

Public installation scripts and checksum-pinned Linux amd64/systemd and Docker amd64 packages.
Generate the installation command in your Shijian server management page. It includes your private node configuration: treat it as a credential and never post it here.

The short command uses `curl -fsSL PINNED_INSTALLER_URL | bash -s -- --endpoint HTTPS_ORIGIN --server-id NODE_ID --token REPORT_TOKEN`, with optional `--interfaces eth0,eth1` and `--docker`. The installer embeds frozen package versions, SHA256 and Docker image ID. Installation requirements and reminders are printed on the target machine; configuration is written with mode 0600 and is never printed or sent to GitHub. The earlier JSON-via-stdin interface remains available with explicit package arguments.

The command downloads the installer over HTTPS at a fixed commit. Its SHA256 is checked at publication and recorded in the control panel distribution manifest; the short command does not perform a separate pre-execution script hash check. The installer verifies the downloaded package SHA256 against its embedded frozen release metadata. Packages live in `agent-VERSION` Releases. There is no automatic update. An existing installation is rejected; use the upgrade/rollback instructions supplied by your control panel.

After installation, the script prints status, logs, temporary stop/start, restart, automatic startup and uninstall commands for the selected platform, and saves the same instructions to `/etc/shijian-probe/OPERATIONS.txt`. Uninstall instructions preserve configuration and state and remind the user to revoke the control panel token.

Missing dependencies, network errors, integrity failures and service startup errors stop installation. Temporary files are cleaned; installed configuration and state remain available for diagnosis. Service startup alone does not confirm delivery to the control panel.

Package-specific license and third-party notices are included in each release package. This repository contains no per-node configuration, credentials, runtime state, or private application source.
