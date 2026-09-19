#!/usr/bin/env bash
# The two issuer documents AWS reads, compared with what the API server serves (app guide step 5).
#   bash infra/scripts/oidc.sh publish <bucket> <issuer-url>   upload whichever is missing
#   bash infra/scripts/oidc.sh check   <bucket> <issuer-url>   only compare
# kubectl goes through `make tunnel`. The bucket's policy lets anyone read exactly these two keys.
set -euo pipefail

mode=$1
bucket=$2
issuer=$3
keys=(".well-known/openid-configuration" "openid/v1/jwks")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# What the API server serves, with the keys sorted so that two copies compare equal.
kubectl get --raw /.well-known/openid-configuration | jq -S . > "$work/0.json"
kubectl get --raw /openid/v1/jwks | jq -S . > "$work/1.json"

served=$(jq -r .issuer "$work/0.json")
if [ "$served" != "$issuer" ]; then
  echo "The API server's issuer is $served, expected $issuer. The cluster needs app guide step 4." >&2
  exit 1
fi

status=0
for i in 0 1; do
  key=${keys[$i]}
  if published=$(curl -fsS "$issuer/$key" 2>/dev/null); then
    if diff <(jq -S . <<<"$published") "$work/$i.json" >/dev/null; then
      echo "same       $key"
    else
      # The key changed. Publishing would move every role to the new key: find out why first.
      echo "DIFFERENT  $key" >&2
      status=1
    fi
  elif [ "$mode" = publish ]; then
    # --if-none-match: refuse to overwrite, even if the object appeared since the check above.
    aws s3api put-object \
      --bucket "$bucket" \
      --key "$key" \
      --body "$work/$i.json" \
      --content-type application/json \
      --if-none-match '*' >/dev/null
    echo "published  $key"
  else
    echo "MISSING    $key" >&2
    status=1
  fi
done
exit "$status"
