# Edge fixture evidence

See [the audit reproduction guide](../README.md#edge-재현) for current commands.

The handlers are imported unchanged. Only HTTP/database/Firebase authentication transports are replaced with local stubs; no network permission is granted. MISA is explicitly enabled in fixture data, not in production. Auth records and metadata are synthetic. Calls, returned rows and serialized bytes are fixture measurements; elapsed time and heap delta are not production latency or peak memory. `probe_auth_scan.ts` extracts the current helper into its own directory, so reproduce from a temporary copy to preserve these files.
