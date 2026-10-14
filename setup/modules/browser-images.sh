# browser-images.sh - image bake: the browser images a worker's edge would
# otherwise pull on its first pass, pulled into the disk image instead.
#
# BAKE_IMAGES (secrets.env, space separated) names every image by the reference
# the edge uses. A reference with a registry host is pulled through
# REGISTRY_SERVER with REGISTRY_USER/REGISTRY_PASSWORD; when its host differs
# (a mirror of the same registry with keys of its own), the pull is tagged back
# to the reference, so the edge finds it under its own name. A reference without
# a host (Docker Hub) is pulled anonymously. Empty BAKE_IMAGES bakes no image.
# shellcheck shell=bash

_bake_image_refs() { # -> BAKE_IMAGES, one reference per line
  local refs=() ref
  read -ra refs <<< "${BAKE_IMAGES:-}"
  for ref in "${refs[@]}"; do printf '%s\n' "$ref"; done
}

_image_registry() { # reference -> its registry host, empty for Docker Hub
  local first="${1%%/*}"
  if [[ "$1" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    printf '%s\n' "$first"
  fi
}

_bake_images_present() {
  local ref
  while IFS= read -r ref; do
    docker image inspect "$ref" >/dev/null 2>&1 || return 1
  done < <(_bake_image_refs)
}

STEP_DESC["browser-images-prefetch"]="image bake: pull BAKE_IMAGES under the references the edge uses"
STEP_PHASE["browser-images-prefetch"]=bake
browser-images-prefetch::check() {
  _bake_images_present
}
browser-images-prefetch::apply() {
  local refs=() ref host pull_ref hosted=0
  mapfile -t refs < <(_bake_image_refs)
  for ref in "${refs[@]}"; do
    [[ -n "$(_image_registry "$ref")" ]] && hosted=1
  done

  if [[ "$hosted" == "1" ]]; then
    require_secrets REGISTRY_SERVER REGISTRY_USER REGISTRY_PASSWORD
    [[ "$REGISTRY_SERVER" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
      || die "REGISTRY_SERVER '$REGISTRY_SERVER' is not a registry host[:port]"
    for ref in "${refs[@]}"; do
      host="$(_image_registry "$ref")"
      if [[ -n "$host" && "$host" != "$REGISTRY_SERVER" && "$ref" == *@* ]]; then
        die "BAKE_IMAGES: '$ref' is pinned by digest on $host; a digest cannot be renamed from $REGISTRY_SERVER (pass a tag, or bake against $host)"
      fi
    done
    # Credentials live on tmpfs for the pulls only: never in /root/.docker,
    # never in the disk image.
    install -d -m 0700 "$RUN_DIR"
    DOCKER_CONFIG="$(mktemp -d "$RUN_DIR/docker.XXXXXX")"
    export DOCKER_CONFIG
    trap 'docker logout "$REGISTRY_SERVER" >/dev/null 2>&1 || true; rm -rf "$DOCKER_CONFIG"' EXIT
    docker login "$REGISTRY_SERVER" --username "$REGISTRY_USER" --password-stdin <<< "$REGISTRY_PASSWORD" >/dev/null
  fi

  for ref in "${refs[@]}"; do
    host="$(_image_registry "$ref")"
    pull_ref="$ref"
    [[ -n "$host" && "$host" != "$REGISTRY_SERVER" ]] && pull_ref="$REGISTRY_SERVER/${ref#*/}"
    retry 3 10 docker pull -q "$pull_ref" >/dev/null || die "pull of $pull_ref failed"
    if [[ "$pull_ref" != "$ref" ]]; then
      docker tag "$pull_ref" "$ref"
      docker rmi "$pull_ref" >/dev/null
    fi
    log "prefetched $ref"
  done
}
browser-images-prefetch::verify() {
  _bake_images_present
}
