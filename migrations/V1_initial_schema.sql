CREATE TABLE job (
    job_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    file_name VARCHAR(255) NOT NULL,
    file_path VARCHAR(1024) NOT NULL,
    current_state ENUM ('QUEUED', 'DISPATCHED', 'RUNNING', 'SUCCEEDED', 'RETRY_WAIT', 'DEAD_LETTERED', 'CANCELLED') NOT NULL DEFAULT 'QUEUED',
    attempt_count INT UNSIGNED,
    max_attempts INT UNSIGNED,
    k8s_job_name VARCHAR(255),
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3), -- insertions into table must be in UTC
    started_at DATETIME(3),
    finished_at DATETIME(3),
    last_error TEXT
);

CREATE TABLE job_attempt (
    attempt_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    job_id BIGINT UNSIGNED NOT NULL,
    attempt_number INT UNSIGNED NOT NULL,
    pod_name VARCHAR(255),
    node_name VARCHAR(255),
    started_at DATETIME(3) NOT NULL,
    ended_at DATETIME(3),
    exit_code INT,
    failure_reason TEXT,
    CONSTRAINT fk_attempt_job FOREIGN KEY (job_id) REFERENCES job(job_id)
);

CREATE TABLE pod_event (
    event_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    job_id BIGINT UNSIGNED NOT NULL,
    pod_name VARCHAR(255) NOT NULL,
    event_type ENUM ('NORMAL', 'WARNING') NOT NULL,
    pod_phase ENUM ('PENDING', 'RUNNING', 'SUCCEEDED', 'FAILED', 'UNKNOWN') NOT NULL,
    pod_message TEXT,
    observed_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    CONSTRAINT fk_event_job FOREIGN KEY (job_id) REFERENCES job(job_id)
);

CREATE TABLE file_progress (
    job_id BIGINT UNSIGNED NOT NULL,
    step ENUM ('FETCH', 'VALIDATE', 'LOAD', 'VERIFY') NOT NULL,
    records_read BIGINT UNSIGNED NOT NULL DEFAULT 0,
    records_inserted BIGINT UNSIGNED NOT NULL DEFAULT 0,
    records_failed BIGINT UNSIGNED NOT NULL DEFAULT 0,
    checkpoint_offset BIGINT UNSIGNED NOT NULL DEFAULT 0,
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    CONSTRAINT fk_progress_job FOREIGN KEY (job_id) REFERENCES job(job_id)
);

CREATE TABLE account_payment (
    job_id BIGINT UNSIGNED NOT NULL,
    line_number BIGINT UNSIGNED NOT NULL,
    account_number VARCHAR(32) NOT NULL,
    email VARCHAR(255),
    payment_due_date DATE,
    payment_amount DECIMAL(12,2) NOT NULL,
    loaded_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    CONSTRAINT fk_payment_job FOREIGN KEY (job_id) REFERENCES job(job_id),
    PRIMARY KEY (job_id, line_number)
);

-- do we need file_name if file_path already contains the name?
-- Is attempt_number necessary in job_attempt if job_id contains attempt_count?
-- job(current_state) cannot be named "state" like in design doc
-- pod_event(pod_message) cannot be named "message" like in design doc
-- file_progress table does not have a primary key in design doc

-- we need to define the database's time zone as UTC (for CURRENT_TIMESTAMP()) in mySQL's config file
