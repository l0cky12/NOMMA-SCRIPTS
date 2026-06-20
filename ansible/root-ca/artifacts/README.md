# Root CA Artifacts
#
# This directory holds files EXPORTED from the offline Root CA
# that the Issuing CA needs to establish its trust chain.
#
# Files expected here:
#   nomma-root-ca.cert.pem       - Root CA certificate (public)
#   nomma-issuing-ca.cert.pem    - Signed Intermediate CA certificate (public)
#   nomma-ca-chain.cert.pem      - Full chain: Intermediate + Root (public)
#
# SECURITY: NEVER place the Root CA private key (nomma-root-ca.key.pem)
# in this directory or anywhere in this repository.
# The Root CA private key must remain on the air-gapped offline system.