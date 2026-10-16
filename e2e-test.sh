#!/usr/bin/env bash
# End-to-end test of a full purchase through the API Gateway, against the running platform (./start-all.sh).
# Exits non-zero if any check fails. Uses a new customer each run, so it can be re-run.
#   ./e2e-test.sh
set -uo pipefail
source "$(dirname "$0")/common.sh"
API="${API_URL:-http://localhost:8000}/api/v1"
PASS=0; FAIL=0
RUN_ID=$(date +%s)

# ---- helpers (no jq needed) ----------------------------------------------------------------------------------
STATUS=""; BODY=""; HEADERS=""
req() { # METHOD PATH [JSON] [extra curl args...]
  local method=$1 path=$2 data=${3:-}; shift 3 2>/dev/null || shift $#
  local out; out=$(mktemp)
  local args=(-s --noproxy '*' -o "$out" -D "$out.h" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json')
  [ -n "$data" ] && args+=(-d "$data")
  STATUS=$(curl "${args[@]}" "$@" "$API$path"); BODY=$(cat "$out"); HEADERS=$(cat "$out.h"); rm -f "$out" "$out.h"
}
field() { echo "$BODY" | grep -o "\"$1\":\"\{0,1\}[^\",}]*" | head -1 | sed "s/\"$1\":\"\{0,1\}//"; }
check() { # description condition-result(0/1)
  if [ "$2" = 0 ]; then PASS=$((PASS+1)); printf "  PASS  %s\n" "$1"; else FAIL=$((FAIL+1)); printf "  FAIL  %s  (status %s, body %.200s)\n" "$1" "$STATUS" "$BODY"; fi
}
is() { [ "$1" = "$2" ]; echo $?; }
has() { echo "$1" | grep -q -- "$2"; echo $?; }
poll() { # seconds METHOD PATH pattern [curl args]  -> retries until BODY matches pattern
  local secs=$1 m=$2 p=$3 pat=$4; shift 4
  for _ in $(seq "$secs"); do req "$m" "$p" "" "$@"; echo "$BODY" | grep -q -- "$pat" && return 0; sleep 1; done; return 1
}

echo "E2E test against $API (run $RUN_ID)"
port_open 8000 || { echo "API Gateway is not running on :8000. Start the platform with ./start-all.sh"; exit 2; }

echo "== Accounts and roles"
ADMIN_EMAIL=${ADMIN_EMAILS%%,*}; CUST_EMAIL="customer-$RUN_ID@e2e.local"
req POST /users/signup "{\"name\":\"Admin\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"Admin#123\"}"
check "admin signup (201, or 409 if it already exists)" "$( [ "$STATUS" = 201 ] || [ "$STATUS" = 409 ]; echo $?)"
req POST /users/login "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"Admin#123\"}"; ADMIN_TOKEN=$(field token)
check "admin login" "$(is "$STATUS" 200)"
check "admin has ADMIN role" "$(has "$BODY" '"ADMIN"')"
req POST /users/signup "{\"name\":\"E2E Customer\",\"email\":\"$CUST_EMAIL\",\"password\":\"Cust#123\"}"
check "customer signup" "$(is "$STATUS" 201)"
req POST /users/login "{\"email\":\"$CUST_EMAIL\",\"password\":\"Cust#123\"}"; CUST_TOKEN=$(field token)
check "customer login" "$(is "$STATUS" 200)"
AH=(-H "Authorization: Bearer $ADMIN_TOKEN"); CH=(-H "Authorization: Bearer $CUST_TOKEN")

echo "== Catalog (admin only) and search"
req POST /products "{\"name\":\"E2E Phone $RUN_ID\",\"price\":250,\"category\":{\"name\":\"E2E\"}}" "${CH[@]}"
check "customer cannot create products (403)" "$(is "$STATUS" 403)"
req POST /products "{\"name\":\"E2E Phone $RUN_ID\",\"price\":250,\"description\":\"smartphone\",\"category\":{\"name\":\"E2E\"}}" "${AH[@]}"
check "admin creates product A (250.00)" "$(is "$STATUS" 201)"; PROD_A=$(field id)
req POST /products "{\"name\":\"E2E Cable $RUN_ID\",\"price\":0.5,\"category\":{\"name\":\"E2E\"}}" "${AH[@]}"
check "admin creates product B (0.50)" "$(is "$STATUS" 201)"; PROD_B=$(field id)
poll 10 GET "/products/search?keyword=phnoe%20$RUN_ID" "E2E Phone $RUN_ID"
ENGINE=$(echo "$HEADERS" | grep -i '^x-search-engine' | cut -d' ' -f2 | tr -d '\r')
if [ "$ENGINE" = elasticsearch ]; then
  check "search with a typo ('phnoe') finds product A via Elasticsearch" "$(has "$BODY" "E2E Phone $RUN_ID")"
else
  req GET "/products/search?keyword=E2E%20Phone" ""
  check "search finds product A (database fallback; Elasticsearch not running)" "$(has "$BODY" "E2E Phone $RUN_ID")"
fi

echo "== Cart and checkout"
req POST /cart/items "{\"productId\":$PROD_A,\"quantity\":2}" "${CH[@]}"; check "add 2 x A to cart" "$(is "$STATUS" 200)"
req POST /cart/items "{\"productId\":$PROD_B,\"quantity\":3}" "${CH[@]}"; check "add 3 x B to cart" "$(is "$STATUS" 200)"
check "cart total is 50150 paise (2 x 25000 + 3 x 50)" "$(is "$(field totalAmount)" 50150)"
req POST /cart/checkout '{"deliveryAddress":{"recipientName":"E2E","line1":"1 Test Street","city":"Bengaluru","postalCode":"560001","country":"IN"}}' "${CH[@]}"
check "checkout creates an order" "$(is "$STATUS" 201)"; ORDER_ID=$(field id)
check "order total 50150 and status CREATED" "$( [ "$(field totalAmount)" = 50150 ] && [ "$(field status)" = CREATED ]; echo $?)"
req GET /cart "" "${CH[@]}"; check "cart is empty after checkout" "$(is "$(field itemCount)" 0)"

echo "== Payment"
req POST /payments "{\"orderId\":\"$ORDER_ID\",\"amount\":1}" "${CH[@]}"
check "payment link created" "$(is "$STATUS" 201)"
check "amount charged is the order total (client amount ignored)" "$(is "$(field amount)" 50150)"
LINK_ID=$(echo "$BODY" | grep -o 'plink_[A-Za-z0-9_]*' | head -1)
WEBHOOK="{\"event\":\"payment_link.paid\",\"payload\":{\"payment_link\":{\"entity\":{\"id\":\"$LINK_ID\"}},\"payment\":{\"entity\":{\"id\":\"pay_e2e_$RUN_ID\"}}}}"
SIG=$(printf '%s' "$WEBHOOK" | openssl dgst -sha256 -hmac "$RAZORPAY_WEBHOOK_SECRET" -hex | sed 's/.* //')
req POST /payments/webhook "$WEBHOOK" -H "X-Razorpay-Signature: deadbeef"
check "webhook with a bad signature is rejected (401)" "$(is "$STATUS" 401)"
req POST /payments/webhook "$WEBHOOK" -H "X-Razorpay-Signature: $SIG"
check "signed Razorpay webhook accepted" "$(is "$STATUS" 200)"
poll 10 GET "/orders/$ORDER_ID" '"status":"PAID"' "${CH[@]}"; check "order becomes PAID" "$?"

echo "== Fulfilment (admin)"
req PUT "/admin/orders/$ORDER_ID/status" '{"status":"SHIPPED","note":"E2E AWB 1"}' "${CH[@]}"
check "customer cannot ship orders (403)" "$(is "$STATUS" 403)"
req PUT "/admin/orders/$ORDER_ID/status" '{"status":"SHIPPED","note":"E2E AWB 1"}' "${AH[@]}"
check "admin ships the order" "$( [ "$STATUS" = 200 ] && [ "$(field status)" = SHIPPED ]; echo $?)"
req GET "/orders/$ORDER_ID" "" "${CH[@]}"
check "tracking history CREATED -> PAID -> SHIPPED" "$(has "$BODY" '"status":"CREATED".*"status":"PAID".*"status":"SHIPPED"')"

echo "== Notifications (via Kafka)"
poll 30 GET /notifications "ORDER_SHIPPED" "${CH[@]}"
for t in USER_REGISTERED ORDER_CONFIRMED PAYMENT_RECEIVED ORDER_SHIPPED; do check "customer received $t" "$(has "$BODY" "\"type\":\"$t\"")"; done

echo "== Gateway protections"
STATUS=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H "X-Internal-Token: $INTERNAL_API_TOKEN" -X POST \
  "${API%/api/v1}/internal/api/v1/orders/$ORDER_ID/payment-completed"); BODY=""
check "/internal/** is not reachable through the gateway, even with the secret (404)" "$(is "$STATUS" 404)"
req GET /orders "" ; check "orders require login (401)" "$(is "$STATUS" 401)"

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
