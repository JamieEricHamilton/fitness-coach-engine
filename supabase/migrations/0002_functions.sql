-- coach-engine: hard-rule functions
-- These are the deterministic layer. The model never decides what day it is,
-- what the calorie budget is, or how an overshoot is corrected: these do.

-- Numeric programme value with a fallback (programme.value is text so it can
-- hold notes like 'TBC'; non-numeric characters are stripped before casting).
create or replace function public.prog_num(k text, fallback numeric)
returns numeric language sql stable set search_path = '' as $$
  select coalesce(
    (select nullif(regexp_replace(value, '[^0-9.]', '', 'g'), '')::numeric from public.programme where key = k),
    fallback);
$$;

-- Per-day calorie target used by the nutrition views: lifting figure if a
-- session exists on that date or the day was set to a lifting type.
create or replace function public.fn_kcal_target(d date)
returns numeric language sql stable set search_path = '' as $$
  select case
    when exists (select 1 from public.sessions where date = d)
      or (select day_type from public.daily where date = d) in ('push','pull','legs')
    then public.prog_num('calorie_target_lift', 2350)
    else public.prog_num('calorie_target_rest', 1850)
  end;
$$;

-- THE source of "what day is it and what is the budget".
-- Precedence: a session logged today > the user's override > a proposal from
-- the rotation and recent volume. Applies yesterday's overshoot as a capped
-- correction on top. Every consumer (morning digest, food reply, day-type
-- reply) quotes this, so the scale, nutrition and training always agree.
create or replace function public.fn_day_type(d date default current_date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_session text; v_override text; v_type text; v_source text; v_reason text;
  v_last_type text; v_last_date date; v_lifts_7d int; v_cardio_7d int;
  v_kcal numeric; v_prot numeric; v_fat numeric; v_fibre numeric; v_carb numeric; v_cap numeric;
  v_y_type text; v_y_kcal numeric; v_y_target numeric; v_over numeric := 0; v_corr numeric := 0;
begin
  select max(case when session_type in ('push','pull','legs') then session_type else 'push' end) into v_session
    from public.sessions where date = d;
  select day_type into v_override from public.daily where date = d;

  if v_session is not null then v_type := v_session; v_source := 'logged'; v_reason := 'session logged today';
  elsif v_override is not null then v_type := v_override; v_source := 'user'; v_reason := 'set by the user';
  else
    select session_type, date into v_last_type, v_last_date from public.sessions
      where date < d and session_type in ('push','pull','legs') order by date desc limit 1;
    select count(*) into v_lifts_7d from public.sessions where date between d - 6 and d - 1;
    select count(*) into v_cardio_7d from public.daily where date between d - 6 and d - 1 and cardio_mins is not null;
    if v_lifts_7d >= 3 then
      v_type := case when v_cardio_7d < 2 then 'cardio' else 'rest' end;
      v_reason := format('%s lifting sessions in the last 7 days', v_lifts_7d);
    elsif v_last_date = d - 1 and v_lifts_7d >= 2 then
      v_type := case when v_cardio_7d < 2 then 'cardio' else 'rest' end;
      v_reason := 'lifted yesterday, two sessions already this week';
    else
      v_type := case v_last_type when 'push' then 'pull' when 'pull' then 'legs' else 'push' end;
      v_reason := format('next in rotation after %s on %s', coalesce(v_last_type,'nothing'), coalesce(v_last_date::text,'-'));
    end if;
    v_source := 'proposed';
  end if;

  v_prot  := public.prog_num('protein_floor_g', 170);
  v_fat   := public.prog_num('fat_g_target', 65);
  v_fibre := public.prog_num('fibre_floor_g', 30);
  v_cap   := public.prog_num('overshoot_cap_kcal', 300);
  v_kcal  := case when v_type in ('push','pull','legs')
               then public.prog_num('calorie_target_lift', 2350)
               else public.prog_num('calorie_target_rest', 1850) end;

  -- yesterday's overshoot: compare logged calories with yesterday's own target
  select calories,
         coalesce((select max(case when session_type in ('push','pull','legs') then 'lift' end) from public.sessions s where s.date = d - 1),
                  case when day_type in ('push','pull','legs') then 'lift' else 'rest' end)
    into v_y_kcal, v_y_type from public.daily where date = d - 1;
  if v_y_kcal is not null then
    v_y_target := case when v_y_type = 'lift' then public.prog_num('calorie_target_lift', 2350) else public.prog_num('calorie_target_rest', 1850) end;
    v_over := greatest(0, v_y_kcal - v_y_target);
    v_corr := least(v_over, v_cap);      -- capped; the remainder is written off, never carried
  end if;

  v_carb := greatest(100, round((v_kcal - v_corr - v_prot * 4 - v_fat * 9) / 4));

  return jsonb_build_object(
    'date', d, 'day_type', v_type, 'source', v_source, 'reason', v_reason,
    'is_lifting', v_type in ('push','pull','legs'),
    'kcal_base', v_kcal, 'overshoot_yesterday', v_over, 'correction', v_corr, 'kcal_target', v_kcal - v_corr,
    'protein_floor_g', v_prot, 'fat_g', v_fat, 'carb_g', v_carb, 'fibre_floor_g', v_fibre,
    'training_time', (select value from public.programme where key = 'training_time'),
    'lifts_last_7d', v_lifts_7d, 'cardio_last_7d', v_cardio_7d,
    'last_session', jsonb_build_object('type', v_last_type, 'date', v_last_date));
end $$;

-- Narrow destructive helper. The Supabase MCP connector blocks bulk DELETE, so
-- recurring destructive jobs are wrapped in a stored procedure the owner
-- approves once and the agent then calls as a normal select.
create or replace function public.delete_session(p_session_id text)
returns integer language plpgsql security definer as $$
declare n int;
begin
  delete from public.workouts where session_id = p_session_id;
  get diagnostics n = row_count;
  delete from public.sessions where session_id = p_session_id;
  return n;
end $$;
