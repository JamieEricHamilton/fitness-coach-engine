-- coach-engine: coach_context(kind)
-- One RPC that assembles the fact document the model receives, sliced per
-- event type so each call carries only what it needs (a weigh-in gets ~11KB,
-- a food event ~14KB, the weekly review everything at ~45KB). The charter is
-- the first block of every slice and is the cached system prompt in n8n.

create or replace function public.coach_context(kind text default 'review', session_exercises text[] default null)
returns jsonb language sql stable set search_path = '' as $$
  with base as (
    select jsonb_build_object(
      'generated_at', now(),
      'today', current_date,
      'kind', kind,
      'charter', (select content from public.coach_config where key = 'charter' and active),
      'programme', (select jsonb_object_agg(key, jsonb_build_object('value', value, 'notes', notes)) from public.programme),
      'recovery', (select to_jsonb(r) from public.v_recovery r),
      'weight_trend', (select jsonb_agg(to_jsonb(x)) from (select * from public.v_weight_trend limit 14) x)
    ) as j
  ),
  extras as (
    select case kind
      when 'weight' then jsonb_build_object(
        'today_plan', public.fn_day_type(current_date),
        'nutrition_days', (select jsonb_agg(to_jsonb(n) - 'steps' - 'cardio_notes') from (select * from public.v_nutrition_days limit 7) n),
        'weekly_training', (select jsonb_agg(to_jsonb(w)) from (select * from public.v_weekly_training limit 2) w))
      when 'tape' then jsonb_build_object(
        'measurements', (select jsonb_agg(to_jsonb(m) - 'created_at' - 'updated_at' - 'photo_link') from (select * from public.measurements order by date desc limit 8) m))
      when 'food' then jsonb_build_object(
        'today_plan', public.fn_day_type(current_date),
        'nutrition_days', (select jsonb_agg(to_jsonb(n)) from public.v_nutrition_days n),
        'today_log', (select jsonb_agg(jsonb_build_object('time', time, 'item', item, 'grams', grams, 'kcal', kcal, 'protein_g', protein_g, 'fibre_g', fibre_g) order by time) from public.food_log where date = current_date),
        'weekly_training', (select jsonb_agg(to_jsonb(w)) from (select * from public.v_weekly_training limit 2) w),
        'muscle_recency', (select jsonb_agg(to_jsonb(m)) from (select * from public.v_muscle_recency where days_since <= 14) m),
        'programme_days', (select jsonb_agg(jsonb_build_object('day', day, 'exercise', exercise, 'role', role) order by day, seq) from public.programme_days where status = 'active'),
        'stool_days', (select jsonb_agg(to_jsonb(s)) from (select * from public.v_stool_days limit 7) s),
        'open_pending', (select jsonb_agg(jsonb_build_object('item', item_raw, 'date', date)) from public.pending where status = 'open'))
      when 'workout' then jsonb_build_object(
        'today_plan', public.fn_day_type(current_date),
        'programme_days', (select jsonb_agg(jsonb_build_object('day', day, 'seq', seq, 'exercise', exercise, 'role', role, 'sets', target_sets, 'reps', rep_low || '-' || rep_high, 'rir', rir_target, 'notes', notes, 'status', status) order by day, seq) from public.programme_days where status <> 'paused'),
        'exercise_trends', (select jsonb_agg(to_jsonb(e)) from public.v_exercise_trend e
            where e.last_date >= current_date - 120
              and (session_exercises is null or e.exercise = any(session_exercises)
                   or e.exercise in (select exercise from public.programme_days where role = 'focus'))),
        'all_time_bests', (select jsonb_agg(to_jsonb(b)) from public.v_exercise_bests b where session_exercises is null or b.exercise = any(session_exercises)),
        'weekly_training', (select jsonb_agg(to_jsonb(w)) from (select * from public.v_weekly_training limit 6) w),
        'muscle_recency', (select jsonb_agg(to_jsonb(m)) from public.v_muscle_recency m),
        'nutrition_days', (select jsonb_agg(to_jsonb(n) - 'steps' - 'cardio_notes') from (select * from public.v_nutrition_days limit 7) n))
      when 'digest_morning' then jsonb_build_object(
        'today_plan', public.fn_day_type(current_date),
        'today_so_far', (select to_jsonb(d) - 'created_at' - 'updated_at' - 'quiz_msg_id' from public.daily d where date = current_date),
        'yesterday', (select to_jsonb(d) - 'created_at' - 'updated_at' - 'quiz_msg_id' from public.daily d where date = current_date - 1),
        'yesterday_plan', public.fn_day_type(current_date - 1),
        'yesterday_log', (select jsonb_agg(jsonb_build_object('time', time, 'item', item, 'kcal', kcal, 'protein_g', protein_g) order by time) from public.food_log where date = current_date - 1),
        'yesterday_sessions', (select jsonb_agg(jsonb_build_object('type', session_type, 'title', title, 'sets', n_sets)) from public.sessions where date = current_date - 1),
        'yesterday_stool', (select to_jsonb(s) from public.v_stool_days s where s.date = current_date - 1),
        'nutrition_days', (select jsonb_agg(to_jsonb(n) - 'cardio_notes') from (select * from public.v_nutrition_days limit 7) n),
        'weekly_training', (select jsonb_agg(to_jsonb(w)) from (select * from public.v_weekly_training limit 2) w),
        'muscle_recency', (select jsonb_agg(to_jsonb(m)) from (select * from public.v_muscle_recency where days_since <= 14) m),
        'programme_days', (select jsonb_agg(jsonb_build_object('day', day, 'exercise', exercise, 'role', role, 'sets', target_sets, 'reps', rep_low || '-' || rep_high) order by day, seq) from public.programme_days where status = 'active'),
        'stalled', (select jsonb_agg(jsonb_build_object('exercise', e.exercise, 'last_date', e.last_date)) from public.v_exercise_trend e where e.stalled_4 and e.last_date >= current_date - 30),
        'last_tape', (select jsonb_build_object('date', max(date), 'days_since', current_date - max(date)) from public.measurements),
        'open_pending', (select jsonb_agg(jsonb_build_object('item', item_raw, 'date', date)) from public.pending where status = 'open'))
      when 'digest_night' then jsonb_build_object(
        'today_plan', public.fn_day_type(current_date),
        'today', (select to_jsonb(d) - 'created_at' - 'updated_at' from public.daily d where date = current_date),
        'today_log', (select jsonb_agg(jsonb_build_object('time', time, 'item', item, 'grams', grams, 'kcal', kcal, 'protein_g', protein_g) order by time) from public.food_log where date = current_date),
        'today_sessions', (select jsonb_agg(jsonb_build_object('type', session_type, 'title', title, 'exercises', n_exercises, 'sets', n_sets)) from public.sessions where date = current_date),
        'today_stool', (select jsonb_agg(bristol_type order by time nulls last, id) from public.stool_log where date = current_date),
        'open_pending', (select jsonb_agg(jsonb_build_object('item', item_raw)) from public.pending where status = 'open' and date = current_date))
      else jsonb_build_object(   -- 'review': everything, used for free-form questions and the weekly review
        'today_plan', public.fn_day_type(current_date),
        'programme_days', (select jsonb_agg(jsonb_build_object('day', day, 'seq', seq, 'exercise', exercise, 'role', role, 'sets', target_sets, 'reps', rep_low || '-' || rep_high, 'rir', rir_target, 'notes', notes, 'status', status) order by day, seq) from public.programme_days where status <> 'paused'),
        'exercise_trends', (select jsonb_agg(to_jsonb(e)) from public.v_exercise_trend e where e.last_date >= current_date - 120),
        'all_time_bests', (select jsonb_agg(to_jsonb(b)) from public.v_exercise_bests b),
        'weekly_training', (select jsonb_agg(to_jsonb(w)) from public.v_weekly_training w),
        'muscle_recency', (select jsonb_agg(to_jsonb(m)) from public.v_muscle_recency m),
        'nutrition_days', (select jsonb_agg(to_jsonb(n)) from public.v_nutrition_days n),
        'measurements', (select jsonb_agg(to_jsonb(m) - 'created_at' - 'updated_at' - 'photo_link') from (select * from public.measurements order by date desc limit 8) m),
        'stool_days', (select jsonb_agg(to_jsonb(s)) from (select * from public.v_stool_days limit 30) s),
        'quiz_days', (select jsonb_agg(jsonb_build_object('date', date, 'energy', energy, 'mood', mood, 'soreness', soreness, 'hunger', hunger, 'substances', substances, 'note', note) order by date desc) from public.daily where date >= current_date - 28 and (energy is not null or substances is not null)),
        'open_pending', (select jsonb_agg(jsonb_build_object('item', item_raw, 'date', date)) from public.pending where status = 'open'))
    end as j
  )
  select base.j || extras.j from base, extras;
$$;
