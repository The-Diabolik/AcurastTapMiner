-- Treat older snapshots from another device as a no-op and return the server checkpoint.
create or replace function public.submit_game_score(p_state jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_today date := (v_now at time zone 'UTC')::date;
  v_week date := pg_catalog.date_trunc('week', v_now at time zone 'UTC')::date;
  v_week_start_at timestamptz;
  v_old game_private.secure_game_state%rowtype;
  v_state jsonb;
  v_text text;
  v_claimed_coins numeric;
  v_new_levels integer[] := array[0,0,0]::integer[];
  v_daily_date date;
  v_daily_bonus numeric := 0;
  v_elapsed numeric;
  v_passive_rate numeric;
  v_click_power numeric;
  v_passive_cap numeric;
  v_click_cap numeric;
  v_earn_cap numeric;
  v_upgrade_cost numeric := 0;
  v_base_cost numeric;
  v_level integer;
  v_gross_earned numeric;
  v_pre_week_seconds numeric;
  v_current_week_seconds numeric;
  v_weekly_cap numeric;
  v_weekly numeric;
  v_reason text;
  i integer;
  v_inserted integer := 0;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  insert into game_private.secure_game_state (user_id, week_start, last_sync_at)
  values (v_user, v_week, v_now)
  on conflict (user_id) do nothing;
  get diagnostics v_inserted = row_count;
  select * into v_old from game_private.secure_game_state where user_id = v_user for update;
  if v_inserted = 1 then
    v_state := jsonb_build_object('coins',v_old.coins,'total',v_old.total,'weekly',0,
      'levels',to_jsonb(v_old.levels),'dailyDate','','weekKey',v_week::text,
      'last',floor(extract(epoch from v_now)::numeric*1000)::bigint);
    insert into public.player_progress (user_id,state,updated_at) values (v_user,v_state,v_now)
    on conflict (user_id) do update set state=excluded.state,updated_at=excluded.updated_at;
    return jsonb_build_object('accepted',false,'reason','initialized','state',v_state);
  end if;

  v_week_start_at := v_week::timestamp at time zone 'UTC';
  v_state := jsonb_build_object('coins',v_old.coins,'total',v_old.total,
    'weekly',case when v_old.week_start=v_week then v_old.weekly_earned else 0 end,
    'levels',to_jsonb(v_old.levels),'dailyDate',coalesce(v_old.daily_date::text,''),
    'weekKey',v_week::text,'last',floor(extract(epoch from v_now)::numeric*1000)::bigint);

  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    return jsonb_build_object('accepted',false,'reason','invalid_state','state',v_state);
  end if;
  if coalesce(jsonb_typeof(p_state->'levels'),'') <> 'array' then
    return jsonb_build_object('accepted',false,'reason','invalid_levels','state',v_state);
  end if;
  if jsonb_array_length(p_state->'levels') <> 3 then
    return jsonb_build_object('accepted',false,'reason','invalid_levels','state',v_state);
  end if;
  v_text := p_state->>'coins';
  if coalesce(v_text,'') !~ '^[0-9]{1,12}([.][0-9]{1,6})?$' then
    return jsonb_build_object('accepted',false,'reason','invalid_coins','state',v_state);
  end if;
  v_claimed_coins := v_text::numeric;

  for i in 1..3 loop
    v_text := p_state->'levels'->>(i-1);
    if coalesce(v_text,'') !~ '^[0-9]{1,3}$' then
      v_reason := 'invalid_levels';
      exit;
    end if;
    v_new_levels[i] := v_text::integer;
    if v_new_levels[i] > 100 or v_new_levels[i] < v_old.levels[i] or v_new_levels[i] > v_old.levels[i] + 10 then
      v_reason := 'invalid_level_change';
      exit;
    end if;
  end loop;
  if v_reason = 'invalid_level_change' and (v_new_levels[1] < v_old.levels[1] or v_new_levels[2] < v_old.levels[2] or v_new_levels[3] < v_old.levels[3]) then
    return jsonb_build_object('accepted',true,'reason','stale_snapshot','state',v_state);
  end if;
  if v_reason is not null then
    return jsonb_build_object('accepted',false,'reason',v_reason,'state',v_state);
  end if;

  if (p_state->>'dailyDate') = v_today::text and (v_old.daily_date is null or v_old.daily_date < v_today) then
    v_daily_bonus := 100;
    v_daily_date := v_today;
  else
    v_daily_date := v_old.daily_date;
  end if;

  v_elapsed := greatest(0::numeric,least(28800::numeric,extract(epoch from (v_now-v_old.last_sync_at))::numeric));
  v_passive_rate := greatest(0::numeric,v_old.levels[2]+5*v_old.levels[3]);
  v_click_power := 1+v_old.levels[1];
  v_passive_cap := v_passive_rate*v_elapsed;
  v_click_cap := case when v_elapsed <= 120 then v_click_power*12*v_elapsed else 0 end;
  v_earn_cap := v_passive_cap+v_click_cap+v_daily_bonus;

  for i in 1..3 loop
    v_base_cost := case i when 1 then 25 when 2 then 60 else 300 end;
    if v_new_levels[i] > v_old.levels[i] then
      for v_level in v_old.levels[i]..(v_new_levels[i]-1) loop
        v_upgrade_cost := v_upgrade_cost+floor(v_base_cost*power(1.55::numeric,v_level));
      end loop;
    end if;
  end loop;

  v_gross_earned := v_claimed_coins-v_old.coins+v_upgrade_cost;
  if v_gross_earned < -0.1 then
    return jsonb_build_object('accepted',true,'reason','stale_snapshot','state',v_state);
  end if;
  if v_gross_earned > v_earn_cap+0.1 then
    return jsonb_build_object('accepted',false,'reason','score_rate_exceeded','state',v_state);
  end if;
  v_gross_earned := greatest(0,v_gross_earned);

  v_pre_week_seconds := greatest(0::numeric,least(v_elapsed,extract(epoch from (v_week_start_at-v_old.last_sync_at))::numeric));
  v_current_week_seconds := greatest(0::numeric,v_elapsed-v_pre_week_seconds);
  v_weekly_cap := v_passive_rate*v_current_week_seconds+v_daily_bonus;
  if v_elapsed <= 120 and v_old.last_sync_at >= v_week_start_at then
    v_weekly_cap := v_weekly_cap+v_click_cap;
  end if;
  v_weekly := (case when v_old.week_start=v_week then v_old.weekly_earned else 0 end)+least(v_gross_earned,v_weekly_cap);

  update game_private.secure_game_state set coins=v_claimed_coins,total=v_old.total+v_gross_earned,
    levels=v_new_levels,daily_date=v_daily_date,week_start=v_week,weekly_earned=v_weekly,last_sync_at=v_now
  where user_id=v_user;

  v_state := jsonb_build_object('coins',v_claimed_coins,'total',v_old.total+v_gross_earned,'weekly',v_weekly,
    'levels',to_jsonb(v_new_levels),'dailyDate',coalesce(v_daily_date::text,''),'weekKey',v_week::text,
    'last',floor(extract(epoch from v_now)::numeric*1000)::bigint);
  insert into public.player_progress (user_id,state,updated_at) values (v_user,v_state,v_now)
  on conflict (user_id) do update set state=excluded.state,updated_at=excluded.updated_at;
  insert into public.player_scores (user_id,crystals,updated_at) values (v_user,floor(v_claimed_coins)::bigint,v_now)
  on conflict (user_id) do update set crystals=excluded.crystals,updated_at=excluded.updated_at;
  if floor(v_weekly) >= 1 then
    insert into public.weekly_scores (user_id,week_start,crystals,updated_at,verified)
    values (v_user,v_week,floor(v_weekly)::bigint,v_now,true)
    on conflict (user_id,week_start) do update set crystals=excluded.crystals,updated_at=excluded.updated_at,verified=true;
  end if;
  return jsonb_build_object('accepted',true,'state',v_state,'weekly_earned',floor(v_weekly)::bigint);
end;
$function$;

