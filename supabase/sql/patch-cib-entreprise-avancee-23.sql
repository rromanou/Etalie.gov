-- ============================================================
-- patch-cib-entreprise-avancee-23.sql
-- À exécuter après patch-cib-entreprise-avancee-22.sql. Additif et rejouable.
--
-- ONGLET MILITAIRE + MINIJEU DE TIR 2D (paiement au nombre de zombies tués,
-- prélevé sur la trésorerie PUBLIQUE du gouvernement).
--
-- HYPOTHÈSES (le message original s'est arrêté net sur "ceux qui sont
-- gradés par la", donc l'autorité de grade n'est pas connue) :
--  - 3 grades, du plus bas au plus haut : Recrue militaire, Militaire,
--    Officier. L'enrôlement et la nomination au grade d'Officier sont
--    réservés au gouvernement (cohérent avec le reste du site, où
--    l'armée/la défense est un ministère) ; un Officier peut ensuite
--    promouvoir une Recrue militaire au grade de Militaire (mais pas au
--    grade d'Officier), un peu comme la hiérarchie policière du patch 20
--    mais volontairement plus simple puisque rien de plus détaillé
--    n'a été donné pour l'armée.
--  - Le minijeu : un tir 2D (déplacement + viser/tirer à la souris,
--    vagues de zombies, temps limité) tourne entièrement dans le
--    navigateur ; à la fin, le nombre de zombies tués est envoyé au
--    serveur et payé depuis le trésor PUBLIC. Comme le nombre de tués
--    vient du client (pas moyen de le vérifier serveur sans rejouer la
--    partie côté serveur), deux garde-fous sont en place : un plafond
--    de tués payables par mission (50) et un délai minimum entre deux
--    missions payées (5 minutes) par citoyen — cohérent avec les autres
--    mécaniques anti-abus déjà sur le site (cooldown du TSO, etc.).
--  - Taux par défaut : 5 R$ par zombie tué, réglable par l'administration.
-- ============================================================

alter table citoyens add column if not exists grade_militaire text check (grade_militaire in ('recrue','militaire','officier'));
alter table parametres_fiscaux add column if not exists taux_militaire_par_kill numeric not null default 5;

create or replace function gouv_assigner_grade_militaire(p_username text, p_grade text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_grade is not null and p_grade not in ('recrue','militaire','officier') then raise exception 'Grade invalide.'; end if;
  update citoyens set grade_militaire = p_grade where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_assigner_grade_militaire(text, text) to authenticated;

create or replace function militaire_promouvoir(p_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v_mon_grade text; v_cible citoyens;
begin
  select grade_militaire into v_mon_grade from citoyens where id = auth.uid();
  if v_mon_grade is distinct from 'officier' then raise exception 'Réservé aux Officiers.'; end if;
  select * into v_cible from citoyens where lower(username) = lower(trim(p_username));
  if v_cible.id is null then raise exception 'Citoyen introuvable.'; end if;
  if v_cible.grade_militaire is distinct from 'recrue' then raise exception 'Seule une Recrue militaire peut être promue (par un Officier) au grade de Militaire.'; end if;
  update citoyens set grade_militaire = 'militaire' where id = v_cible.id;
end; $$;
grant execute on function militaire_promouvoir(text) to authenticated;

create or replace function gouv_definir_taux_militaire(p_taux numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_taux < 0 then raise exception 'Taux invalide.'; end if;
  update parametres_fiscaux set taux_militaire_par_kill = p_taux where id = 1;
end; $$;
grant execute on function gouv_definir_taux_militaire(numeric) to authenticated;

create table if not exists militaire_missions (
  id         uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null references auth.users(id),
  debut_le   timestamptz not null default now(),
  fin_le     timestamptz,
  kills      int,
  montant    numeric,
  statut     text not null default 'en_cours' check (statut in ('en_cours','payee'))
);
alter table militaire_missions enable row level security;
drop policy if exists "Voir ses propres missions militaires, ou tout si admin" on militaire_missions;
create policy "Voir ses propres missions militaires, ou tout si admin" on militaire_missions for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function militaire_demarrer_mission()
returns militaire_missions language plpgsql security definer set search_path = public as $$
declare v_grade text; v_derniere timestamptz; v_row militaire_missions;
begin
  select grade_militaire into v_grade from citoyens where id = auth.uid();
  if v_grade is null then raise exception 'Réservé aux membres de l''armée.'; end if;
  select max(debut_le) into v_derniere from militaire_missions where citoyen_id = auth.uid();
  if v_derniere is not null and v_derniere + interval '5 minutes' > now() then
    raise exception 'Prochaine mission disponible dans %.', (v_derniere + interval '5 minutes' - now());
  end if;
  insert into militaire_missions (citoyen_id) values (auth.uid()) returning * into v_row;
  return v_row;
end; $$;
grant execute on function militaire_demarrer_mission() to authenticated;

create or replace function militaire_terminer_mission(p_mission_id uuid, p_kills int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m militaire_missions; v_taux numeric; v_montant numeric; v_kills_payes int;
begin
  select * into m from militaire_missions where id = p_mission_id and citoyen_id = auth.uid() and statut = 'en_cours';
  if m.id is null then raise exception 'Mission introuvable ou déjà terminée.'; end if;
  if p_kills < 0 then raise exception 'Nombre de tués invalide.'; end if;
  v_kills_payes := least(p_kills, 50);
  select taux_militaire_par_kill into v_taux from parametres_fiscaux where id = 1;
  v_montant := v_kills_payes * v_taux;
  update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
  update citoyens set tresorerie = tresorerie + v_montant where id = auth.uid();
  update militaire_missions set fin_le = now(), kills = p_kills, montant = v_montant, statut = 'payee' where id = p_mission_id;
  return jsonb_build_object('kills', p_kills, 'kills_payes', v_kills_payes, 'montant', v_montant);
end; $$;
grant execute on function militaire_terminer_mission(uuid, int) to authenticated;

create or replace function mon_statut_militaire()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('grade_militaire', grade_militaire, 'taux_par_kill', (select taux_militaire_par_kill from parametres_fiscaux where id = 1))
  from citoyens where id = auth.uid();
$$;
grant execute on function mon_statut_militaire() to authenticated;

create or replace function mes_missions_militaires()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'debut_le', debut_le, 'fin_le', fin_le, 'kills', kills, 'montant', montant, 'statut', statut
  ) order by debut_le desc), '[]'::jsonb)
  from militaire_missions where citoyen_id = auth.uid();
$$;
grant execute on function mes_missions_militaires() to authenticated;
