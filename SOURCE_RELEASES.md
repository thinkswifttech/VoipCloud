# Source releases

This process is mandatory for every VoIPCloud binary distributed through the
Apple App Store, Google Play, or another channel under GNU AGPLv3.

## Binary-to-source rule

Every distributed binary must correspond to a public, immutable tag in this
repository. Use the tag format `v<version>+<build>`, matching the version and
build number in `pubspec.yaml`.

The tagged commit must be the exact source used to build the binary. Do not
build from private-only commits, uncommitted changes, or a sanitized copy made
after the binary was produced.

## What the tag must contain

Include all material needed to build, install, run, and modify the client,
including:

- Flutter/Dart application source;
- Android, iOS, macOS, and Windows native bridges that are shipped;
- build definitions, scripts, interface definitions, and project files;
- dependency manifests and lock files;
- local modifications or patches applied to third-party components; and
- copyright, license, and third-party notices.

Credentials, signing keys, provisioning profiles, Firebase project files,
production accounts, and private server configuration must not be published.
If a non-public module is compiled or linked into the app and is required to
build or run it, the binary must not be distributed under this open-source
license path until that licensing/source issue is resolved.

## Release procedure

1. Merge the complete release source to the public repository.
2. Audit the full public diff and history for secrets, personal data, internal
   hostnames, IP addresses, logs, and infrastructure details.
3. Run the checks in [BUILDING.md](BUILDING.md).
4. Commit every dependency lock file. In particular, record the exact iOS
   Liblinphone Swift-package revision; a moving branch name alone is not enough
   for a production source release.
5. Create the version tag from the exact commit used for the store build.
6. Build the store artifacts from a clean checkout of that tag.
7. Create a GitHub Release for the tag and record:
   - app version and build number;
   - commit SHA;
   - Flutter version;
   - Liblinphone versions and resolved revisions; and
   - SHA-256 checksums of the AAB and IPA.
8. Keep the tag and its source downloadable at no charge while that binary is
   distributed. The app's About screen must continue to link users to the
   public releases and GNU AGPLv3 license.

## Flexisip is separate

This repository covers the VoIPCloud client only. Flexisip and Flexisip
Account Manager are separate AGPLv3 programs. If a modified Flexisip-based
service is operated, its users must receive the required notice and source
access through a separate, sanitized publication. Do not publish server
credentials, deployment configuration, network diagrams, or operational
runbooks in this client repository.

This document is an engineering compliance procedure, not legal advice.
