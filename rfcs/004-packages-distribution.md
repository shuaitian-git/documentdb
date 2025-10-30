# RFC: Automated Package Distribution for DocumentDB

## Summary

Automate the build and publication of DocumentDB packages so that customers can install the extension through familiar package managers (`apt`, `yum`, `dnf`) without building from source or manually fetching release assets.

## Problem Statement

Today release consumers face several hurdles:

- Packages are only available as ad-hoc assets on GitHub releases.
- There is no official repository that can be added to `sources.list`/`yum.repos.d`.
- Dependency resolution, upgrades, and security updates are all manual.

## Goals

- Produce signed DEB and RPM artifacts for every supported OS/architecture/PostgreSQL version combination.
- Publish those artifacts to a first-party repository that can be consumed by `apt` and `yum`/`dnf`.
- Automate the end-to-end process through GitHub Actions so each new tag is shipped consistently.

## Hosting Strategy

### 1 - Self owned : GitHub Pages
Leverage ([documentdb.io](https://documentdb.io/)) to serve packages. Fast deployment for immediate availability, no infrastructure setup required. We currently using this repository to build and deploy our documentdb site: https://documentdb.io/.

Example install snippets:
**APT** (Ubuntu 22.04):
```bash
echo "deb [trusted=yes] https://documentdb.github.io/packages/apt jammy main" \
  | sudo tee /etc/apt/sources.list.d/documentdb.list
sudo apt update && sudo apt install postgresql-16-documentdb
```

**YUM** (RHEL 9):
```bash
cat <<EOF | sudo tee /etc/yum.repos.d/documentdb.repo
[documentdb]
name=DocumentDB Repository
baseurl=https://documentdb.github.io/packages/yum/el9/\$basearch
enabled=1
gpgcheck=0
EOF
sudo yum install postgresql16-documentdb
```

Alternatively, if we think GitHub Pages has limitations or for additional control, we can set up dedicated website with custom domain. Provides:
- Full control over infrastructure
- Custom branding and domain (e.g. packages.documentdb.com)
- No rate limits
- Production SLA with CDN

### 2 - Official Repositories
Submit to official apt/yum repositories and PostgreSQL Global Development Group (PGDG).
  - PGDG (PostgreSQL Global Development Group): https://www.postgresql.org/download/, https://download.postgresql.org/pub/repos/
  - PGXN (PostgreSQL Extension Network): community-driven distribution network for PostgreSQL extensions. Details: https://pgxn.org/
  - Debian/Ubuntu archives
  - EPEL (Extra Packages for Enterprise Linux) – Red Hat community repo for RHEL/CentOS Stream: https://docs.fedoraproject.org/en-US/epel/

If published with PGDG (like postgis), users then can install our documentdb more easily and no need to add additional repository:
```bash
apt-get update && apt-get install -y \
    postgresql-16 \
    postgresql-16-cron \
    postgresql-16-rum \
    postgresql-16-pgvector \
    postgresql-16-postgis-3 \
    postgresql-16-documentdb
```
And with dependency set up, only install documentdb, others will be handled automatically.

```bash
apt-get install postgresql-16-documentdb
```

## GitHub Pages Repository Layout

```
documentdb/documentdb.github.io
├── README.md          # Installation instructions
├── packages/
│   ├── apt/
│   │   ├── pool/main/     # All .deb files
│   │   └── dists/         # Metadata (bullseye, bookworm, jammy, noble)
│   └── yum/
│       ├── el8/           # RHEL 8 (x86_64, aarch64)
│       └── el9/           # RHEL 9 (x86_64, aarch64)
└── index.html / docs      # public site content
```

## Automation Pipelines

Within [documentdb](https://github.com/documentdb/documentdb), have a release workflow triggered by release tags (and optionally manual dispatch) will:

1. Build the matrix of packages:
   - **DEB**: Debian 11/12, Ubuntu 22.04/24.04 × amd64/arm64 × PostgreSQL 16–17 (add 15/18 once validated) → 32 artifacts.
   - **RPM**: RHEL 8/9 × x86_64/aarch64 × PostgreSQL 16–17 (add 15/18 once validated) → 16 artifacts.
2. Generate a draft release with note from CHANGELOG.md
3. Upload artifacts as release assets (example: [`v0.107-0`](https://github.com/documentdb/documentdb/releases/tag/v0.107-0)).

Then in [documentdb.github.io](https://github.com/documentdb/documentdb.github.io), we added steps in current GitHub Page deploy workflow:

1. Pull packages from release page of documentdb/documentdb.
2. Sign packages via GPG and publish apt/yum repository metadata.
3. Publish installation documentation alongside the repository.
4. Deploy GitHub Page which will contains a subpage for packages.