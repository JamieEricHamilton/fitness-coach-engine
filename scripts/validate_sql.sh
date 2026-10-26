#!/usr/bin/env bash
# Apply every migration, in order, to a fresh database and exercise the
# hard-rule functions on the empty schema. Needs psql and a reachable
# Postgres (CI uses a service container; locally set PG* env vars or
# DATABASE_URL).
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${DATABASE_URL:-postgresql://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-postgres}}"
P=(psql "$DB" -v ON_ERROR_STOP=1 -q)

for f in supabase/migrations/*.sql; do
  echo "== $f"
  "${P[@]}" -f "$f"
done

echo "== object counts"
"${P[@]}" -At -c "
  select 'tables: '    || count(*) from pg_tables where schemaname = 'public'
  union all select 'views: ' || count(*) from pg_views  where schemaname = 'public'
  union all select 'functions: ' || count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('prog_num','fn_kcal_target','fn_day_type','coach_context','delete_session','set_updated_at');"

echo "== smoke tests"
"${P[@]}" -At -c "select 'fn_day_type ok: ' || (fn_day_type(current_date)->>'day_type');"
"${P[@]}" -At -c "select 'coach_context(' || k || ') ok: ' || length(coach_context(k)::text) || ' chars'
                  from unnest(array['weight','tape','food','workout','digest_morning','digest_night','review']) k;"
"${P[@]}" -At -c "select 'active charter: v' || version from coach_config where key = 'charter' and active;"
"${P[@]}" -At -c "select 'rls enabled on all tables: ' || bool_and(relrowsecurity)
                  from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind = 'r';"
echo "sql validation passed"
