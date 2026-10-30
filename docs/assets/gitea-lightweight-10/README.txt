Release platform configuration, updated 2026-10-30

Read the accompanying guide before copying files to a server.
This is configuration source, not the customer deployment TAR.

host/       Files mapped to the same absolute paths on a new server.
repository/ Copy workflows/publish-manifest.yaml to .gitea/workflows/,
            gitignore to .gitignore, and adapt release/manifest.example.yaml.

No credentials, private keys, Runner registration, images or product binaries
are included. Use the proven product source and artifacts from your release seed.
The manifest is a format/reference snapshot. Recalculate all hashes for your
actual files, especially the Nexus image archive.

Do not copy host/ over an existing server. Install the files in guide order.
Do not run any of these scripts just to inspect them.

Edit host/etc/gitea-runner-env/services.env for service and pipeline settings.
Use TEST_SKIP_LABEL=skip-test and required PR approvals=0. A merged release-branch
PR is still required for current/future-line release tags; review-count API checks
are not used. Historical-line annotated patch tags remain supported.
Set NEXUS_DOWNLOAD_URL only when test VMs need a different HTTPS Nexus base URL
from the Runner. Empty means the same internal NEXUS_URL.
bundle-pipeline.env and backup.env load it; do not edit derived settings there.
Passwords and tokens belong in Actions Secrets or protected credential files.
repository/pull_request_template.md is copied to .gitea/pull_request_template.md.
Gitea Release notes are written manually from the PR description; TAR files stay
in Nexus and are linked, not attached to Gitea.

The VMware sample uses one ESXi host, five template NICs and four test VMs.
All example network addresses must be replaced with reserved site networks.
Backup scheduling is optional and must be enabled only after a manual backup.
