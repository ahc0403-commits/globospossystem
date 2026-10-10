#!/usr/bin/env python3
"""Owned disposable DB only: permissions, quotas and multi-session slot bounds."""
import concurrent.futures
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
DB = "pos-esgoo-test-" + uuid.uuid4().hex[:12]
AUTH = "00000000-0000-0000-0000-000000000001"
SHOP = "20000000-0000-0000-0000-000000000001"
OTHER = "20000000-0000-0000-0000-000000000002"


def sql(text):
    return subprocess.check_output(
        ["docker", "exec", "-i", DB, "psql", "-X", "-At", "-U", "postgres",
         "-d", "esgoo_test", "-v", "ON_ERROR_STOP=1"], input=text, text=True
    ).strip()


def claim(auth=AUTH, store=SHOP, lease=None):
    lease = lease or str(uuid.uuid4())
    return json.loads(sql(f"SELECT pos_claim_company_tax_lookup('{auth}','{store}','{lease}');"))["outcome"], lease


def release(auth, lease):
    sql(f"SELECT pos_release_company_tax_lookup('{auth}','{lease}');")


def main():
    subprocess.check_call([
        "docker", "run", "--detach", "--rm", "--name", DB,
        "--env", "POSTGRES_PASSWORD=esgoo-isolated-fixture", "--env", "POSTGRES_DB=esgoo_test",
        "postgres:17.6"
    ], stdout=subprocess.DEVNULL)
    try:
        for _ in range(60):
            # The image starts a temporary server during init; wait for PID 1
            # to become the final postgres process, not that temporary listener.
            final_server = subprocess.run(["docker", "exec", DB, "sh", "-c", 'case "$(cat /proc/1/comm)" in *postgres*) exit 0;; *) exit 1;; esac'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ready = subprocess.run(["docker", "exec", DB, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "esgoo_test"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if final_server.returncode == 0 and ready.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("isolated database did not start")
        sql(f"""
          CREATE ROLE anon;
          CREATE ROLE authenticated;
          CREATE ROLE service_role BYPASSRLS;
          CREATE TABLE restaurants(id uuid PRIMARY KEY, is_active boolean NOT NULL DEFAULT true);
          CREATE TABLE users(id uuid PRIMARY KEY, auth_id uuid UNIQUE, role text, is_active boolean DEFAULT true);
          CREATE TABLE fixture_store_access(auth_id uuid, store_id uuid);
          CREATE FUNCTION user_accessible_stores(p_auth uuid) RETURNS SETOF uuid LANGUAGE sql AS
            $$ SELECT store_id FROM fixture_store_access WHERE auth_id=p_auth; $$;
          INSERT INTO restaurants VALUES ('{SHOP}',true),('{OTHER}',true);
          INSERT INTO users SELECT md5('actor-'||i)::uuid,md5('auth-'||i)::uuid,'cashier',true FROM generate_series(1,100) i;
          INSERT INTO users VALUES ('10000000-0000-0000-0000-000000000001','{AUTH}','cashier',true);
          INSERT INTO fixture_store_access SELECT auth_id,'{SHOP}'::uuid FROM users;
        """)
        sql((ROOT / "supabase/migrations/20261011130000_company_tax_lookup.sql").read_text())
        assert claim()[0] == "disabled"
        sql(f"INSERT INTO company_tax_lookup_settings VALUES ('{SHOP}',true),('{OTHER}',true);")
        assert claim(store=OTHER)[0] == "forbidden"
        sql(f"UPDATE users SET is_active=false WHERE auth_id='{AUTH}';")
        assert claim()[0] == "forbidden"
        sql(f"UPDATE users SET is_active=true,role='waiter' WHERE auth_id='{AUTH}';")
        assert claim()[0] == "forbidden"
        sql(f"UPDATE users SET role=NULL WHERE auth_id='{AUTH}';")
        assert claim()[0] == "forbidden"
        sql(f"UPDATE users SET role='cashier' WHERE auth_id='{AUTH}';")
        for role in ["anon", "authenticated"]:
            # Direct client statements exercise actual ACL denial.
            for query in [f"SELECT pos_claim_company_tax_lookup('{AUTH}','{SHOP}',gen_random_uuid());",
                          "SELECT * FROM company_tax_lookup_slots;"]:
                denied = subprocess.run(["docker", "exec", "-i", DB, "psql", "-X", "-At", "-U", "postgres",
                                         "-d", "esgoo_test", "-v", "ON_ERROR_STOP=1"],
                                        input=f"SET ROLE {role}; {query}", text=True, capture_output=True)
                assert denied.returncode == 3 and "permission denied" in denied.stderr, denied.stderr
        for _ in range(10):
            outcome, lease = claim()
            assert outcome == "claimed"
            release(AUTH, lease)
        assert claim()[0] == "rate_limited"
        sql("UPDATE company_tax_lookup_rate SET window_start=now()-interval '61 seconds';")
        assert claim()[0] == "claimed"
        sql("UPDATE company_tax_lookup_slots SET lease_until='-infinity';")
        _, old = claim()
        sql("UPDATE company_tax_lookup_slots SET lease_until='-infinity';")
        _, current = claim()
        release(AUTH, old)
        assert sql(f"SELECT count(*) FROM company_tax_lookup_slots WHERE lease_id='{current}';") == "1"
        release("00000000-0000-0000-0000-000000000002", current)
        assert sql(f"SELECT count(*) FROM company_tax_lookup_slots WHERE lease_id='{current}';") == "1"
        release(AUTH, current)
        records = []
        for parallel in [1, 2, 8]:
            sql("UPDATE company_tax_lookup_slots SET lease_until='-infinity'; DELETE FROM company_tax_lookup_rate;")
            auths = [sql(f"SELECT md5('auth-{i}')::uuid;") for i in range(1, parallel + 1)]
            started = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=parallel) as pool:
                values = list(pool.map(lambda auth: claim(auth)[0], auths))
            winners = values.count("claimed")
            assert winners == min(parallel, 2), values
            active = int(sql("SELECT count(*) FROM company_tax_lookup_slots WHERE lease_until>clock_timestamp();"))
            assert active == winners <= 2
            records.append({"sessions": parallel, "claimed": winners, "limited": values.count("rate_limited"),
                            "slotRows": 2, "elapsedMs": round((time.monotonic()-started)*1000, 2)})
        print(json.dumps({"test": "company_tax_lookup_sql", "permissions": "pass", "quota": "10 per 60s",
                          "expiredAndOwnedLease": "pass", "concurrency": records}, indent=2))
    except Exception:
        print(subprocess.check_output(["docker", "logs", "--tail", "35", DB], stderr=subprocess.STDOUT, text=True))
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", DB], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
