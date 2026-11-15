# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add automated walking skeleton demonstration script `scripts/demo-walking-skeleton.sh` to validate end-to-end Kubernetes job execution, backing services, and database row assertions ([#4](https://github.com/uconn-cse-sdp-2027-team13/platform-infra/issues/4)).
- Add automated MySQL initialization via `migrations/` volume mount in `compose/docker-compose.yml` with explicit UTC timezone ([#4](https://github.com/uconn-cse-sdp-2027-team13/platform-infra/issues/4)).
- Update `.env.example` with S3 and workload container networking configuration ([#4](https://github.com/uconn-cse-sdp-2027-team13/platform-infra/issues/4)).
- Add `platform-infra/README.md` documentation covering prerequisites, quick start, service endpoints, and demonstration usage ([#4](https://github.com/uconn-cse-sdp-2027-team13/platform-infra/issues/4)).
- Add a local development stack for MySQL 8, Redis 7 with AOF persistence, and RustFS, including sample environment settings and startup and teardown scripts.
- Created a MySQL database schema ([#3](https://github.com/uconn-cse-sdp-2027-team13/platform-infra/issues/3)).