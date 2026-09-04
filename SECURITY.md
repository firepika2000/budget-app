# Security policy

This is a private, self-hosted project. Do not open a public issue containing credentials, invitation codes, tokens, transaction data, or deployment details.

## Reporting a problem

Report suspected vulnerabilities privately to the repository owner. Include the affected commit and a minimal reproduction with all personal and secret values removed.

## Deployment responsibilities

- Keep the repository private and review access regularly.
- Use HTTPS or a trusted private VPN for every non-local connection.
- Use unique passwords and independently generated database and JWT secrets.
- Keep the host, containers, reverse proxy, and application current.
- Maintain encrypted off-host backups and test restoration.
- Treat exported CSV and JSON files as sensitive financial records.

The application deliberately has no bank synchronization, third-party analytics, subscription service, or required vendor cloud dependency.
