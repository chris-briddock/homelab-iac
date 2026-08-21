#!/usr/bin/env bash
# Idempotently mint the lab internal PKI as LOCAL FILES (no tls provider, no
# private key material in tfstate):
#
#   pki/root-ca.key / pki/root-ca.crt           -- ECDSA P-256 root CA, ~10y
#   pki/intermediate-ca.key / .crt              -- ECDSA P-256 intermediate, ~5y
#
# OpenTofu only ever READS these files (services.tf local.root_ca_cert_pem,
# infra.tf module.ca extra_files). Certs (*.crt) are committed; keys (*.key)
# are git-ignored and must never leave the operator's machine. On a fresh
# clone, run this script once before `tofu apply`.
#
# This machine has no native openssl; run it through the alpine/openssl
# container image with the pki/ dir mounted (docker or podman, whichever is
# present). Refuses to overwrite existing files -- delete them yourself if
# you really mean to re-mint (that revokes trust on every VM).
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."

ROOT_KEY=pki/root-ca.key
ROOT_CRT=pki/root-ca.crt
INT_KEY=pki/intermediate-ca.key
INT_CRT=pki/intermediate-ca.crt
ROOT_DAYS=3650 # ~10 years
INT_DAYS=1825  # ~5 years
ROOT_SUBJ="/O=Lab Internal/CN=Lab Internal Root CA"
INT_SUBJ="/O=Lab Internal/CN=Lab Internal Intermediate CA"

if [[ -f $ROOT_KEY && -f $ROOT_CRT && -f $INT_KEY && -f $INT_CRT ]]; then
  echo "gen-pki: all pki/*.key / *.crt already exist -- nothing to do." >&2
  exit 0
fi
if [[ -f $ROOT_KEY || -f $ROOT_CRT || -f $INT_KEY || -f $INT_CRT ]]; then
  echo "gen-pki: PARTIAL pki/ state found (some but not all files exist)." >&2
  echo "gen-pki: refusing to guess -- inspect pki/ and either restore the" >&2
  echo "gen-pki: missing files or remove all four to re-mint from scratch." >&2
  exit 1
fi

# Pick a container runtime for openssl (host has none installed). alpine/openssl
# runs the openssl CLI as its entrypoint, so extra args are passed straight
# through. The pki dir is mounted rw at /pki; the container runs as the host
# uid so generated files stay user-owned (openssl only needs to write here).
RUNTIME=""
for c in docker podman; do
  if command -v "$c" >/dev/null 2>&1; then
    RUNTIME=$c
    break
  fi
done
if [[ -z $RUNTIME ]]; then
  echo "gen-pki: need docker or podman (no openssl on this host)." >&2
  exit 1
fi

mkdir -p pki/.work
WORKDIR="$(cd pki/.work && pwd)"
trap 'rm -rf "$WORKDIR"' EXIT

docker_run() {
  "$RUNTIME" run --rm \
    --user "$(id -u):$(id -g)" \
    --network none \
    -v "$(cd pki && pwd):/pki" \
    -v "$WORKDIR:/work" \
    alpine/openssl "$@"
}

echo "gen-pki: minting NEW root CA (ECDSA P-256, ${ROOT_DAYS}d) ..." >&2
docker_run ecparam -genkey -name prime256v1 -noout -out "/pki/$(basename "$ROOT_KEY")"
docker_run req -new -x509 -sha256 \
  -key "/pki/$(basename "$ROOT_KEY")" \
  -out "/pki/$(basename "$ROOT_CRT")" \
  -days "$ROOT_DAYS" \
  -subj "$ROOT_SUBJ" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always"

echo "gen-pki: minting intermediate CA (ECDSA P-256, ${INT_DAYS}d) ..." >&2
docker_run ecparam -genkey -name prime256v1 -noout -out "/pki/$(basename "$INT_KEY")"
docker_run req -new -sha256 \
  -key "/pki/$(basename "$INT_KEY")" \
  -out /work/intermediate.csr \
  -subj "$INT_SUBJ"
cat >"$WORKDIR/int-ext.cnf" <<'EOF'
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
docker_run x509 -req -sha256 \
  -in /work/intermediate.csr \
  -CA "/pki/$(basename "$ROOT_CRT")" \
  -CAkey "/pki/$(basename "$ROOT_KEY")" \
  -CAcreateserial \
  -out "/pki/$(basename "$INT_CRT")" \
  -days "$INT_DAYS" \
  -extfile /work/int-ext.cnf

chmod 600 "$ROOT_KEY" "$INT_KEY"
chmod 644 "$ROOT_CRT" "$INT_CRT"

echo "gen-pki: chain verification:" >&2
docker_run verify -CAfile "/pki/$(basename "$ROOT_CRT")" "/pki/$(basename "$INT_CRT")"

echo "gen-pki: DONE. REMINDER: pki/*.key are git-ignored private keys --" >&2
echo "gen-pki: never commit them; back them up somewhere safe instead." >&2
