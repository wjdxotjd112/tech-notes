Release platform configuration, 2026-10-22

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

The VMware sample uses one ESXi host, five template NICs and four test VMs.
All example network addresses must be replaced with reserved site networks.
Backup scheduling is optional and must be enabled only after a manual backup.
