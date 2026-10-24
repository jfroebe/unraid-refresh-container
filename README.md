# Unraid Container Refresh

Refresh an existing Docker container from the Unraid terminal without opening the web interface. The script pulls the image specified in the container's saved Unraid template, preserves the previous image when it changes, recreates the container using Unraid's own helpers, starts it, and checks its status.

Version 2.0.0 supports rollback to an archived image by its exact Docker image ID. The script and rollback archives live on persistent storage so they survive host restarts.

## Features

- Accepts a container name rather than a hard-coded application.
- Uses the saved Unraid template for container configuration.
- Pulls the replacement image before stopping the existing container.
- Archives the previous image and template before replacing a changed image.
- Restores an archived image without relying on an old mutable registry tag.
- Keeps the normal template repository setting after rollback.
- Recovers a pending template restoration on the next update or rollback invocation after an interruption.
- Prevents concurrent refresh operations on the same container.
- Uses the local Docker socket.
- Waits for Docker health status when a HEALTHCHECK exists; otherwise checks that the container remains running across two samples.
- Retains rollback points until the administrator removes them.

## Requirements

Run as root directly on an Unraid host with Docker enabled, mounted persistent storage, and exactly one saved user template matching the container name. This is an Unraid-specific utility, not a general Docker or Compose updater.

The script requires Bash, Docker CLI, PHP with SimpleXML/JSON support, flock, gzip, mountpoint, findmnt, and standard Unix utilities. It uses these Unraid Docker Manager helpers:

- `/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container`
- `/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/rebuild_container`

Compatibility depends on the installed Unraid release and its internal helpers. Validate on a noncritical container before routine use.

## Persistent installation

Install the script at:

```text
/boot/config/scripts/unraid-refresh-container.sh
```

The Unraid flash configuration directory survives reboots. Invoke the script with `bash` because the flash drive may be mounted with `noexec`.

Download from the terminal:

```bash
mkdir -p /boot/config/scripts
curl --fail --location --output /boot/config/scripts/unraid-refresh-container.sh \
  https://raw.githubusercontent.com/jfroebe/unraid-refresh-container/main/unraid-refresh-container.sh
bash -n /boot/config/scripts/unraid-refresh-container.sh
bash /boot/config/scripts/unraid-refresh-container.sh --help
```

Review the downloaded script before running it as root. To update the utility itself, download it again using the same command.

## Usage

```text
bash /boot/config/scripts/unraid-refresh-container.sh CONTAINER [TIMEOUT_SECONDS]
bash /boot/config/scripts/unraid-refresh-container.sh --rollback CONTAINER [TIMEOUT_SECONDS] [BACKUP_ID]
bash /boot/config/scripts/unraid-refresh-container.sh --list CONTAINER
```

Use the exact name shown in Unraid's Docker tab. The default readiness timeout is 180 seconds; accepted values are 1–86400. This timeout applies to the readiness check, not to image downloads, archiving, or recreation.

### Refresh a container

```bash
bash /boot/config/scripts/unraid-refresh-container.sh example-container
```

Allow up to five minutes for readiness:

```bash
bash /boot/config/scripts/unraid-refresh-container.sh example-container 300
```

A refresh recreates the container even when the pulled image is unchanged. An unchanged image does not overwrite the earlier rollback point. A stopped container is started.

### List saved images

```bash
bash /boot/config/scripts/unraid-refresh-container.sh --list example-container
```

The output shows backup IDs and exact image IDs.

### Roll back to the latest saved image

```bash
bash /boot/config/scripts/unraid-refresh-container.sh --rollback example-container
```

### Roll back to a specific saved image

Copy a backup ID from `--list`:

```bash
bash /boot/config/scripts/unraid-refresh-container.sh --rollback example-container 300 20260101T120000Z-1234
```

The ID above is illustrative; substitute an existing ID.

### Choose another persistent backup directory

```bash
UNRAID_REFRESH_BACKUP_DIR=/mnt/user/backups/container-refresh \
  bash /boot/config/scripts/unraid-refresh-container.sh example-container
```

Use the same override for later list and rollback commands. The directory must be an absolute path on mounted persistent storage outside `/boot`. Ensure custom storage is mounted before running the script.

## Backup location and contents

Default backup root:

```text
/mnt/user/appdata/container-refresh/
```

Each changed-image update creates:

```text
CONTAINER/BACKUP_ID/image.tar.gz
CONTAINER/BACKUP_ID/template.xml
CONTAINER/BACKUP_ID/metadata.json
```

A per-container `latest` file identifies the latest rollback point. A temporary `pending-template.json` recovery record is used when rollback temporarily changes the template repository.

Image archives can be large. Keep them off the Unraid flash drive, allow sufficient free space, and manage retention manually. There is no automatic pruning. Backup image tags also remain in Docker. Removing an archive removes that rollback option; keep the latest pointer consistent when manually deleting backups.

Templates and recovery records can contain application credentials, environment variables, paths, and other sensitive configuration. Keep the backup directory private and never publish its contents. The repository contains only generic examples; it does not include runtime backups or host configuration.

## Rollback behavior and limits

Rollback loads the saved image archive before rebuilding and verifies the exact image ID. It uses the **current saved template settings**, temporarily selects the archived image, and restores the template's normal repository afterwards. The earlier template is retained for reference, not automatically restored.

Image rollback does **not** restore application data, databases, volumes, bind mounts, or the container's writable layer. Back up application data separately before updating; a newer application may make data changes that an older version cannot read.

Only changed-image updates performed by this version create rollback points. Rollback is manual; a failed readiness check does not automatically revert the container. The next regular refresh uses the normal configured repository again.

Rollback refuses containers with Unraid-managed Tailscale enabled because the native rebuild helper does not reproduce those entrypoints. Updates continue to use the native Unraid update helper.

## Status checks and failures

When an image defines a Docker HEALTHCHECK, success requires a healthy status. Without one, success means the container was running across two samples; it does not prove the application or its web interface is ready.

If pulling or saving the previous image fails, the script exits before requesting container replacement. If recreation or readiness fails, inspect the container and use a retained rollback point where appropriate:

```bash
docker logs --tail 50 example-container
bash /boot/config/scripts/unraid-refresh-container.sh --list example-container
bash /boot/config/scripts/unraid-refresh-container.sh --rollback example-container
```

Ctrl-C and termination signals trigger exit cleanup that attempts to restore a temporarily changed template. An interrupted child operation may take time to return. After a power loss or forced termination, the next update or rollback invocation attempts pending template recovery. Do not delete a pending recovery record without inspecting and resolving it first.

Exit status is 0 for success, 2 for invalid argument counts, 130 for an interrupt, 143 for termination, and generally 1 for operational errors. Other invalid arguments can also return 1.

## Scope

This utility refreshes existing containers managed by saved Unraid templates. It does not install new applications, schedule updates, back up application data, or manage remote Docker hosts.
