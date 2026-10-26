-- coach-engine: source-of-truth schema (Postgres / Supabase)
-- Schema only. No rows. Column names match the original Google Sheet tabs the
-- system was migrated from, which is why some are flat and a little denormalised.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Training
-- ---------------------------------------------------------------------------

create table public.exercises (
  exercise        text primary key,
  muscle_group    text,
  equipment       text,                 -- barbell / dumbbell / machine / cable / bodyweight
  first_date      date,
  last_date       date,
  sessions        integer,
  sets            integer,
  aliases         text,                 -- pipe-separated raw names that map to this exercise
  substitute_for  text,
  created_at      timestamptz not null default now()
);

create table public.sessions (
  session_id      text primary key,
  date            date not null,
  gym             text,
  session_type    text,                 -- push / pull / legs
  title           text,
  n_exercises     integer,
  n_sets          integer,
  comments        text,
  date_source     text,
  source          text,                 -- keep-import / telegram
  raw_note        text,
  created_at      timestamptz not null default now()
);
create index sessions_date_idx on public.sessions (date);

create table public.workouts (
  id              bigserial primary key,
  date            date not null,
  session_id      text not null,
  gym             text,
  session_type    text,
  exercise        text not null,
  exercise_raw    text,
  muscle_group    text,
  equipment       text,
  set_no          integer not null,
  weight          numeric,
  unit            text,                 -- kg / bw / kg_per_side
  reps            numeric,
  pb_flag         integer default 0,
  proud           integer default 0,
  effort          integer default 0,
  delta_vs_prev   numeric,
  note            text,
  source          text,
  rest_s          integer,
  hold_s          integer,
  warmup          boolean not null default false,
  created_at      timestamptz not null default now()
);
create index workouts_date_idx on public.workouts (date);
create index workouts_exercise_date_idx on public.workouts (exercise, date);
create index workouts_session_id_idx on public.workouts (session_id);

-- ---------------------------------------------------------------------------
-- Programme: key/value config plus the per-day training template
-- ---------------------------------------------------------------------------

create table public.programme (
  key             text primary key,
  value           text,
  notes           text,
  updated_at      timestamptz not null default now()
);

create table public.programme_days (
  id              bigserial primary key,
  day             text not null,        -- push / pull / legs
  seq             integer not null,
  exercise        text not null references public.exercises (exercise),
  role            text not null default 'accessory',   -- focus / compound / accessory
  target_sets     integer not null,
  rep_low         integer not null,
  rep_high        integer not null,
  rir_target      text,
  notes           text,
  status          text not null default 'active',      -- active / paused / proposed
  source          text not null default 'user',        -- user / coach
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (day, seq)
);

-- ---------------------------------------------------------------------------
-- Daily state: one row per date (weight, nutrition totals, check-in answers)
-- ---------------------------------------------------------------------------

create table public.daily (
  date            date primary key,
  weight_kg       numeric,
  weight_7d_avg   numeric,
  weight_source   text,                 -- scale provider or null = typed
  calories        numeric,
  protein_g       numeric,
  carbs_g         numeric,
  fat_g           numeric,
  fibre_g         numeric,
  steps           integer,
  resting_hr      numeric,
  hrv             numeric,
  sleep_hrs       numeric,
  vo2max          numeric,
  cardio_type     text,
  cardio_mins     numeric,
  cardio_notes    text,
  day_type        text check (day_type in ('push','pull','legs','cardio','rest')),
  -- night check-in answers (1-5 scales)
  energy          smallint check (energy between 1 and 5),
  mood            smallint check (mood between 1 and 5),
  soreness        smallint check (soreness between 1 and 5),
  hunger          smallint check (hunger between 1 and 5),
  substances      text check (substances in ('none','alcohol','thc','both')),
  bowel_count     smallint check (bowel_count between 0 and 4),
  note            text,
  -- quiz state machine
  quiz_step       smallint not null default 0,
  quiz_msg_id     bigint,
  day_status      text not null default 'open' check (day_status in ('open','confirmed')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table public.weigh_ins (
  grpid           bigint primary key,   -- provider's measurement group id: idempotent ingest
  measured_at     timestamptz not null,
  date            date not null,
  weight_kg       numeric not null,
  source          text default 'withings',
  ignored         boolean not null default false,
  created_at      timestamptz default now()
);
create index weigh_ins_date_idx on public.weigh_ins (date);

create table public.measurements (
  date                  date primary key,
  neck_cm               numeric,
  chest_cm              numeric,
  waist_navel_cm        numeric,
  hips_cm               numeric,
  shoulders_cm          numeric,
  l_arm_cm              numeric,
  r_arm_cm              numeric,
  l_thigh_cm            numeric,
  r_thigh_cm            numeric,
  l_calf_cm             numeric,
  r_calf_cm             numeric,
  navy_bf_pct           numeric,
  shoulder_waist_ratio  numeric,
  photo_link            text,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create table public.stool_log (
  id              bigserial primary key,
  date            date not null,
  "time"          time,
  bristol_type    smallint not null check (bristol_type between 1 and 7),
  note            text,
  source          text not null default 'message' check (source in ('message','quiz')),
  created_at      timestamptz not null default now()
);
create index stool_log_date_idx on public.stool_log (date);

-- ---------------------------------------------------------------------------
-- Food: personal library + log + unresolved items + Telegram album buffer
-- ---------------------------------------------------------------------------

create table public.foods (
  id                text primary key,   -- slug of name + brand
  name              text not null,
  aliases           text,               -- pipe-separated spoken aliases
  brand             text,
  per_100g_kcal     numeric,
  per_100g_protein  numeric,
  per_100g_carbs    numeric,
  per_100g_fat      numeric,
  per_100g_fibre    numeric,
  serving_desc      text,
  serving_g         numeric,
  source            text,               -- label / openfoodfacts / estimate
  added             date,
  created_at        timestamptz not null default now()
);

create table public.food_log (
  id              text primary key,
  date            date not null,
  "time"          time,
  meal_text       text,
  item            text,
  food_id         text references public.foods (id),
  grams           numeric,
  kcal            numeric,
  protein_g       numeric,
  carbs_g         numeric,
  fat_g           numeric,
  fibre_g         numeric,
  source          text,                 -- library / openfoodfacts / label / estimate / photo
  created_at      timestamptz not null default now()
);
create index food_log_date_idx on public.food_log (date);

create table public.pending (
  id              text primary key,
  date            date,
  item_raw        text,
  qty_desc        text,
  grams           numeric,
  status          text default 'open',  -- open / resolved
  created         timestamptz,
  created_at      timestamptz not null default now()
);

create table public.media_buffer (
  message_id      bigint primary key,
  group_key       text not null,        -- g:<media_group_id> or m:<message_id>
  file_id         text not null,
  caption         text,
  created_at      timestamptz not null default now()
);
create index media_buffer_group_key_idx on public.media_buffer (group_key);

-- ---------------------------------------------------------------------------
-- Integrations: OAuth state per provider (tokens live here, not in n8n)
-- ---------------------------------------------------------------------------

create table public.integrations (
  provider          text primary key,
  client_id         text,
  client_secret     text,
  access_token      text,
  refresh_token     text,
  expires_at        timestamptz,
  external_user_id  text,
  callback_url      text,
  meta              jsonb default '{}'::jsonb,
  updated_at        timestamptz default now()
);

-- ---------------------------------------------------------------------------
-- Coaching charter: versioned, one active row per key
-- ---------------------------------------------------------------------------

create table public.coach_config (
  id              bigserial primary key,
  key             text not null,        -- 'charter'
  version         integer not null default 1,
  active          boolean not null default true,
  content         text not null,        -- the charter document the model receives on every call
  notes           text,                 -- what this version changed
  created_at      timestamptz not null default now(),
  unique (key, version)
);
create unique index coach_config_one_active on public.coach_config (key) where active;

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create trigger daily_updated_at          before update on public.daily          for each row execute function public.set_updated_at();
create trigger measurements_updated_at   before update on public.measurements   for each row execute function public.set_updated_at();
create trigger programme_updated_at      before update on public.programme      for each row execute function public.set_updated_at();
create trigger programme_days_updated_at before update on public.programme_days for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security: enabled everywhere, no anon policies. The n8n workflows
-- use the service role key, which bypasses RLS. A dashboard would get
-- read-only policies on views, never on the raw tables.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

create policy "service role full access" on public.media_buffer for all using (true) with check (true);
