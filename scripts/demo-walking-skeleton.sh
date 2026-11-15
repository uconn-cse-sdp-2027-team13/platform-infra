#!/usr/bin/env bash
# ==============================================================================
# demo-walking-skeleton.sh
#
# End-to-End Walking Skeleton Demonstration Script (INFRA-3)
#
# Orchestrates and validates the entire Phase 1 queue-based batch processing flow:
#   1. Pre-flight verification (Docker, Kubernetes, Java 17+, Maven).
#   2. Backing infrastructure readiness (MySQL 8, Redis 7, RustFS S3).
#   3. Database schema migration verification (V1__initial_schema.sql).
#   4. Workload container image build (batch-workload:local).
#   5. Orchestrator service fat JAR builds (consumer, producer, status-tracker).
#   6. Background service activation (status-tracker & consumer).
#   7. One-shot synthetic CSV generation and S3 upload via producer.
#   8. Real-time Kubernetes job execution, pod lifecycle tracking, and DB assertions.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors & Formatting
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  {
    echo -e "\n${BOLD}${BLUE}====================================================================${NC}"
    echo -e "${BOLD}${BLUE} $*${NC}"
    echo -e "${BOLD}${BLUE}====================================================================${NC}"
}

# ------------------------------------------------------------------------------
# Configuration & Arguments
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "$REPO_ROOT/.." && pwd)"
ORCH_DIR="$WORKSPACE_ROOT/job-orchestrator"
WORKLOAD_DIR="$WORKSPACE_ROOT/batch-workload"
COMPOSE_FILE="$REPO_ROOT/compose/docker-compose.yml"
LOG_DIR="$REPO_ROOT/target/demo-logs"

# Defaults
RECORD_COUNT=1000
TIMEOUT_SECONDS=120
SKIP_BUILD=false
KEEP_SERVICES=false
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"

# MySQL / Redis / S3 settings
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-app}"
DB_PASSWORD="${DB_PASSWORD:-local-app-password}"
DB_NAME="${DB_NAME:-app}"
JDBC_URL="jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

S3_ENDPOINT="${S3_ENDPOINT:-http://127.0.0.1:9000}"
S3_BUCKET="${S3_BUCKET:-job-files}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-local-rustfs}"
S3_SECRET_KEY="${S3_SECRET_KEY:-local-rustfs-password}"
S3_REGION="${S3_REGION:-us-east-1}"

WORKLOAD_S3_ENDPOINT="${WORKLOAD_S3_ENDPOINT:-http://host.docker.internal:9000}"
WORKLOAD_JDBC_URL="${WORKLOAD_JDBC_URL:-jdbc:mysql://host.docker.internal:3306/app?rewriteBatchedStatements=true}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

End-to-End Walking Skeleton Demonstration Script (INFRA-3)

Options:
  --records <num>       Number of synthetic records to generate (default: 1000)
  --timeout <seconds>   Maximum seconds to wait for job completion (default: 120)
  --skip-build          Skip Maven builds and Docker image build if already built
  --keep-services       Keep consumer and status-tracker running after demo finishes
  -h, --help            Show this help message and exit
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --records)
            RECORD_COUNT="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --keep-services)
            KEEP_SERVICES=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown argument: $1"
            usage
            ;;
    esac
done

# Background PIDs for cleanup
TRACKER_PID=""
CONSUMER_PID=""

cleanup() {
    local exit_code=$?
    if [ "$KEEP_SERVICES" = false ]; then
        if [ -n "$CONSUMER_PID" ] && kill -0 "$CONSUMER_PID" 2>/dev/null; then
            info "Stopping background consumer (PID $CONSUMER_PID)..."
            kill "$CONSUMER_PID" 2>/dev/null || true
        fi
        if [ -n "$TRACKER_PID" ] && kill -0 "$TRACKER_PID" 2>/dev/null; then
            info "Stopping background status tracker (PID $TRACKER_PID)..."
            kill "$TRACKER_PID" 2>/dev/null || true
        fi
    else
        warn "Background services left running as requested (--keep-services)."
        [ -n "$CONSUMER_PID" ] && info "Consumer PID: $CONSUMER_PID (log: $LOG_DIR/consumer.log)"
        [ -n "$TRACKER_PID" ] && info "Status Tracker PID: $TRACKER_PID (log: $LOG_DIR/status-tracker.log)"
    fi

    if [ $exit_code -ne 0 ]; then
        error "Demo failed with exit code $exit_code. Inspect logs in $LOG_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# 1. Pre-Flight Verification
# ------------------------------------------------------------------------------
header "Step 1: Pre-Flight Verification"

mkdir -p "$LOG_DIR"
mkdir -p "${DATA_HOST_PATH:-$HOME/job-data}"

for cmd in docker kubectl java; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

info "Checking Docker daemon status..."
if ! docker info >/dev/null 2>&1; then
    error "Docker daemon is not running. Please start Docker Desktop and ensure Kubernetes is enabled."
    exit 1
fi
success "Docker daemon is running."

info "Checking Kubernetes cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Kubernetes cluster is unreachable. Please ensure Kubernetes is enabled in Docker Desktop (or local cluster is active)."
    exit 1
fi
success "Kubernetes cluster is reachable: $(kubectl config current-context)"

info "Checking Java environment..."
JAVA_VER=$(java -version 2>&1 | head -n 1)
info "Using Java: $JAVA_VER"

# ------------------------------------------------------------------------------
# 2. Backing Infrastructure Readiness
# ------------------------------------------------------------------------------
header "Step 2: Starting Backing Services (MySQL, Redis, RustFS)"

info "Starting docker compose stack in $REPO_ROOT..."
docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" up --detach

info "Waiting for MySQL at ${DB_HOST}:${DB_PORT} to accept connections..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql mysqladmin ping -h 127.0.0.1 -u "$DB_USER" -p"$DB_PASSWORD" --silent >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
        error "Timed out waiting for MySQL to start."
        exit 1
    fi
    sleep 1
done
success "MySQL is healthy and ready."

info "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT}..."
ATTEMPTS=0
until docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q "PONG"; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
        error "Timed out waiting for Redis to start."
        exit 1
    fi
    sleep 1
done
success "Redis is healthy and ready."

info "Verifying database schema in MySQL '${DB_NAME}'..."
TABLE_COUNT=$(docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='job';" 2>/dev/null || echo "0")

if [ "$TABLE_COUNT" -eq 0 ]; then
    info "Applying V1__initial_schema.sql migrations..."
    docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
        mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$REPO_ROOT/migrations/V1__initial_schema.sql"
    success "Schema migration applied successfully."
else
    success "Database schema is already initialized."
fi

# ------------------------------------------------------------------------------
# 3. Build Artifacts
# ------------------------------------------------------------------------------
header "Step 3: Building Applications & Container Images"

if [ "$SKIP_BUILD" = true ]; then
    info "Skipping build steps (--skip-build specified)."
else
    info "Building batch workload (batch-workload:local)..."
    (
        cd "$WORKLOAD_DIR"
        ./mvnw -B clean package -DskipTests
        docker build -t batch-workload:local .
    ) > "$LOG_DIR/build-workload.log" 2>&1
    success "Workload container built: batch-workload:local"

    info "Building job orchestrator fat JARs (consumer, producer, status-tracker)..."
    (
        cd "$ORCH_DIR"
        ./mvnw -B clean package -DskipTests
    ) > "$LOG_DIR/build-orchestrator.log" 2>&1
    success "Job orchestrator modules packaged."
fi

# Verify JAR files exist
for jar in "$ORCH_DIR/consumer/target/consumer.jar" \
           "$ORCH_DIR/producer/target/producer.jar" \
           "$ORCH_DIR/status-tracker/target/status-tracker.jar"; do
    if [ ! -f "$jar" ]; then
        error "Required JAR not found: $jar. Run without --skip-build."
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# 4. Activate Background Services (Status Tracker & Consumer)
# ------------------------------------------------------------------------------
header "Step 4: Activating Consumer & Status Tracker"

info "Starting status tracker in background..."
JDBC_URL="$JDBC_URL" \
DB_USER="$DB_USER" \
DB_PASSWORD="$DB_PASSWORD" \
K8S_NAMESPACE="$K8S_NAMESPACE" \
java -jar "$ORCH_DIR/status-tracker/target/status-tracker.jar" > "$LOG_DIR/status-tracker.log" 2>&1 &
TRACKER_PID=$!
info "Status tracker started (PID $TRACKER_PID)."

info "Starting consumer service in background..."
JDBC_URL="$JDBC_URL" \
DB_USER="$DB_USER" \
DB_PASSWORD="$DB_PASSWORD" \
REDIS_HOST="$REDIS_HOST" \
WORKLOAD_JDBC_URL="$WORKLOAD_JDBC_URL" \
WORKLOAD_S3_ENDPOINT="$WORKLOAD_S3_ENDPOINT" \
S3_ENDPOINT="$S3_ENDPOINT" \
S3_BUCKET="$S3_BUCKET" \
S3_ACCESS_KEY="$S3_ACCESS_KEY" \
S3_SECRET_KEY="$S3_SECRET_KEY" \
S3_REGION="$S3_REGION" \
K8S_NAMESPACE="$K8S_NAMESPACE" \
java -jar "$ORCH_DIR/consumer/target/consumer.jar" > "$LOG_DIR/consumer.log" 2>&1 &
CONSUMER_PID=$!
info "Consumer service started (PID $CONSUMER_PID)."

sleep 2
if ! kill -0 "$TRACKER_PID" 2>/dev/null; then
    error "Status tracker died unexpectedly. Check $LOG_DIR/status-tracker.log"
    exit 1
fi
if ! kill -0 "$CONSUMER_PID" 2>/dev/null; then
    error "Consumer service died unexpectedly. Check $LOG_DIR/consumer.log"
    exit 1
fi
success "Both orchestrator services running."

# ------------------------------------------------------------------------------
# 5. One-Shot Synthetic Job Generation
# ------------------------------------------------------------------------------
header "Step 5: Generating Synthetic Job via Producer"

info "Executing producer in one-shot mode (RECORD_COUNT=${RECORD_COUNT})..."
JDBC_URL="$JDBC_URL" \
DB_USER="$DB_USER" \
DB_PASSWORD="$DB_PASSWORD" \
REDIS_HOST="$REDIS_HOST" \
S3_ENDPOINT="$S3_ENDPOINT" \
S3_BUCKET="$S3_BUCKET" \
S3_ACCESS_KEY="$S3_ACCESS_KEY" \
S3_SECRET_KEY="$S3_SECRET_KEY" \
S3_REGION="$S3_REGION" \
ONE_SHOT="true" \
RECORD_COUNT="$RECORD_COUNT" \
java -jar "$ORCH_DIR/producer/target/producer.jar" > "$LOG_DIR/producer.log" 2>&1

JOB_ID=$(grep -oE "jobId=[a-f0-9\-]+" "$LOG_DIR/producer.log" | head -n 1 | cut -d'=' -f2 || true)
if [ -z "$JOB_ID" ]; then
    error "Failed to retrieve generated jobId from producer log. Check $LOG_DIR/producer.log"
    cat "$LOG_DIR/producer.log"
    exit 1
fi
success "Job successfully published! Job ID: ${BOLD}${JOB_ID}${NC}"

# ------------------------------------------------------------------------------
# 6. Monitor Lifecycle & Await Completion
# ------------------------------------------------------------------------------
header "Step 6: Monitoring Job Execution on Kubernetes"

info "Awaiting completion of job ${JOB_ID} (timeout: ${TIMEOUT_SECONDS}s)..."
START_TIME=$(date +%s)
CURRENT_STATE=""

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
        error "Timed out after ${TIMEOUT_SECONDS}s waiting for job to complete."
        break
    fi

    STATE=$(docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
        mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -Nse "SELECT state FROM job WHERE job_id = '${JOB_ID}';" 2>/dev/null || echo "")

    if [ -n "$STATE" ] && [ "$STATE" != "$CURRENT_STATE" ]; then
        CURRENT_STATE="$STATE"
        info "Job state transition: ${BOLD}${CURRENT_STATE}${NC} (elapsed: ${ELAPSED}s)"
    fi

    if [ "$CURRENT_STATE" = "SUCCEEDED" ]; then
        success "Job reached SUCCEEDED state!"
        break
    elif [ "$CURRENT_STATE" = "DEAD_LETTERED" ] || [ "$CURRENT_STATE" = "CANCELLED" ]; then
        error "Job ended in failed state: $CURRENT_STATE"
        LAST_ERR=$(docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
            mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -Nse "SELECT last_error FROM job WHERE job_id = '${JOB_ID}';" 2>/dev/null || echo "")
        error "Last error: $LAST_ERR"
        exit 1
    fi

    sleep 2
done

if [ "$CURRENT_STATE" != "SUCCEEDED" ]; then
    error "Walking skeleton demonstration did not reach SUCCEEDED."
    info "Kubernetes Pod status:"
    kubectl get pods -n "$K8S_NAMESPACE" -l "app.kubernetes.io/managed-by=job-orchestrator" || true
    exit 1
fi

# ------------------------------------------------------------------------------
# 7. End-to-End Assertions
# ------------------------------------------------------------------------------
header "Step 7: Asserting Database Results & Data Integrity"

TOTAL_PAYMENTS=$(docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -Nse "SELECT COUNT(*) FROM account_payment WHERE job_id = '${JOB_ID}';" 2>/dev/null || echo "0")

RECORDS_INSERTED=$(docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -Nse "SELECT records_inserted FROM file_progress WHERE job_id = '${JOB_ID}' AND step = 'LOAD';" 2>/dev/null || echo "0")

POD_EVENTS_COUNT=$(docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" exec -T mysql \
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -Nse "SELECT COUNT(*) FROM pod_event WHERE job_id = '${JOB_ID}';" 2>/dev/null || echo "0")

echo -e "\n${BOLD}Execution Verification Metrics:${NC}"
echo -e "  - Target Job ID:              ${CYAN}${JOB_ID}${NC}"
echo -e "  - Requested Record Count:     ${RECORD_COUNT}"
echo -e "  - Payments Inserted (MySQL):  ${TOTAL_PAYMENTS}"
echo -e "  - File Progress (LOAD step):  ${RECORDS_INSERTED}"
echo -e "  - Pod Lifecycle Events:       ${POD_EVENTS_COUNT}"

if [ "$TOTAL_PAYMENTS" -ne "$RECORD_COUNT" ]; then
    error "Payment count assertion failed! Expected $RECORD_COUNT rows in account_payment, found $TOTAL_PAYMENTS."
    exit 1
fi

if [ "$RECORDS_INSERTED" -ne "$RECORD_COUNT" ]; then
    error "File progress assertion failed! Expected $RECORD_COUNT records_inserted in file_progress, found $RECORDS_INSERTED."
    exit 1
fi

success "All database assertions passed exactly ($TOTAL_PAYMENTS rows inserted and verified)!"

header "Walking Skeleton Demonstration Completed Successfully!"
info "Detailed logs are available at: ${LOG_DIR}"
