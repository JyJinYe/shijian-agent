# Shijian Agent distribution

Public installation scripts and checksum-pinned Linux amd64/systemd and Docker amd64 packages.
Generate the installation command in your Shijian server management page. It includes your private node configuration: treat it as a credential and never post it here.

The installer reads configuration JSON from stdin and accepts `--platform linux-amd64|docker-amd64 --version VERSION --sha256 PACKAGE_SHA256` (Docker also requires `--image-id sha256:...`). Run as root. Native installation requires systemd; Docker requires Linux >=5.12 and rootful Docker Engine, excluding Docker Desktop.

The UI pins the installer commit and SHA256 and the package version and SHA256. Packages live in `agent-VERSION` Releases. There is no automatic update. An existing installation is rejected; use the upgrade/rollback instructions supplied by your control panel.

Missing dependencies, network errors, integrity failures and service startup errors stop installation. Temporary files are cleaned; installed configuration and state remain available for diagnosis. Service startup alone does not confirm delivery to the control panel.

Package-specific license and third-party notices are included in each release package. This repository contains no per-node configuration, credentials, runtime state, or private application source.
