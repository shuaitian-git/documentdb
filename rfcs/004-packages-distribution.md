# RFC: Automated Package Distribution for DocumentDB

## Summary

Create an automated distribution system for DocumentDB packages enabling users to install via standard package managers (`apt`/`yum`) with a single command, instead of building from source or manually downloading releases.

## Problem

**Current limitations:**
- Users must downloads from GitHub releases (no dependency management)
- No centralized package repository for easy discovery
- No integration with standard package managers

## Proposed Solution

Automated GitHub Actions pipeline that:
1. Builds 48 package combinations (DEB/RPM across multiple OS/arch/PG versions)
2. Signs packages with GPG for security
3. Publishes to APT/YUM repositories (GitHub Pages → Official PGDG repos)
4. Enables one-command installation: `apt install postgresql-16-documentdb`

**Package Matrix**:
- **DEB**: 4 OS (Debian 11/12, Ubuntu 22.04/24.04) × 2 Arch (amd64/arm64) × 4 PG (15-18) = 32
- **RPM**: 2 OS (RHEL 8/9) × 2 Arch (x86_64/aarch64) × 4 PG (15-18) = 16
- **Total**: 48 packages per release

**Note**: Currently building PG 16-17; will add 15 & 18 after compatibility testing.

## Hosting Strategy

**1 - GitHub Pages**: Fast deployment for immediate availability, no infrastructure setup required. Need to create new repository: documentdb/packages.

**2 - Official Repositories**: Submit to official apt/yum repositories and PostgreSQL Global Development Group (PGDG).
If published with PGDG (like postgis), users then can install our documentdb more easily and no need to add additional repository:
```
apt-get update && apt-get install -y \
    postgresql-16 \
    postgresql-16-cron \
    postgresql-16-rum \
    postgresql-16-pgvector \
    postgresql-16-postgis-3 \
    postgresql-16-documentdb
```
And with dependency set up, only install documentdb, others will be handled automatically.

**3 - Self-hosted Website** (Alternative to GitHub Pages): If GitHub Pages has limitations or for additional control, set up dedicated website with custom domain. Provides:
- Full control over infrastructure
- Custom branding and domain (e.g. packages.documentdb.com)
- No rate limits
- Production SLA with CDN

## Host Repository Structure

```
documentdb/packages (public repo)
├── README.md          # Installation instructions
├── apt/
│   ├── pool/main/     # All .deb files
│   └── dists/         # Metadata (bullseye, bookworm, jammy, noble)
└── yum/
    ├── el8/           # RHEL 8 (x86_64, aarch64)
    └── el9/           # RHEL 9 (x86_64, aarch64)
```

## Implementation Details

### 1. Workflow (`.github/workflows/documentdb_release.yml`)

**Triggers**: Manual dispatch, Git tag push (`v*`)

**Steps**:
1. Checkout & extract version
2. Build 48 packages in parallel
3. GPG sign all packages
4. Generate APT/YUM metadata
5. Push to `documentdb/packages`
6. (Optional) Create GitHub release

### 2. Security: GPG Package Signing

**Key Generation**:
```bash
gpg --full-generate-key  # RSA 4096, 2-year expiry
```

**Signing**:
- DEB: `dpkg-sig --sign builder package.deb`
- RPM: `rpm --addsign package.rpm`
- Metadata: Sign Release files (APT), repomd.xml (YUM)

**Key Storage**:
- Private: GitHub Secrets (`GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`)
- Public: Published in repo (`apt/public.key`, `yum/RPM-GPG-KEY-DocumentDB`)

### 3. User Installation

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