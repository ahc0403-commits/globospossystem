# Isolated scalability measurements — 2026-09-05

Both runs used the workload, fixture schema, limits and caveats in `../../scalability-remaining-execution.md`.
Initial run overlapped local repository verification; the repeat ran after it stopped. Other local Supabase containers remained running. Neither is a production capacity certification.

| Run | Stores / VUs | Requests | Errors | Max in flight | Queue p95 ms | Detailed report p95 ms | All-store report p95 ms | Response bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| initial | 10 / 50 | 201 | 0 | 6 | 19.29 | 24 | 26.34 | 164376 |
| initial | 50 / 300 | 1200 | 0 | 102 | 431.2 | 627.51 | 508.57 | 1427880 |
| initial | 100 / 1000 | 2647 | 61 | 830 | 10694.02 | 10303.15 | 11174.3 | 4195286 |
| repeat | 10 / 50 | 201 | 0 | 3 | 6.05 | 10.72 | 12 | 164376 |
| repeat | 50 / 300 | 1203 | 0 | 9 | 3.96 | 8 | 32.43 | 1430268 |
| repeat | 100 / 1000 | 3523 | 0 | 825 | 4626.26 | 4812.18 | 4582.26 | 5759193 |

The initial C run recorded 61 invalid/failed responses; the retained first ten failures were HTTP 504 around the configured ten-second pool acquisition deadline. The original driver did not retain the API error body, so PGRST003 is not proven by that run. The repeat retained error codes but recorded no errors. Do not attribute all latency to PostgreSQL: the one-CPU PostgREST container was also saturated.

C remained slow in the repeat (p95 around 4.6–4.8 seconds). A and B had no errors in either short run. Different host contention materially changed latency; the evidence supports more staging measurement, not a guaranteed store limit or savings estimate.

Each response was validated against exact seeded totals (3,400,000 per store per selected day) or four queue items. VUs use a closed-loop request/think-time model; completed request counts are observed, not a fixed offered rate. Byte counts are HTTP response bodies, not billable Supabase/Vercel egress.

The index comparison uses 100,000 payments across 100 stores and 180 retained days, plus 40,000 queue items. The scenario runs separately reseed 30 days. Execution times are individual EXPLAIN samples, not latency percentiles; inspect block counts and plans.

Required staging/production acceptance: actual role/screen mix and orders/minute, full KDS RPC latency and database plans, interval pg_stat_statements calls/time, CPU and I/O, pool waits/active connections, Realtime channels and delivered messages, reconnect catch-up, order/payment lock waits, cron duration/failure/cursor lag, response bytes and billed egress, and Vercel request/build usage. Observe a pilot store through real business hours before widening rollout.
