# ---------------------------------------------------------------------------
# Internal PKI: FILE-BASED root + intermediate CA (no tls provider, no
# private key material in tfstate).
#
# The chain lives entirely in pki/, minted ONCE by scripts/gen-pki.sh:
#
#   pki/root-ca.key / pki/root-ca.crt           -- ECDSA P-256 root, ~10y
#   pki/intermediate-ca.key / .crt              -- ECDSA P-256 intermediate, ~5y
#
#   - Private keys (pki/*.key) are git-ignored; they exist ONLY on the
#     operator's machine (back them up somewhere safe, outside this repo).
#   - Certificates (pki/*.crt) are committed; they are public by definition.
#   - Tofu only READS these files: the root cert becomes every VM's trust
#     anchor (local.root_ca_cert_pem in services.tf), and the intermediate
#     cert+key are provisioned onto ca-vm for step-ca (infra.tf module.ca).
#   - scripts/gen-pki.sh is idempotent and never overwrites existing files.
#     On a fresh clone, run it once before `tofu apply`; without pki/*.key
#     the ca module plan/apply will fail -- expected on a machine without
#     the keys.
#
# History: an earlier revision generated this chain with the `tls` provider
# (keys in tfstate). The prior tfstate was lost, the root key with it; the
# checked-in pki/root-ca-cert.pem is that DEAD root (key lost forever) --
# kept for reference only, do NOT reintroduce it as a trust anchor. The new
# pki/root-ca.crt minted by scripts/gen-pki.sh replaces it.
# ---------------------------------------------------------------------------
