-- coach-engine: fact views
-- All analysis (PBs, estimated 1RM, stall detection, trends) is done in SQL.
-- The model receives these as facts and is told to use only numbers from them.

-- Top set per exercise per session, with Epley e1RM (reps capped at 12 so a
-- 30-rep set does not produce a silly estimate). Bodyweight sets have no e1RM.
create view public.v_session_top_sets as
select distinct on (session_id, exercise)
  date, session_id, gym, session_type, exercise, muscle_group, equipment, unit, weight, reps,
  case when unit = 'bw' or weight is null or weight = 0 then null
       else round(weight * (1 + least(reps, 12) / 30.0), 1) end as e1rm,
  (select count(*) from public.workouts w2 where w2.session_id = w.session_id and w2.exercise = w.exercise) as n_sets
from public.workouts w
order by session_id, exercise, weight desc nulls last, reps desc;

-- All-time best set per exercise, with date and gym (machine weights are only
-- comparable within a gym, which the consumer handles via best_gym).
create view public.v_exercise_bests as
with top as (
  select distinct on (exercise) exercise, muscle_group, equipment, unit, weight, reps, date, gym
  from public.workouts
  where exercise is not null
  order by exercise, (case when unit = 'bw' then 0 else weight end) desc nulls last, reps desc, date desc
), agg as (
  select exercise,
    max(case when unit = 'bw' or weight is null or weight = 0 then null
             else round(weight * (1 + least(reps, 12) / 30.0), 1) end) as best_e1rm,
    min(date) as first_date, max(date) as last_date,
    count(distinct session_id) as sessions, count(*) as sets
  from public.workouts group by exercise
)
select t.exercise, t.muscle_group, t.equipment, t.weight as best_weight, t.unit, t.reps as best_reps,
       t.date as best_date, t.gym as best_gym, a.best_e1rm, a.first_date, a.last_date, a.sessions, a.sets
from top t join agg a using (exercise)
order by a.sets desc;

-- Last six sessions per lift plus a stall flag. Machine and cable lifts are
-- scoped to the most recent gym; stalled_4 needs four sessions since the
-- programme's baseline_date so old history cannot trip it.
create view public.v_exercise_trend as
with baseline as (
  select coalesce((select value::date from public.programme where key = 'baseline_date'), current_date - 90) as d
), last_gym as (
  select distinct on (exercise) exercise, gym from public.v_session_top_sets
  order by exercise, date desc, session_id desc
), scoped as (
  select t.* from public.v_session_top_sets t
  join last_gym g on g.exercise = t.exercise
  where t.equipment not in ('machine','cable') or t.gym = g.gym
), ranked as (
  select s.*,
    row_number() over (partition by s.exercise order by s.date desc, s.session_id desc) as rn,
    max(s.e1rm) over (partition by s.exercise) as best_e1rm_scope,
    count(*) filter (where s.date >= current_date - 90) over (partition by s.exercise) as sessions_90d,
    count(*) filter (where s.date >= (select d from baseline)) over (partition by s.exercise) as sessions_since_baseline
  from scoped s
), recent as (
  select * from ranked where rn <= 6
)
select exercise, muscle_group, equipment,
  max(date) as last_date,
  max(sessions_90d) as sessions_90d,
  (array_agg(weight order by date desc, session_id desc))[1] as last_weight,
  (array_agg(reps   order by date desc, session_id desc))[1] as last_reps,
  (array_agg(e1rm   order by date desc, session_id desc))[1] as last_e1rm,
  max(e1rm) as best_e1rm_recent,
  max(best_e1rm_scope) as best_e1rm_all_time,
  case when max(sessions_since_baseline) >= 4 and count(*) >= 4
        and (array_agg(e1rm order by date desc, session_id desc))[1] is not null
        and (array_agg(e1rm order by date desc, session_id desc))[1]
            <= greatest((array_agg(e1rm order by date desc, session_id desc))[2],
                        (array_agg(e1rm order by date desc, session_id desc))[3],
                        (array_agg(e1rm order by date desc, session_id desc))[4])
       then true else false end as stalled_4,
  (array_agg(gym order by date desc, session_id desc))[1] as last_gym,
  json_agg(json_build_object('date', date, 'weight', weight, 'unit', unit, 'reps', reps, 'e1rm', e1rm, 'sets', n_sets)
           order by date desc, session_id desc) as history,
  (array_agg(unit order by date desc, session_id desc))[1] as unit,
  max(sessions_since_baseline) as sessions_since_baseline
from recent
group by exercise, muscle_group, equipment;

-- Sets per muscle group per ISO week, last 12 weeks.
create view public.v_weekly_training as
select week_start,
  count(distinct session_id) as lifting_sessions,
  sum(n)::bigint as total_sets,
  json_object_agg(muscle_group, n) as sets_by_muscle
from (
  select date_trunc('week', date)::date as week_start, session_id,
         coalesce(nullif(muscle_group, ''), 'unknown') as muscle_group, count(*) as n
  from public.workouts
  where date >= date_trunc('week', current_date) - interval '84 days'
  group by 1, 2, 3
) s
group by week_start
order by week_start desc;

create view public.v_muscle_recency as
select muscle_group, max(date) as last_trained, current_date - max(date) as days_since
from public.workouts
where muscle_group is not null and muscle_group <> ''
group by muscle_group
order by days_since desc;

-- 7-day rolling average and change vs the previous week. The single reading is
-- noise; this is the signal everything else reads.
create view public.v_weight_trend as
select date, weight_kg,
  round(avg(weight_kg) over (order by date rows between 6 preceding and current row), 2) as avg_7d,
  round(avg(weight_kg) over (order by date rows between 6 preceding and current row)
      - avg(weight_kg) over (order by date rows between 13 preceding and 7 preceding), 2) as change_vs_prev_week,
  count(*) over (order by date rows between 6 preceding and current row) as readings_7d
from public.daily
where weight_kg is not null and date >= current_date - 90
order by date desc;

-- Last 14 days of intake against the day-type-aware target.
create view public.v_nutrition_days as
with t as (
  select public.prog_num('protein_floor_g', 170) as protein_floor,
         public.prog_num('fibre_floor_g', 30) as fibre_floor
)
select d.date, d.calories, d.protein_g, d.carbs_g, d.fat_g, d.fibre_g,
  public.fn_kcal_target(d.date) as kcal_target,
  t.protein_floor, t.fibre_floor,
  d.calories - public.fn_kcal_target(d.date) as kcal_vs_target,
  d.protein_g >= t.protein_floor as protein_hit,
  d.fibre_g >= t.fibre_floor as fibre_hit,
  (select count(*) from public.food_log f where f.date = d.date) as items_logged,
  d.steps, d.resting_hr, d.hrv, d.sleep_hrs, d.cardio_type, d.cardio_mins,
  coalesce((select max(s.session_type) from public.sessions s where s.date = d.date), d.day_type) as day_type
from public.daily d cross join t
where d.date >= current_date - 14 and (d.calories is not null or d.protein_g is not null)
order by d.date desc;

-- 3-day recovery metrics against a 14-day baseline (fed by a wearable later).
create view public.v_recovery as
select
  round(avg(sleep_hrs)  filter (where date >= current_date - 2), 2) as sleep_3d,
  round(avg(sleep_hrs)  filter (where date between current_date - 16 and current_date - 3), 2) as sleep_baseline_14d,
  round(avg(hrv)        filter (where date >= current_date - 2), 1) as hrv_3d,
  round(avg(hrv)        filter (where date between current_date - 16 and current_date - 3), 1) as hrv_baseline_14d,
  round(avg(resting_hr) filter (where date >= current_date - 2), 1) as rhr_3d,
  round(avg(resting_hr) filter (where date between current_date - 16 and current_date - 3), 1) as rhr_baseline_14d,
  count(*) filter (where sleep_hrs is not null) as days_with_sleep_data
from public.daily
where date >= current_date - 16;

-- Gut log per day joined to the PREVIOUS day's intake (one-day lag by design).
create view public.v_stool_days as
with days as (
  select date from public.stool_log where date >= current_date - 60
  union
  select date from public.daily where bowel_count is not null and date >= current_date - 60
)
select dd.date,
  count(s.id) as entries,
  round(avg(s.bristol_type), 1) as mean_type,
  min(s.bristol_type) as min_type, max(s.bristol_type) as max_type,
  array_remove(array_agg(s.bristol_type order by s."time", s.id), null) as types,
  string_agg(s.note, '; ' order by s.id) filter (where s.note is not null) as notes,
  y.calories as prev_day_kcal, y.protein_g as prev_day_protein_g, y.fat_g as prev_day_fat_g, y.fibre_g as prev_day_fibre_g,
  (select string_agg(f.item, ', ' order by f."time") from public.food_log f where f.date = dd.date - 1) as prev_day_items,
  y.substances as prev_day_substances,
  d.bowel_count
from days dd
left join public.stool_log s on s.date = dd.date
left join public.daily d on d.date = dd.date
left join public.daily y on y.date = dd.date - 1
group by dd.date, d.bowel_count, y.calories, y.protein_g, y.fat_g, y.fibre_g, y.substances
order by dd.date desc;

-- Daily row plus the count of gut entries; read by the night quiz state machine.
create view public.v_quiz_rows as
select d.*, (select count(*) from public.stool_log s where s.date = d.date) as stool_entries
from public.daily d;
