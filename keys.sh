#!/usr/bin/env bash
# ==============================================================================
# keys.sh — VERIFICATION ASSETS SETUP (LOCAL PERSISTENT KEYS)
# ==============================================================================
setup_signing_keys() {
  echo "--> Verifying persistent signing assets..."

  for CANDIDATE in my-signing-keys my_signing_keys my_private_keys; do
    if [ -d "vendor/lineage-priv/keys/${CANDIDATE}" ]; then
      mv vendor/lineage-priv/keys/"${CANDIDATE}"/* vendor/lineage-priv/keys/ 2>/dev/null || true
      rm -rf vendor/lineage-priv/keys/"${CANDIDATE}"
    fi
  done

  KEY_COUNT=$(ls -1 vendor/lineage-priv/keys/*.pk8 2>/dev/null | wc -l)

  if [ "$KEY_COUNT" -gt 0 ] && [ -f "vendor/lineage-priv/keys/releasekey.pk8" ]; then
    echo "====================================="
    echo "✅ Target output verification profile active ($KEY_COUNT assets found)!"
    echo "====================================="
    export PRODUCT_DEFAULT_DEV_CERTIFICATE=vendor/lineage-priv/keys/releasekey
    SM="Custom"
    tg_send "🔑 *Asset Status:* Loaded with ${KEY_COUNT} items (\`${SM}\`)"
  else
    echo "====================================="
    echo "⚠️ Standard verification profile active (No persistent keys found in vendor/lineage-priv/keys)."
    echo "====================================="
    SM="Default"
    tg_send "⚠️ *Asset Status:* Standard fallback active (\`${SM}\`)"
  fi
}
