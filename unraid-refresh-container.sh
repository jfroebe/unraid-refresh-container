#!/bin/bash
# Version 2.0.0 — persistent Unraid container update and image rollback.
# Install: /boot/config/scripts/unraid-refresh-container.sh
# Invoke with bash because the Unraid flash drive may be mounted noexec.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'HELP'
Usage:
  bash unraid-refresh-container.sh CONTAINER [TIMEOUT_SECONDS]
  bash unraid-refresh-container.sh --rollback CONTAINER [TIMEOUT_SECONDS] [BACKUP_ID]
  bash unraid-refresh-container.sh --list CONTAINER

Update pulls the image in the saved Unraid template, saves the previous image
and template before replacement, recreates the container and checks readiness.
Rollback restores the latest saved image, or BACKUP_ID from --list. It does not
pull an old mutable tag: the saved image is loaded and verified by image ID.
A stopped container is started. Default readiness timeout: 180 seconds.

Examples:
  bash /boot/config/scripts/unraid-refresh-container.sh example-container
  bash /boot/config/scripts/unraid-refresh-container.sh --rollback example-container
  bash /boot/config/scripts/unraid-refresh-container.sh --list example-container
  bash /boot/config/scripts/unraid-refresh-container.sh --rollback example-container 300 20260101T120000Z-1234

Persistent script: /boot/config/scripts/unraid-refresh-container.sh
Persistent backups: /mnt/user/appdata/container-refresh/CONTAINER/
Override the backup root with UNRAID_REFRESH_BACKUP_DIR (persistent storage).
Image archives can be large. Backups are retained until you remove them.
Rollback uses the CURRENT saved template settings, temporarily selecting the
old image. The template's normal update repository is restored afterwards.
Backups include the earlier template for reference, but rollback does not
restore application data, databases, container writable layers or volumes.
Only updates performed with this version create rollback backups. Containers
without Docker HEALTHCHECK are checked for running state only. Run as root.
HELP
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mode=update
case ${1:-} in
  --help|-h) usage; exit 0 ;;
  --rollback) mode=rollback; shift ;;
  --list) mode=list; shift ;;
esac
if (( $# < 1 || $# > 3 )); then usage >&2; exit 2; fi
container=$1
timeout_seconds=${2:-180}
backup_id=${3:-}
[[ $container =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail 'Invalid container name.'
if [[ $mode != rollback && $# -gt 2 || $mode == list && $# -gt 1 ]]; then usage >&2; exit 2; fi
[[ $timeout_seconds =~ ^[0-9]{1,5}$ ]] || fail 'Timeout must be an integer from 1 to 86400.'
timeout_seconds=$((10#$timeout_seconds))
(( timeout_seconds >= 1 && timeout_seconds <= 86400 )) || fail 'Timeout must be from 1 to 86400 seconds.'
[[ -z $backup_id || $backup_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || fail 'Invalid backup ID; use --list.'
(( EUID == 0 )) || fail 'Run as root on the Unraid host.'
[[ -x /usr/bin/php ]] || fail 'Unraid PHP was not found.'
backup_root=${UNRAID_REFRESH_BACKUP_DIR:-/mnt/user/appdata/container-refresh}
[[ $backup_root == /* && $backup_root != /boot && $backup_root != /boot/* ]] || fail 'Use an absolute backup directory outside /boot.'
if [[ -z ${UNRAID_REFRESH_BACKUP_DIR:-} && $mode != list ]]; then
  mountpoint -q /mnt/user || fail 'Unraid user shares are not mounted; refusing to put image archives on the RAM filesystem.'
fi
state_dir="$backup_root/$container"
pending="$state_dir/pending-template.json"

if [[ $mode == list ]]; then
  printf '\n\nSaved images for %s\n' "$container"
  found=0
  for meta in "$state_dir"/*/metadata.json; do
    [[ -f $meta ]] || continue
    /usr/bin/php -r '$m=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR); printf("%s  %s\n", basename(dirname($argv[1])), $m["image_id"]);' "$meta"
    found=1
  done
  (( found )) || printf 'No saved images. Run an update with this version first.\n'
  exit 0
fi

updater=/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container
rebuilder=/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/rebuild_container
[[ -f $updater && -f $rebuilder ]] || fail 'Required Unraid update/rebuild helpers were not found.'
for program in docker flock gzip mountpoint findmnt; do
  command -v "$program" >/dev/null || fail "Required command is missing: $program"
done
export DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
[[ -S /var/run/docker.sock ]] || fail 'Local Docker socket was not found.'
exec 9>"/var/lock/unraid-refresh-container-${container}.lock"
flock -n 9 || fail "Another operation on $container is already running."
mkdir -p "$state_dir"
chmod 700 "$state_dir" 2>/dev/null || true
filesystem=$(findmnt -n -o FSTYPE -T "$state_dir") || fail 'Cannot identify backup storage.'
case "$filesystem" in tmpfs|ramfs|rootfs|overlay) fail 'Backup directory must be on persistent storage, not RAM or a container filesystem.' ;; esac

# The pending record is written before temporarily changing a template. Restore
# it on exit, or on the next invocation following an interrupted rollback.
restore_pending() {
  [[ -f $pending ]] || return 0
  /usr/bin/php -r '
  $p=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);
  $path=$p["path"]; $xml=$p["xml"];
  if (dirname($path)!=="/boot/config/plugins/dockerMan/templates-user") exit(1);
  $x=simplexml_load_string($xml,"SimpleXMLElement",LIBXML_NONET);
  if (!$x || (string)$x->Name!==$argv[2]) exit(1);
  $tmp=tempnam(dirname($path),".refresh-");
  if ($tmp===false || file_put_contents($tmp,$xml)===false || !rename($tmp,$path)) exit(1);
  if (!unlink($argv[1])) exit(1);
  ' "$pending" "$container"
}
cleanup() {
  local status=$?
  trap - EXIT
  if ! restore_pending; then
    printf 'ERROR: Could not restore the saved update repository. Pending record: %s\n' "$pending" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
restore_pending || fail 'An interrupted rollback left a template restoration that could not be completed.'

printf '\n\nUnraid container %s: %s\n' "$mode" "$container"
# Resolve exactly one saved template. Do not print environment variables or XML.
info=$(/usr/bin/php -r '
if (!function_exists("simplexml_load_file")) exit(1);
$matches=[];
foreach (glob("/boot/config/plugins/dockerMan/templates-user/*.xml") ?: [] as $path) {
 $x=@simplexml_load_file($path,"SimpleXMLElement",LIBXML_NONET);
 if ($x!==false && (string)$x->Name===$argv[1]) $matches[]=[$path,trim((string)$x->Repository),(string)$x->TailscaleEnabled];
}
if (count($matches)!==1 || $matches[0][1]==="" || strpbrk($matches[0][0],"\r\n")!==false) exit(1);
echo implode("\n",$matches[0]);
' "$container") || fail 'Expected exactly one saved Unraid template with a Repository.'
mapfile -t fields <<< "$info"
template=${fields[0]}
image=${fields[1]}
tailscale=${fields[2]:-false}
[[ -n $image && $image != -* && $image != *[[:space:]]* ]] || fail 'Invalid image reference in saved template.'

ready() {
  local deadline=$((SECONDS + timeout_seconds)) state health samples=0
  printf '\nWaiting up to %s seconds for readiness...\n' "$timeout_seconds"
  while (( SECONDS < deadline )); do
    state=$(docker inspect --type container --format '{{.State.Status}}' "$container") || return 1
    case "$state" in
      exited|dead|removing) return 1 ;;
      running)
        health=$(docker inspect --type container --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container") || return 1
        [[ $health == healthy ]] && return 0
        if [[ $health == none ]]; then
          samples=$((samples + 1))
          if (( samples >= 2 )); then
            printf 'No Docker HEALTHCHECK is defined; application readiness was not verified.\n'
            return 0
          fi
        else samples=0; fi
        ;;
      *) samples=0 ;;
    esac
    sleep 2
  done
  return 1
}

if [[ $mode == update ]]; then
  old_container=$(docker inspect --type container --format '{{.Id}}' "$container") || fail "Container not found: $container"
  previous=$(docker inspect --type container --format '{{.Image}}' "$container") || fail 'Cannot inspect current image.'
  printf 'Pulling saved template image: %s\n' "$image"
  docker pull "$image" || fail 'Pull failed; existing container was not stopped.'
  expected=$(docker image inspect --format '{{.Id}}' "$image") || fail 'Cannot inspect pulled image.'
  if [[ $expected != "$previous" ]]; then
    backup_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    snapshot="$state_dir/$backup_id"
    mkdir "$snapshot"
    tag="unraid-refresh-backup/${container,,}:$backup_id"
    docker image tag "$previous" "$tag" || fail 'Cannot retain the old image; container was not stopped.'
    cp -- "$template" "$snapshot/template.xml"
    printf '\nSaving previous image to %s/image.tar.gz ...\n' "$snapshot"
    if ! docker image save "$tag" | gzip -1 > "$snapshot/image.tar.gz.partial"; then
      rm -f -- "$snapshot/image.tar.gz.partial"
      fail 'Image backup failed; existing container was not stopped.'
    fi
    mv -- "$snapshot/image.tar.gz.partial" "$snapshot/image.tar.gz"
    /usr/bin/php -r '
    $m=["format"=>1,"container"=>$argv[2],"image_id"=>$argv[3],"backup_tag"=>$argv[4],"repository"=>$argv[5],"created_at"=>gmdate("c")];
    if (file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n")===false) exit(1);
    ' "$snapshot/metadata.json" "$container" "$previous" "$tag" "$image"
    printf '%s\n' "$backup_id" > "$state_dir/latest.partial"
    mv -- "$state_dir/latest.partial" "$state_dir/latest"
    printf 'Saved rollback point: %s\n' "$backup_id"
  else
    printf 'Image is unchanged; retaining the existing earlier rollback point.\n'
  fi
  printf '\nRecreating container using Unraid saved settings...\n'
  /usr/bin/php -d short_open_tag=On -q "$updater" "$container" || fail 'Unraid updater failed; use --rollback if necessary.'
  new_container=$(docker inspect --type container --format '{{.Id}}' "$container") || fail 'Recreation failed; rollback backup is retained.'
  [[ $new_container != "$old_container" ]] || fail 'Unraid did not recreate the container.'
else
  [[ $tailscale != true ]] || fail 'Native rebuild does not reproduce Unraid-managed Tailscale entrypoints. Use the saved image/template with Unraid-managed Tailscale recovery instead.'
  if [[ -z $backup_id ]]; then
    [[ -f $state_dir/latest ]] || fail 'No rollback point exists. Only updates with this version save earlier images.'
    backup_id=$(cat "$state_dir/latest")
  fi
  [[ $backup_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || fail 'Invalid saved backup ID.'
  snapshot="$state_dir/$backup_id"
  [[ -s $snapshot/metadata.json && -s $snapshot/image.tar.gz ]] || fail 'Selected rollback backup is incomplete.'
  meta=$(/usr/bin/php -r '
  $m=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);
  if (($m["format"]??0)!==1 || ($m["container"]??"")!==$argv[2] || !preg_match("/^sha256:[a-f0-9]{64}$/",$m["image_id"]??"")) exit(1);
  echo $m["image_id"];
  ' "$snapshot/metadata.json" "$container") || fail 'Invalid rollback metadata.'
  expected=$meta
  # Load before stopping anything. Docker validates the archive contents; then
  # verify its exact image ID before using it, even after Docker image cleanup.
  printf 'Loading saved image: %s\n' "$backup_id"
  docker image load -i "$snapshot/image.tar.gz" >/dev/null || fail 'Saved image could not be loaded; current container was not stopped.'
  actual=$(docker image inspect --format '{{.Id}}' "$expected") || fail 'Archive does not contain the expected old image.'
  [[ $actual == "$expected" ]] || fail 'Saved image identity mismatch.'
  tag="unraid-refresh-backup/${container,,}:$backup_id"
  docker image tag "$expected" "$tag"
  # Keep the regular update repository unchanged on disk after rollback. The
  # small pending record also allows recovery after a power interruption.
  /usr/bin/php -r '
  $path=$argv[1];$pending=$argv[2];$tag=$argv[3];
  $raw=file_get_contents($path);$x=simplexml_load_string($raw,"SimpleXMLElement",LIBXML_NONET);
  if (!$x || (string)$x->Name!==$argv[4]) exit(1);
  $record=json_encode(["path"=>$path,"xml"=>$raw],JSON_THROW_ON_ERROR);
  if (file_put_contents($pending.".partial",$record)===false || !rename($pending.".partial",$pending)) exit(1);
  $x->Repository=$tag;
  $tmp=tempnam(dirname($path),".refresh-");
  if ($tmp===false || $x->asXML($tmp)===false || !rename($tmp,$path)) exit(1);
  ' "$template" "$pending" "$tag" "$container" || fail 'Could not prepare rollback template.'
  printf '\nRebuilding with the saved local image (no image pull)...\n'
  /usr/bin/php -d short_open_tag=On -q "$rebuilder" "$container" || fail 'Unraid rebuild failed; backup is retained.'
  # The native rebuild helper omits the extra-network step used by update.
  /usr/bin/php -d short_open_tag=On -r '
  $docroot="/usr/local/emhttp";
  require_once "$docroot/plugins/dynamix.docker.manager/include/DockerClient.php";
  $xml=file_get_contents($argv[1]);$network=getXmlVal($xml,"Network");$extra=getXmlVal($xml,"ExtraNetworks");
  if (trim($extra)!=="") {
    if (!function_exists("connectExtraNetworks") || !connectExtraNetworks($argv[2],$extra,$network)) exit(1);
  }
  ' "$template" "$container" || fail 'Could not reconnect saved additional networks.'
  restore_pending || fail 'Rollback image selected but the normal template repository could not be restored.'
  image=$tag
fi
actual=$(docker inspect --type container --format '{{.Image}}' "$container") || fail 'Cannot inspect recreated container.'
[[ $actual == "$expected" ]] || fail 'Container is not using the expected image; backup is retained.'
docker start "$container" >/dev/null || fail 'Recreated container could not be started; backup is retained.'
ready || fail "Readiness failed. Inspect: docker logs --tail 50 $container ; rollback: bash $0 --rollback $container"
printf '\nSUCCESS: %s completed for %s.\nImage: %s\nImage ID: %s\n' "$mode" "$container" "$image" "$expected"
