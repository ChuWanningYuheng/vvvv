#!/bin/bash
# prints IAM token for service account key in sa_key.json
set -e
D=$(dirname "$0"); K=$D/sa_key.json
KID=$(python3 -c "import json;print(json.load(open('$K'))['id'])")
SA=$(python3 -c "import json;print(json.load(open('$K'))['service_account_id'])")
python3 -c "import json;print(json.load(open('$K'))['private_key'].split('\n',1)[1])" > $D/.pk.pem
b64(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW=$(date +%s)
H=$(printf '{"typ":"JWT","alg":"PS256","kid":"%s"}' "$KID" | b64)
P=$(printf '{"aud":"https://iam.api.cloud.yandex.net/iam/v1/tokens","iss":"%s","iat":%d,"exp":%d}' "$SA" $NOW $((NOW+3600)) | b64)
SIG=$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -sign $D/.pk.pem -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 | b64)
rm -f $D/.pk.pem
curl -sS -X POST https://iam.api.cloud.yandex.net/iam/v1/tokens -d "{\"jwt\":\"$H.$P.$SIG\"}" | python3 -c "import json,sys;print(json.load(sys.stdin)['iamToken'])"
