-- =====================================================================
-- which_database.sql — the database says whether it is live or test
-- (17 Nov 2026)
--
-- HOW TO USE: paste this whole file into a NEW, empty query in the
-- Supabase SQL Editor and click Run. Run order 64. Safe to run twice.
-- Registers itself: one paste. The last result is the PASS/FAIL table:
-- every row should say PASS.
--
-- WHAT IT DOES
-- The test environment (a second Supabase project, shop-floor-test) runs
-- the same pages as live. A page picks its database from the address it
-- was opened at; this file is the second lock, in the database itself.
-- 1. which_database() answers 'live' or 'test' to a signed-in login.
--    Every page asks once a login is signed in: a page on the test
--    address stops if the answer isn't 'test', a page on the live
--    address stops if it is. No login can ask (the list of functions
--    that run without a login doesn't change).
-- 2. A database is live unless it has been marked test, by one line
--    run in the SQL Editor of the test project only:
--        select this_is_the_test_database();
--    It refuses, changing nothing, on a database where anything has
--    ever been counted or more than 5 devices have opened the app, so
--    it can't be run on live by mistake. It can't be undone from a
--    page or a login; nothing is deleted.
-- 3. The floor TV has no login, so it reads the same answer from its
--    snapshot: tv_snapshot() gains 'site'. Nothing else it sends
--    changes, and the TV page from before ignores it.
-- On live nothing changes for anyone: which_database() says 'live', and
-- the pages that ask arrive with the first monthly release (Tue 8 Dec).
--
-- 4. Two checks that took whichever login the database happened to list
--    first. Building a test project from nothing showed it: on a new
--    project check_test_lane() can pick the Delivery login (Delivery has
--    no sheet counts) and check_arrow_pos() the sales look-up login (it
--    sees no Arrow at all), and both fail though nothing is wrong. On
--    live they pass only because of the order the rows happen to be in.
--    Each now picks a fitting login by name. What they test is unchanged.
--
-- Replaces tv_snapshot from tv_coming.sql, check_test_lane() from
-- direct_counts_off.sql and check_arrow_pos() from arrow_pos.sql, so those
-- files now stop if run again. Ends with check_which_database().
-- =====================================================================

do $$ begin
  if to_regprocedure('public.sql_file_register(text,numeric,text,text,text[])') is not null then
    perform sql_file_register('which_database.sql', 64, 'which_database', 'check_which_database', '{tv_coming.sql,direct_counts_off.sql,arrow_pos.sql}');
  end if;
  if to_regprocedure('public.sql_file_start(text,text[])') is not null then perform sql_file_start('which_database.sql', '{tv_coming.sql,direct_counts_off.sql,arrow_pos.sql}'); end if;
end $$;

do $$ begin
  if to_regprocedure('public.check_tv_coming()') is null then raise exception 'Run tv_coming.sql first. This file builds on it.'; end if;
  if to_regclass('public.device_versions') is null then raise exception 'Run install_log.sql first. This file builds on it.'; end if;
  if to_regprocedure('public.check_checks_clean()') is null then raise exception 'Run checks_clean.sql first. This file comes after it.'; end if;
  if to_regprocedure('public.check_arrow_pos()') is null then raise exception 'Run arrow_pos.sql first. This file builds on it.'; end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. The mark: one row, only on the test project
-- ---------------------------------------------------------------------
create table if not exists database_site (
  one        boolean     primary key default true check (one),      -- at most one row
  site       text        not null check (site = 'test'),
  marked_at  timestamptz not null default now(),
  marked_by  text        not null default current_user
);
alter table database_site enable row level security;                 -- no policy: no login reads or changes it
revoke all on database_site from public, anon, authenticated;

create or replace function which_database() returns text
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from database_site where site = 'test') then 'test' else 'live' end;
$$;
revoke all on function which_database() from public, anon;
grant execute on function which_database() to authenticated;

-- why this database can't be marked test, in words; null when it can
create or replace function site_mark_refusal() returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from progress_events)
      then 'Stop — nothing was changed. Counts have been made in this database, so it is not a new test project. '
           || 'The test mark goes only on the test project (shop-floor-test), before any page opens it.'
    when (select count(distinct device_id) from device_versions) > 5
      then format('Stop — nothing was changed. %s devices have opened the app on this database, so it is not a new test project. '
           || 'The test mark goes only on the test project (shop-floor-test), before any page opens it.',
           (select count(distinct device_id) from device_versions))
  end;
$$;
revoke all on function site_mark_refusal() from public, anon, authenticated;

-- SQL Editor only, on the test project only
create or replace function this_is_the_test_database() returns text
language plpgsql security definer set search_path = public as $$
declare v database_site; why text;
begin
  select * into v from database_site;
  if v.site = 'test' then
    return format('This is already the test database (marked %s). Nothing was changed.',
                  to_char(v.marked_at at time zone 'America/Indiana/Indianapolis', 'FMDD Mon YYYY, FMHH12:MI am'));
  end if;
  why := site_mark_refusal();
  if why is not null then raise exception '%', why; end if;
  insert into database_site (site) values ('test');
  return 'This is now the test database. Pages at the test address (…/shop-floor-test/) will use it; '
         || 'pages at the live address will refuse it.';
end $$;
revoke all on function this_is_the_test_database() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. The floor TV's snapshot: as tv_coming.sql left it, plus 'site'
-- ---------------------------------------------------------------------
create or replace function public.tv_snapshot(p_key text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_hash  text;
  v_today date := local_today();
  v_alert int;
  v_out   jsonb;
  tz      constant text := 'America/Indiana/Indianapolis';
  v_week  date;
  v_first date;
  v_used  int;
begin
  select value #>> '{}' into v_hash from app_settings where key = 'secret_tv_key_hash';
  if v_hash is null or nullif(p_key, '') is null or encode(sha256(convert_to(p_key, 'UTF8')), 'hex') <> v_hash then
    return jsonb_build_object('ok', false,
      'reason', 'This TV link isn''t valid any more. Make a new one on the office page (Setup → TV link) and open it on this screen.');
  end if;
  select coalesce((select (value #>> '{}')::int from app_settings where key = 'arrow_alert_days'), 14) into v_alert;

  with live as (
    select key, name, sort_order from departments where is_live and not log_only
  ),
  r as (      -- every live-department count on real, active, linked jobs
    select j.id as job_id, j.project_id, j.name as job_name, j.delivery_date, j.materials_ordered,
           sp.department, sp.qty_done, sp.qty_required, coalesce(rw.ready, 0) as ready
      from sheet_progress sp
      join live l        on l.key = sp.department
      join sheets s      on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id and w.is_current
      join jobs j        on j.id = w.job_id and j.is_active and not j.is_test and j.monday_item_id is not null
      left join v_ready_to_work rw on rw.sheet_id = sp.sheet_id and rw.department = sp.department
  ),
  per_job as (
    select job_id, project_id, job_name, delivery_date, materials_ordered,
           sum(qty_required - qty_done) as left_n, sum(qty_done) as done_n, sum(qty_required) as total_n
      from r group by job_id, project_id, job_name, delivery_date, materials_ordered
  ),
  on_floor as (select * from per_job where left_n > 0),
  per_dept as (
    select l.key, l.name, l.sort_order,
           coalesce(sum(r.qty_required - r.qty_done), 0) as left_n,
           coalesce(sum(r.ready), 0) as ready_n,
           count(distinct r.job_id) filter (where r.qty_done < r.qty_required) as jobs_n
      from live l left join r on r.department = l.key
     group by l.key, l.name, l.sort_order
  ),
  open_flags as (
    select f.job_id, f.level, f.note, f.department, d.name as department_name, j.project_id, j.name as job_name
      from flags f join jobs j on j.id = f.job_id
      left join departments d on d.key = f.department
     where f.cleared_at is null and not f.is_test and j.is_active
       and (f.department is null or f.department in (select key from live))
  ),
  tbl as (      -- still worked out: the attention list's materials line comes from it
    select o.*, (o.delivery_date - v_today) as days
      from on_floor o
     order by o.delivery_date nulls last, o.project_id
     limit 15
  ),
  attention as (
    select 1 as ord, p.raised_at as at,
           left(format('%s%s · %s: %s', j.project_id, coalesce(' sheet ' || p.sheet_number, ''), d.name, p.body), 160) as text,
           'stopped' as kind
      from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
     where p.status = 'open' and p.work_stopped and not p.is_test and j.is_active
       and p.department in (select key from live)
    union all
    select 2, o.sent_at,
           format('%s at Arrow %s days — %s', j.project_id, v_today - o.sent_on,
                  coalesce(o.description, 'sheet' || case when cardinality(o.sheet_numbers) = 1 then ' ' else 's ' end
                                          || array_to_string(o.sheet_numbers, ', '))),
           'arrow'
      from outside_jobs o join jobs j on j.id = o.job_id
     where o.returned_on is null and o.voided_at is null and not o.is_test and not coalesce(o.waiting, false)
       and v_today - o.sent_on > v_alert
    union all
    select 3, null, format('%s — materials not marked ordered in Monday, due in %s days', t.project_id, t.days), 'materials'
      from tbl t where not t.materials_ordered and t.days <= 14
  )
  select jsonb_build_object(
    'ok', true,
    'site', which_database(),          -- which_database.sql (17 Nov): the floor TV's second lock
    'generated_at', now(),
    'today', v_today,
    'arrow_alert_days', v_alert,
    'live', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'name', name, 'left', left_n, 'ready', ready_n, 'jobs', jobs_n)
                                       order by sort_order) from per_dept), '[]'::jsonb),
    'donut', jsonb_build_object(
       'finished', (select coalesce(sum(qty_done), 0) from r where job_id in (select job_id from on_floor)),
       'ready',    (select coalesce(sum(ready), 0) from r where job_id in (select job_id from on_floor)),
       'total',    (select coalesce(sum(qty_required), 0) from r where job_id in (select job_id from on_floor))),
    'critical', coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'job_name', job_name, 'note', note,
                                                              'department', department_name) order by project_id)
                            from open_flags where level = 'critical'), '[]'::jsonb),
    'attention', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text) order by ord, at nulls last)
                             from attention), '[]'::jsonb)
  ) into v_out;

  -- ---- tv_pace.sql: pace, work stopped, going out ----
  v_week := pace_week(now());
  select min(week_start) into v_first from v_pace_done;
  v_used := case when v_first is null then 0
                 else least(4, greatest((v_week - greatest(v_first, v_week - 28)) / 7, 0)) end;

  v_out := v_out || jsonb_build_object(
    'version', 4,
    'pace_weeks', v_used,
    'pace', coalesce((
      with done as (
        select department,
               sum(main) filter (where week_start = v_week) as this_week,
               sum(main) filter (where week_start >= v_week - 7 * v_used and week_start < v_week) as before
          from v_pace_done where week_start >= v_week - 28
         group by department)
      select jsonb_agg(jsonb_build_object(
               'key', d.key, 'name', d.name,
               'measure', case when d.key in ('metal', 'full_custom', 'metal_paint') then 'pieces' else 'sqft' end,
               'this_week', round(coalesce(x.this_week, 0), 1),
               'usual', case when v_used > 0 then round(coalesce(x.before, 0) / v_used, 1) end,
               'days', to_jsonb(s.days)) order by d.sort_order)
        from departments d
        left join done x on x.department = d.key
        left join v_pace_schedules s on s.department = d.key
       where d.is_live and not d.log_only), '[]'::jsonb),

    'stopped', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', j.project_id, 'job_name', j.name, 'sheet_number', p.sheet_number,
                                          'department', d.name, 'body', left(p.body, 200)) order by p.raised_at)
        from problems p join jobs j on j.id = p.job_id join departments d on d.key = p.department
       where p.status = 'open' and p.work_stopped and not p.is_test and not j.is_test and j.is_active
         and d.is_live and not d.log_only), '[]'::jsonb),

    'trips', coalesce((
      select jsonb_agg(jsonb_build_object('kind', t.kind, 'project_id', t.project_id, 'job_name', t.job_name,
                                          'date', t.on_day, 'time', t.at_time, 'ready', t.grp = 2, 'done_at', t.done_at)
                       order by t.on_day, t.grp, t.sort_at)
        from (select * from (select l.kind, j.project_id, j.name as job_name,
                     case when l.completed_at is not null then 0 when l.kind in ('delivery', 'dock') then 1 else 2 end as grp,
                     case when l.completed_at is not null then (l.completed_at at time zone tz)::date
                          when l.kind in ('delivery', 'dock') then (l.scheduled_for at time zone tz)::date
                          else v_today end as on_day,
                     case when l.completed_at is null and l.kind in ('delivery', 'dock') then to_char(l.scheduled_for at time zone tz, 'FMHH12:MI') end as at_time,
                     case when l.completed_at is not null then to_char(l.completed_at at time zone tz, 'FMHH12:MI') end as done_at,
                     coalesce(l.completed_at, l.scheduled_for, l.ready_at) as sort_at
                from loadouts l join jobs j on j.id = l.job_id
               where l.voided_at is null and not l.is_test and not j.is_test
                 and (   (l.completed_at is not null and (l.completed_at at time zone tz)::date = v_today)
                      or (l.completed_at is null and l.kind in ('delivery', 'dock') and l.scheduled_for is not null
                          and (l.scheduled_for at time zone tz)::date between v_today and v_today + 6)
                      or (l.completed_at is null and l.kind not in ('delivery', 'dock') and l.pickup_steps and l.ready_at is not null))

               union all
               select 'delivery', coalesce(j.project_id, 'Task'), left(coalesce(nullif(k.for_text, '') || ': ', '') || k.what, 80),
                      1, (k.scheduled_for at time zone tz)::date, to_char(k.scheduled_for at time zone tz, 'FMHH12:MI'), null, k.scheduled_for
                 from delivery_tasks k left join jobs j on j.id = k.job_id
                where k.voided_at is null and k.done_at is null and not k.is_test and not coalesce(j.is_test, false)
                  and (k.scheduled_for at time zone tz)::date between v_today and v_today + 6) u
               order by on_day, grp, sort_at
               limit 12) t), '[]'::jsonb),

    -- tv_photos.sql: in its new home. The gate's rows in round order; no image data here.
    'home', coalesce((
      select jsonb_agg(jsonb_build_object('id', h.photo_id, 'project_id', h.project_id, 'delivered_on', h.delivered_on,
                                          'tables', h.tables) order by h.ord)
        from tv_home_pictures() h), '[]'::jsonb),

    -- tv_coming.sql: coming up. The next 10 jobs on the floor by Monday's delivery date,
    -- today or later: the PROJ number, the job's name and the date, nothing else.
    'coming', coalesce((
      select jsonb_agg(jsonb_build_object('project_id', c.project_id, 'job_name', c.name, 'delivery_date', c.delivery_date)
                       order by c.delivery_date, c.project_id)
        from (select j.project_id, j.name, j.delivery_date
                from jobs j
               where j.is_active and not j.is_test and j.monday_item_id is not null
                 and j.delivery_date is not null and j.delivery_date >= v_today
               order by j.delivery_date, j.project_id
               limit 10) c), '[]'::jsonb)
  );
  return v_out;
end $function$;
revoke all on function tv_snapshot(text) from public;
grant execute on function tv_snapshot(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Two checks that took whichever login came first: each picks a fitting
--    login by name (as direct_counts_off.sql and arrow_pos.sql left them
--    otherwise, word for word)
-- ---------------------------------------------------------------------
create or replace function check_test_lane()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test
declare
  tst     uuid;
  sup     uuid;
  sup_dept text;
  v_real  uuid;
  v_wo    uuid;
  s1      uuid;
  v_test  uuid;
  v_copy  jsonb;
  n       int;
  ok      boolean;
  msg     text;
  v_all   text[] := array['milling','cnc','sanding','finishing','full_custom','metal','assembly_qc'];
begin
  -- clear anything left by an interrupted earlier run
  delete from jobs where project_id like 'TEST-LANECHECK%' or project_id = 'LANECHECK';

  step := 1; check_name := 'A Test Supervisor login exists and owns all seven departments';
  select id into tst from profiles where is_test and role = 'supervisor' and active and departments @> v_all limit 1;
  if tst is null then
    result := 'FAIL';
    if_it_failed := 'Create the login in Authentication → Users, then run: select set_person(''<its email>'', ''Test Supervisor'', ''supervisor'', ''{milling,cnc,sanding,finishing,full_custom,metal,assembly_qc}'', true);';
    return next; return;
  end if;
  result := 'PASS'; if_it_failed := null; return next;

  select id, departments[1] into sup, sup_dept from profiles          -- which_database.sql (17 Nov): one whose first department counts sheets, by name
   where role = 'supervisor' and active and not is_test and not look_up and array_length(departments, 1) > 0
     and not exists (select 1 from departments d where d.key = profiles.departments[1] and d.log_only)
   order by full_name limit 1;

  -- a throwaway real job: two departments on one sheet, one of them the real supervisor's
  insert into jobs (monday_item_id, project_id, name, is_active)
    values (-999998, 'LANECHECK', 'Lane check - safe to delete', true) returning id into v_real;
  insert into work_orders (job_id) values (v_real) returning id into v_wo;
  insert into sheets (work_order_id, sheet_number, qty) values (v_wo, 1, 3) returning id into s1;
  insert into sheet_progress (sheet_id, department, qty_required)
    select s1, d, 3 from unnest(array_remove(array['milling', coalesce(sup_dept,'sanding')], null)) d
    on conflict do nothing;

  step := 2; check_name := 'make_test_job copies a job with every count at zero';
  begin
    v_copy := make_test_job('LANECHECK');
    select id into v_test from jobs where project_id = v_copy->>'project_id';
    select count(*) into n from sheet_progress sp join sheets s on s.id = sp.sheet_id
      join work_orders w on w.id = s.work_order_id where w.job_id = v_test and sp.qty_done = 0;
    ok := v_test is not null and (select is_test from jobs where id = v_test) and n >= 1;
    msg := case when ok then null else 'The copy is missing, not marked as a test job, or has counts.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;
  if not ok then delete from jobs where id in (v_real, v_test); return; end if;

  -- ---- as the Test Supervisor ----
  perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);

  step := 3; check_name := 'The Test Supervisor can count on a test job';
  begin
    execute 'set local role authenticated';
    -- through set_count(), as the tablet does (21 Oct: the direct route is closed)
    perform set_count((select sp.id from sheet_progress sp
                        where sp.department = 'milling' and sp.sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test)
                        limit 1), 2);
    select count(*) into n from sheet_progress sp
     where sp.department = 'milling' and sp.qty_done = 2
       and sp.sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test);
    execute 'reset role';
    ok := (n = 1); msg := case when ok then null else 'The count wasn''t saved.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  step := 4; check_name := 'That count is recorded under the Test Supervisor';
  select exists (select 1 from progress_events e join sheets s on s.id = e.sheet_id join work_orders w on w.id = s.work_order_id
                  where w.job_id = v_test and e.qty_to = 2 and e.actor = tst) into ok;
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'History is missing, or has the wrong name on it.' end; return next;

  step := 5; check_name := 'The Test Supervisor cannot change a real job';
  begin
    execute 'set local role authenticated';
    update sheet_progress set qty_done = 3 where sheet_id = s1 and department = 'milling';
    get diagnostics n = row_count;
    execute 'reset role';
    ok := (n = 0); msg := case when ok then null else 'A test login changed a REAL count. Do not go further.' end;
  exception when insufficient_privilege then ok := true; msg := null;
  when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  step := 6; check_name := 'The Test Supervisor''s tablet shows test jobs only';
  begin
    execute 'set local role authenticated';
    select count(*) filter (where not is_test) into n from v_floor_sheets;
    execute 'reset role';
    ok := (n = 0); msg := case when ok then null else n || ' real sheets showed on the test tablet.' end;
  exception when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

  -- ---- as a real supervisor ----
  step := 7; check_name := 'A real supervisor cannot see test jobs';
  if sup is null then
    result := 'FAIL'; if_it_failed := 'No real supervisor login exists to test with.'; return next;
  else
    perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select (select count(*) from jobs where is_test) + (select count(*) from v_floor_sheets where is_test) into n;
      execute 'reset role';
      ok := (n = 0); msg := case when ok then null else 'A real supervisor can see test jobs.' end;
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

    step := 8; check_name := 'A real supervisor cannot change a test job';
    begin
      execute 'set local role authenticated';
      update sheet_progress set qty_done = 1
       where sheet_id in (select s.id from sheets s join work_orders w on w.id = s.work_order_id where w.job_id = v_test);
      get diagnostics n = row_count;
      execute 'reset role';
      ok := (n = 0); msg := case when ok then null else 'A real supervisor changed a test count.' end;
    exception when insufficient_privilege then ok := true; msg := null;
    when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;

    step := 9; check_name := 'A real supervisor can still count on a real job';
    begin
      execute 'set local role authenticated';
      perform set_count((select id from sheet_progress where sheet_id = s1 and department = sup_dept), 1);   -- 21 Oct: through set_count()
      select count(*) into n from sheet_progress where sheet_id = s1 and department = sup_dept and qty_done = 1;
      execute 'reset role';
      ok := (n = 1); msg := case when ok then null else 'The real supervisor''s own count was refused. The tablet would stop working.' end;
    exception when others then ok := false; msg := 'Error: ' || sqlerrm;
    end;
    result := case when ok then 'PASS' else 'FAIL' end; if_it_failed := msg; return next;
  end if;

  perform set_config('request.jwt.claims', '', true);

  step := 10; check_name := 'Test jobs are left out of the handoff list and the Monday check';
  select count(*) into n from jobs where is_test and monday_item_id is not null;
  ok := n = 0 and not exists (select 1 from check_monday_sync() c where c.step = 6 and c.detail like '%TEST-LANECHECK%');
  result := case when ok then 'PASS' else 'FAIL' end;
  if_it_failed := case when ok then null else 'A test job is being treated as a Monday job.' end; return next;

  delete from jobs where id in (v_real, v_test);
end;
$$;
revoke all on function check_test_lane() from public, anon, authenticated;

create or replace function check_arrow_pos()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as each login
declare
  res jsonb := '[]'; mgr uuid; met uuid; san uuid; as_mgr text; as_met text; as_san text;
  j1 uuid; j2 uuid; w1 uuid; w2 uuid; a1 uuid; a2 uuid; a3 uuid; v jsonb; v2 jsonb; cid uuid := gen_random_uuid();
  st arrow_po_settings; n int; ok boolean; msg text; t record; r record; num int;
begin
  -- which_database.sql (17 Nov): each picked by name, and never a look-up login (it sees no Arrow at all)
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;
  select p.id into met from profiles p where p.role = 'supervisor' and p.active and not p.is_test and not p.look_up and 'metal' = any(p.departments) order by p.full_name limit 1;
  select p.id into san from profiles p where p.role = 'supervisor' and p.active and not p.is_test and not p.look_up
     and not (p.departments && arrow_departments()) order by p.full_name limit 1;
  if mgr is null or met is null or san is null then
    res := res || check_row(1, 'A manager, Metal''s supervisor and another supervisor exist to test with', false, 'Set up the logins first.');
    return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
    return;
  end if;
  as_mgr := json_build_object('sub', mgr, 'role', 'authenticated')::text;
  as_met := json_build_object('sub', met, 'role', 'authenticated')::text;
  as_san := json_build_object('sub', san, 'role', 'authenticated')::text;

  -- ---- 1. tables locked -----------------------------------------------------
  ok := true;
  for t in select x.tb from unnest(array['public.sheet_arrow_lines', 'public.work_order_arrow', 'public.arrow_po_settings', 'public.arrow_pos']) x(tb) loop
    ok := ok and (select relrowsecurity from pg_class where oid = t.tb::regclass)
             and not has_table_privilege('authenticated', t.tb, 'insert') and not has_table_privilege('authenticated', t.tb, 'update')
             and not has_table_privilege('authenticated', t.tb, 'delete') and not has_table_privilege('anon', t.tb, 'select');
  end loop;
  ok := ok and not has_table_privilege('authenticated', 'public.arrow_po_settings', 'select');
  res := res || check_row(1, 'The four tables have row-level security and no login writes them directly; the PO details are read only through a function', ok,
    'A table can be written directly or read where it shouldn''t. Run arrow_pos.sql again.');

  -- ---- 2. functions need a login --------------------------------------------
  ok := true; msg := null;
  for t in select x.f from unnest(array['set_sheet_arrow(uuid,jsonb)', 'arrow_po_maker()', 'arrow_po_settings_get()', 'set_arrow_po_settings(jsonb)',
         'arrow_item_counts_for(uuid)', 'arrow_po_make(uuid,date,jsonb)', 'arrow_pos_to_file()', 'record_arrow_po_filed(jsonb)']) x(f) loop
    if to_regprocedure('public.' || t.f) is null or has_function_privilege('anon', 'public.' || t.f, 'execute')
       or not has_function_privilege('authenticated', 'public.' || t.f, 'execute') then ok := false; msg := concat_ws(' ', msg, t.f); end if;
  end loop;
  ok := ok and not has_function_privilege('authenticated', 'public.arrow_item_counts(uuid,integer[],jsonb)', 'execute');
  res := res || check_row(2, 'Its functions need a login; the inside helper is closed to logins', ok, coalesce('Missing, or open to no login: ' || msg, 'arrow_item_counts is open to logins.'));

  select * into st from arrow_po_settings;
  begin
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999971, 'PROJ-99971', 'Arrow PO check - undone automatically', true, 'In Production') returning id into j1;
    insert into jobs (monday_item_id, project_id, name, is_active, phase) values (-999972, 'PROJ-99972', 'Arrow PO check 2 - undone automatically', true, 'In Production') returning id into j2;
    insert into work_orders (job_id, is_current) values (j1, true) returning id into w1;
    insert into work_orders (job_id, is_current) values (j2, true) returning id into w2;
    insert into sheets (work_order_id, sheet_number, qty, item_code) values (w1, 1, 15, 'PD-01'), (w2, 1, 2, 'TB-01'), (w2, 2, 1, 'TB-02');
    update arrow_po_settings set issued_by = null, next_number = 9000 where id;

    -- ---- 3. the lines: only a manager saves them, once per work order -----------
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": []}]');
      execute 'reset role'; ok := false; msg := 'Metal''s supervisor saved Arrow lines.';
    exception when insufficient_privilege then execute 'reset role'; ok := true;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": [{"qty": 15, "base": "JESS", "description": "Pedestal Base, Round Disc, 3.5\" Post", "pd_color": "Stardust Silver", "arrow_color": "RAL 9006 White Aluminum"}]}]');
      v2 := set_sheet_arrow(w1, '[{"sheet_number": 1, "arrow": []}]');
      v := set_sheet_arrow(w2, '[{"sheet_number": 1, "arrow": [{"qty": 4, "base": "DAN", "description": "Angled Post Leg", "pd_color": "Denim Black", "arrow_color": "PCU90229 Denim Black"}, {"qty": 2, "base": "BEN", "description": "Inverted Trapezoid Leg", "pd_color": "Bronze", "arrow_color": "38/60080 Bronze"}]}, {"sheet_number": 2, "arrow": []}]');
      execute 'reset role';
      ok := ok and (v2 ->> 'already')::boolean and (select count(*) from sheet_arrow_lines where work_order_id in (w1, w2)) = 3;
      if not ok and msg is null then msg := 'The lines weren''t saved once each: ' || v2::text; end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(3, 'Only a manager saves a work order''s Arrow lines, and only once (a resend changes nothing)', ok, msg);

    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j1, '{1}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a1;
    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j2, '{1}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a2;
    insert into outside_jobs (job_id, sheet_numbers, service, department, sent_on, waiting, queued_on, queued_by_name, sent_by_name)
      values (j2, '{2}', 'powdercoat', 'metal', local_today(), true, local_today(), 'Check', 'Check') returning id into a3;

    -- ---- 4. details first; a supervisor can't set them; the number never goes back ---------
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v := arrow_po_make(cid, null, jsonb_build_array(jsonb_build_object('id', a2)));
      execute 'reset role'; ok := false; msg := 'A PO was made with no issuer filled in.';
    exception when others then execute 'reset role'; ok := sqlerrm like '%PO details%'; msg := 'Unexpected: ' || sqlerrm; end;
    begin
      execute 'set local role authenticated';
      v := set_arrow_po_settings('{"issued_by": "X"}');
      execute 'reset role'; ok := false; msg := 'Metal''s supervisor set the PO details.';
    exception when insufficient_privilege then execute 'reset role';
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := set_arrow_po_settings('{"issued_by": "Check Issuer", "phone": "000", "email": "check@example.com", "tax_line": "Check line", "next_number": 9000}');
      execute 'reset role';
      ok := ok and (select issued_by from arrow_po_settings) = 'Check Issuer' and (select count(*) from outside_jobs where id in (a1, a2, a3) and waiting) = 3;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(4, 'No PO until the office fills in the details (nothing is marked gone); only a manager fills them in', ok, msg);

    -- ---- 5. a PO across two jobs: 7 of 15 pedestals (a run), and the other job whole ----
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v := arrow_po_make(cid, null, jsonb_build_array(
             jsonb_build_object('id', a1, 'lines', jsonb_build_array(jsonb_build_object('sheet', 1, 'pos', 1, 'qty', 7))),
             jsonb_build_object('id', a2), jsonb_build_object('id', a3)));
      execute 'reset role';
      select * into r from outside_jobs where run_of = a1;
      ok := v ->> 'name' = 'AR-9000' and v ->> 'file_name' = 'AR-9000(99971-1,99972).pdf'
        and r.id is not null and not r.waiting and r.po_id = (v ->> 'id')::uuid and r.arrow_qty = '[{"sheet": 1, "pos": 1, "qty": 7}]'::jsonb
        and (select waiting and arrow_qty = '[{"sheet": 1, "pos": 1, "qty": 8}]'::jsonb and po_id is null from outside_jobs where id = a1)
        and (select count(*) from outside_jobs where id in (a2, a3) and not waiting and po_id = (v ->> 'id')::uuid) = 2;
      msg := 'The PO, its file name or the runs are wrong: ' || left(v::text, 300);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(5, 'One PO across jobs: 7 of 15 go as a run of their own, 8 stay waiting; the file is named AR-n(99971-1,99972)', ok, msg);

    -- ---- 6. the lines as printed: Denim Black first, then Stardust Silver; an item without lines by item, blanks for a pen ---
    ok := jsonb_array_length(v -> 'lines') = 4
      and v #>> '{lines,0,pd_color}' = 'Denim Black' and (v #>> '{lines,0,qty}')::int = 4 and v #>> '{lines,0,project}' = 'PROJ-99972'
      and v #>> '{lines,1,pd_color}' = 'Stardust Silver' and (v #>> '{lines,1,qty}')::int = 7 and v #>> '{lines,1,base}' = 'JESS'
      and v #>> '{lines,2,pd_color}' = 'Bronze' and (v #>> '{lines,2,qty}')::int = 2
      and v #>> '{lines,3,pd_color}' = '' and v #>> '{lines,3,description}' = 'Item TB-02 (sheet 2)' and v #> '{lines,3,qty}' = 'null'::jsonb
      and v #>> '{header,issued_by}' = 'Check Issuer' and v #>> '{header,date_required}' = to_char(local_today() + 7, 'YYYY-MM-DD');
    res := res || check_row(6, 'The lines: grouped by colour (Denim Black, Stardust Silver, the rest, Custom, then blanks), merged, as the upload file spelled them', ok,
      'The lines are in the wrong order or wrong: ' || left((v -> 'lines')::text, 400));

    -- ---- 7. sent twice (no signal): the same PO, nothing doubled; Sanding can't make one ----
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      v2 := arrow_po_make(cid, null, jsonb_build_array(jsonb_build_object('id', a1)));
      execute 'reset role';
      ok := (v2 ->> 'already')::boolean and v2 ->> 'name' = 'AR-9000' and (select count(*) from arrow_pos where client_id = cid) = 1
            and (select count(*) from outside_jobs where run_of = a1) = 1;
      msg := 'A resend made another PO or another run.';
      perform set_config('request.jwt.claims', as_san, true);
      begin
        execute 'set local role authenticated';
        v2 := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1)));
        execute 'reset role'; ok := false; msg := 'A Sanding supervisor made a PO.';
      exception when insufficient_privilege then execute 'reset role'; end;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(7, 'A PO sent twice is one PO; a supervisor outside Metal, Assembly / QC and Delivery can''t make one', ok, msg);

    -- ---- 8. the rest goes on the next PO: the item itself goes, -2; more than left is refused ----
    perform set_config('request.jwt.claims', as_met, true);
    begin
      execute 'set local role authenticated';
      begin
        v2 := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1, 'lines', '[{"sheet": 1, "pos": 1, "qty": 9}]'::jsonb)));
        ok := false; msg := 'More than was left went.';
      exception when others then ok := sqlerrm like 'Only 8 of that line%'; msg := 'Unexpected: ' || sqlerrm; end;
      v2 := arrow_po_make(gen_random_uuid(), null, jsonb_build_array(jsonb_build_object('id', a1)));
      execute 'reset role';
      ok := ok and v2 ->> 'name' = 'AR-9001' and v2 ->> 'file_name' = 'AR-9001(99971-2).pdf'
        and (select not waiting and arrow_qty = '[{"sheet": 1, "pos": 1, "qty": 8}]'::jsonb from outside_jobs where id = a1)
        and (v2 #>> '{lines,0,qty}')::int = 8;
      if not ok and msg like 'Unexpected%' is false then msg := coalesce(msg, 'The second run is wrong: ') || left(v2::text, 200); end if;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(8, 'The rest goes on the next PO (the item itself, named 99971-2); more than is left is refused', ok, msg);

    -- ---- 9. every page sees the runs and their counts; Returned works per run --------
    perform set_config('request.jwt.claims', as_san, true);
    begin
      execute 'set local role authenticated';
      select count(*) into n from v_outside_jobs where job_id = j1 and at_vendor and not waiting;
      select arrow_counts into v from v_outside_jobs where run_of = a1;
      execute 'reset role';
      ok := n = 2 and v = '[{"pos": 1, "sheet": 1, "holds": 7, "total": 15}]'::jsonb;
      perform set_config('request.jwt.claims', as_met, true);
      execute 'set local role authenticated';
      v2 := return_from_arrow((select id from outside_jobs where run_of = a1), null);
      execute 'reset role';
      ok := ok and (select returned_on is not null from outside_jobs where run_of = a1) and (select returned_on is null from outside_jobs where id = a1);
      msg := format('%s runs at Arrow, counts %s', n, v);
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(9, 'Any login sees each run at Arrow with its count (7 of 15); one run comes back on its own', ok, msg);

    -- ---- 10. the office files real POs; a supervisor can't report filing; no login sees anything ----
    perform set_config('request.jwt.claims', as_mgr, true);
    begin
      execute 'set local role authenticated';
      v := arrow_pos_to_file();
      v2 := record_arrow_po_filed((select jsonb_agg(jsonb_build_object('id', id, 'place', p, 'bytes', 1000)) from arrow_pos, unnest(array['onedrive', 'backup']) p where name in ('AR-9000')));
      v2 := arrow_pos_to_file();
      execute 'reset role';
      ok := v @> '[{"name": "AR-9000"}]'::jsonb and not v2 @> '[{"name": "AR-9000"}]'::jsonb and v2 @> '[{"name": "AR-9001"}]'::jsonb;
      msg := 'The office''s list of POs to file is wrong.';
      perform set_config('request.jwt.claims', as_san, true);
      begin execute 'set local role authenticated'; v := record_arrow_po_filed('[]'); execute 'reset role'; ok := false; msg := 'A supervisor reported a filed PO.';
      exception when insufficient_privilege then execute 'reset role'; end;
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      begin select count(*) into n from arrow_pos; exception when insufficient_privilege then n := 0; end;
      execute 'reset role';
      ok := ok and n = 0;
    exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm; end;
    res := res || check_row(10, 'The office files real POs once each; a supervisor can''t report filing; no login sees a PO', ok, msg);

    raise exception 'undo' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- ---- 11. every update and delete names its rows (4 Nov) ---------------------
  -- Supabase's API runs with safeupdate on: an UPDATE or DELETE with no WHERE is refused
  -- ("UPDATE requires a WHERE clause"), even inside a function. The SQL Editor doesn't
  -- have it, so steps 1-10 can't see it. This reads every function's text instead.
  select string_agg(distinct fn, ', ') into msg from (
    select p.oid::regprocedure::text fn, m[1] stmt
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace,
           regexp_matches(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'),
             '(\mupdate\s+[\w.]+(\s+(as\s+)?\w+)?\s+set\s[^;]*;|\mdelete\s+from\s+[\w.]+[^;]*;)', 'gi') m
     where ns.nspname = 'public' and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))) x
   where stmt !~* '\mwhere\M';
  res := res || check_row(11, 'Every function''s update and delete says which rows (Supabase''s API refuses one that doesn''t)',
                          msg is null, 'These would stop with "UPDATE requires a WHERE clause" from a page: ' || msg);
  return query select (x->>'step')::int, x->>'name', x->>'result', x->>'msg' from jsonb_array_elements(res) x;
end $$;
revoke all on function check_arrow_pos() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. The check
-- ---------------------------------------------------------------------
create or replace function check_which_database()
returns table (step int, check_name text, result text, if_it_failed text)
language plpgsql set search_path = public as $$   -- not security definer: it switches role to test as a login and as no login
declare
  res    jsonb := '[]';
  ok     boolean;  msg text;
  marked boolean := exists (select 1 from database_site where site = 'test');
  sup    uuid;  mgr uuid;  v_key text;  v jsonb;  got text;
begin
  select id into sup from profiles where role = 'supervisor' and active order by full_name limit 1;
  select id into mgr from profiles where role in ('manager', 'admin') and active and not is_test order by full_name limit 1;

  -- ---- 1. the answer matches the mark --------------------------------------------------------
  got := which_database();
  res := res || check_row(1, 'The database says what it is (' || coalesce(got, '?') || ')',
    got = case when marked then 'test' else 'live' end and (select count(*) from database_site) <= 1,
    format('which_database() says %s but the mark says %s. Bring this line to Claude in a chat.', got, case when marked then 'test' else 'live' end));

  -- ---- 2. a signed-in login can ask; no login can't; nobody but the SQL Editor can mark ---------
  begin
    ok := true; msg := null;
    if sup is null then ok := false; msg := 'No supervisor login to try it with. Set up the logins first.';
    else
      perform set_config('request.jwt.claims', json_build_object('sub', sup, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      if which_database() is distinct from got then ok := false; msg := 'A signed-in login got a different answer.'; end if;
      begin perform this_is_the_test_database(); ok := false; msg := 'A signed-in login could mark the database.';
      exception when insufficient_privilege then null; end;
      begin insert into database_site (site) values ('test'); ok := false; msg := 'A signed-in login could write the mark.';
      exception when insufficient_privilege then null; end;
      execute 'reset role';
    end if;
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    begin perform which_database(); ok := false; msg := 'No login could ask which database this is.';
    exception when insufficient_privilege then null; end;
    begin delete from database_site where site = 'test'; ok := false; msg := 'No login could clear the mark.';
    exception when insufficient_privilege then null; end;
    execute 'reset role';
  exception when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
  end;
  res := res || check_row(2, 'A signed-in login can ask which database this is; no login can, and only the SQL Editor can mark it', ok, msg);

  -- ---- 3. marking: refused on a used database, never twice -----------------------------------
  begin
    ok := true; msg := null;
    if marked then
      got := this_is_the_test_database();
      ok := got like 'This is already the test database%' and (select count(*) from database_site) = 1;
      msg := 'Marking a second time changed something: ' || got;
    else
      if site_mark_refusal() is null then              -- a new database: stand-in devices show the refusal
        insert into device_versions (device_id, page, version)
          select 'which-db-check-' || g, 'index', 'check' from generate_series(1, 6) g;
      end if;
      begin
        perform this_is_the_test_database();
        ok := false; msg := 'A database with counts or more than 5 devices was marked test.';
      exception when others then
        ok := sqlerrm like 'Stop — nothing was changed.%' and not exists (select 1 from database_site);
        msg := 'The refusal didn''t read as expected: ' || sqlerrm;
      end;
    end if;
    raise exception 'undo' using errcode = 'P0099';
  exception
    when sqlstate 'P0099' then null;
    when others then ok := false; msg := 'Error: ' || sqlerrm;
  end;
  res := res || check_row(3, case when marked then 'Marked test once; marking again changes nothing'
                              else 'Can''t be marked test: it has been used (counts, or more than 5 devices)' end, ok, msg);

  -- ---- 4. the floor TV reads the same answer, and nothing else it gets has changed --------------
  begin
    ok := true; msg := null;
    if mgr is null then ok := false; msg := 'No manager login to make a TV link with. Set up the logins first.';
    else
      perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v_key := new_tv_link()->>'key';
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
      v := tv_snapshot(v_key);
      execute 'reset role';
      ok := (v->>'ok')::boolean and v->>'site' = which_database() and (v->>'version')::int = 4
            and v ? 'coming' and v ? 'home' and v ? 'live' and v ? 'today' and v ? 'generated_at';
      msg := format('The TV''s snapshot says site %s, version %s (keys: %s).', coalesce(v->>'site', 'nothing'), v->>'version',
                    (select string_agg(k, ', ' order by k) from jsonb_object_keys(v) k));
    end if;
    raise exception 'undo' using errcode = 'P0099';
  exception
    when sqlstate 'P0099' then null;
    when others then execute 'reset role'; ok := false; msg := 'Error: ' || sqlerrm;
  end;
  perform set_config('request.jwt.claims', '', true);
  res := res || check_row(4, 'The floor TV''s snapshot says which database it is, and still carries everything it did', ok, msg);

  return query select (r->>'step')::int, r->>'name', r->>'result', r->>'msg' from jsonb_array_elements(res) r;
end $$;
revoke all on function check_which_database() from public, anon, authenticated;

select * from check_which_database();
