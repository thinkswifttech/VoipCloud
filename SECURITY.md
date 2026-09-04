# Security policy

Please do not report security vulnerabilities through a public issue. Email
`support@thinkswift.com` with a description, reproduction steps, affected
versions, and potential impact.

Never include real SIP credentials, access tokens, private keys, customer data,
or production infrastructure details in a report.

## Repository hygiene

This repository must contain only public-safe source and synthetic test data.
Service configuration, Firebase configuration, signing material, deployment
runbooks, logs, crash dumps, and real contact or directory exports belong in
approved private systems. Review the complete diff and commit history before
every public release.

If sensitive data is committed, do not rely on deleting the file. Revoke or
rotate every affected secret first, remove the data from Git history, and
contact GitHub Support when cached objects or pull-request references also need
purging.
