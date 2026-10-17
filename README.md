# Ecom Platform – run everything with one command

Scripts to start, stop and test the whole ecom platform on one machine (Windows with Git Bash, or Linux).
They expect the service repositories next to this folder (`../userservice`, `../productservice`, …,
`../kafkaservice`, `../elasticsearchservice`) and MongoDB in `../tools`.

| Script | What it does |
|---|---|
| `./start-all.sh` | Starts MongoDB, Kafka, Elasticsearch, then the 7 services (User first, gateway last) in the background, waits until every port is open. Builds any service whose jar is missing (`--build` rebuilds all) |
| `./status.sh` | Shows which components are up |
| `./e2e-test.sh` | Full purchase through the API Gateway with ~35 checks; exits non-zero on any failure |
| `./stop-all.sh` | Stops everything |

Logs: `logs/<component>.log`. Process ids: `run/`.

## Getting the code

Clone every repository side by side, using these folder names (the scripts expect them):

```bash
mkdir Capstone && cd Capstone
G=https://github.com/pavithrakudethurscaler
git clone $G/platform.git             platform
git clone $G/UserService.git          userservice
git clone $G/ProductService.git       productservice
git clone $G/OrderService.git         orderservice
git clone $G/PaymentService.git       paymentservice
git clone $G/CartService-.git         cartservice
git clone $G/NotificationService.git  notificationservice
git clone $G/ApiGatewayService.git    apigateway
git clone $G/KafkaService.git         kafkaservice
git clone $G/elasticsearchservice.git elasticsearchservice
```

MongoDB is not in a repository: unzip the MongoDB 8.0 Windows zip into `tools/` (so that
`tools/mongodb-win32-x86_64-windows-*/bin/mongod.exe` exists) and add `tools/start-mongodb.sh`, or point the Cart
Service at another MongoDB with `MONGODB_URI`. Java 21 is required for the services.

## First run

1. One-time installs: `../kafkaservice/scripts/setup-kafka.sh`, `../elasticsearchservice/scripts/setup-elasticsearch.sh`
   (optional: without Elasticsearch, search falls back to the database), MongoDB in `../tools`.
2. `./start-all.sh` creates `.env` with **random** `INTERNAL_API_TOKEN` and `RAZORPAY_WEBHOOK_SECRET` and
   `ADMIN_EMAILS=admin@ecom.local`. Every service reads these, so they always match. `.env` is git-ignored.
3. Use the API at `http://localhost:8000/api/v1/...`. Sign up as `admin@ecom.local` to get the admin role.

## What the end-to-end test covers

Accounts and roles → admin-only catalog changes → search (typo-tolerant via Elasticsearch, or database fallback)
→ cart totals → checkout → payment link for the order total (client amount ignored) → bad and good webhook
signatures → order PAID → admin ships (customer cannot) → tracking history → notifications delivered through
Kafka (welcome, confirmation, receipt, shipped) → `/internal/**` blocked at the gateway → login required.

The services keep data in memory (H2), so a restart starts clean; the test creates a new customer each run.
