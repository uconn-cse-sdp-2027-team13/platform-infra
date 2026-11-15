# Platform Infrastructure (`platform-infra`)

Infrastructure definitions, backing services, database schemas, and local demonstration automation for the Queue-Based Job Orchestrator.

## Overview

This repository provides:
- **Local Dev Stack** via Docker Compose (`compose/docker-compose.yml`):
  - **MySQL 8.0**: Database for job state, attempt history, pod events, and payment records (`3306`).
  - **Redis 7**: Stream broker for job scheduling and consumer groups (`6379`).
  - **RustFS**: High-performance S3-compatible object storage for CSV inputs and reports (`9000` API, `9001` Web Console).
- **Database Migrations** (`migrations/`):
  - Flyway-style SQL schema migrations (`V1__initial_schema.sql`), auto-mounted into `/docker-entrypoint-initdb.d`.
- **Demonstration Automation** (`scripts/demo-walking-skeleton.sh`):
  - Automated single-command walking skeleton test validating the full end-to-end pipeline across `job-orchestrator`, `batch-workload`, and Kubernetes.

---

## Prerequisites

1. **Docker Desktop**:
   - Ensure Docker Desktop is installed and running.
   - Enable Kubernetes in **Settings > Kubernetes > Enable Kubernetes**.
2. **Java 17+**:
   - JDK 17 or higher installed (`java -version`).
3. **Command-Line Tools**:
   - `docker`, `docker compose`, `kubectl`.

---

## Quick Start

### 1. Start Backing Infrastructure

```bash
# Start MySQL, Redis, and RustFS in the background
./scripts/local-dev-up.sh

# Stop backing services
./scripts/local-dev-down.sh
```

### 2. Run the End-to-End Walking Skeleton Demo

The walking skeleton script (`scripts/demo-walking-skeleton.sh`) executes the complete flow:
1. Validates Docker and Kubernetes cluster connectivity.
2. Ensures MySQL, Redis, and RustFS are ready with the initialized schema.
3. Builds the `batch-workload:local` Docker container and the orchestrator fat JARs.
4. Starts `status-tracker` and `consumer` background services.
5. Runs `producer` in one-shot mode to generate synthetic records and upload to RustFS.
6. Watches the Kubernetes Job and pod lifecycle transitions in MySQL until `SUCCEEDED`.
7. Asserts row counts in `account_payment` and `file_progress`.

```bash
# Run the walking skeleton demo (default 1000 records)
./scripts/demo-walking-skeleton.sh

# Run with custom parameters
./scripts/demo-walking-skeleton.sh --records 2500 --timeout 180

# Fast re-runs skipping rebuilds:
./scripts/demo-walking-skeleton.sh --skip-build
```

---

## Service Endpoints & Configuration

Copy `.env.example` to `.env` to customize settings:

| Service | Port | Internal Pod Endpoint | Default Credentials |
| :--- | :--- | :--- | :--- |
| **MySQL** | `3306` | `host.docker.internal:3306` | User: `app`, Pass: `local-app-password`, DB: `app` |
| **Redis** | `6379` | `host.docker.internal:6379` | Stream: `jobs:stream`, Group: `orchestrator-consumers` |
| **RustFS (S3)** | `9000` | `http://host.docker.internal:9000` | Key: `local-rustfs`, Secret: `local-rustfs-password`, Bucket: `job-files` |
| **RustFS Console**| `9001` | N/A | Web UI: `http://localhost:9001` |
