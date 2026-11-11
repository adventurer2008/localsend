#!/usr/bin/env bash
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
openssl req -newkey rsa:2048 -x509 -nodes -days 1 -subj '/CN=LocalSend smoke test' \
  -keyout "$work/key.pem" -out "$work/client.pem" 2>/dev/null
fingerprint="$(openssl x509 -in "$work/client.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
data="$(printf '{"alias":"CI smoke test","version":"2.2","fingerprint":"%s","port":53318,"protocol":"https"}' "$fingerprint")"
for attempt in {1..35}; do
  # This isolated test server uses a self-signed certificate, as LocalSend LAN normally does.
  if curl -kfsS --max-time 3 --cert "$work/client.pem" --key "$work/key.pem" \
    -H 'Content-Type: application/json' --data "$data" \
    'https://127.0.0.1:53317/api/localsend/v2/register' > "$work/response.json" 2>/dev/null; then
    python3 -c 'import json,re,sys; d=json.load(sys.stdin); assert d["alias"]; assert re.fullmatch("[0-9a-fA-F]{64}", d["fingerprint"]); print("LocalSend native HTTPS registration succeeded")' < "$work/response.json"
    if [[ $# -eq 1 ]]; then
      python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])' < "$work/response.json" > "$1"
    fi
    exit 0
  fi
  sleep 2
done
echo 'Native LocalSend HTTPS registration did not respond on port 53317' >&2
exit 1

