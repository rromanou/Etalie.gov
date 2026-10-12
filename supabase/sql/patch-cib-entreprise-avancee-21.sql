-- ============================================================
-- patch-cib-entreprise-avancee-21.sql
-- À exécuter après patch-cib-entreprise-avancee-20.sql. Additif et rejouable.
--
-- CASIER JUDICIAIRE (6 paliers) + PRISON (bloque la connexion).
--
-- HYPOTHÈSES :
--  - 6 paliers, du plus léger au plus grave : Infraction mineure, Délit,
--    Délit grave, Crime, Crime contre l'humanité, Crime contre la
--    Couronne. Les paliers 1 à 4 sont accessibles à tout policier actif,
--    selon son grade (palier max = min(4, floor((grade-1)/4)+1), donc il
--    faut un grade assez élevé pour dresser un Crime). Le palier 5 est
--    réservé aux commissariats de type police_militaire ou
--    police_royale_militaire ("infractions contre l'humanité" demandées
--    pour la police militaire). Le palier 6 est réservé au commissariat
--    de type royal.
--  - Dresser une infraction la juge immédiatement (pas de procès séparé,
--    cohérent avec le reste du site où les constats s'appliquent tout de
--    suite) ; l'amende s'ajoute aux dettes du citoyen (système "dettes"
--    déjà existant, payable via payer_dette) ; la peine de prison
--    s'EMPILE sur une peine déjà en cours (elle commence à la date de
--    fin de la peine actuelle, pas à maintenant, si le citoyen est déjà
--    emprisonné) — c'est la lecture la plus simple de "chevauchement".
--  - Annulation : réservée au Directeur du commissariat ayant dressé
--    l'infraction, à un superviseur royal, ou à l'administration. Si la
--    peine annulée était celle qui fixait la date de sortie, la date de
--    sortie est recalculée à partir des peines actives restantes.
--  - Prison = connexion bloquée (même mécanisme que ban/kick/maintenance,
--    verifier_acces_connexion()), avec le casier affiché sur l'écran de
--    blocage.
--  - Consultation : le casier judiciaire est partiellement public (type
--    d'infraction, date, statut — cohérent avec "ajoute l'option d'accéder
--    aux casiers judiciaires"), le détail complet (preuves, témoins, lieu,
--    agent) est réservé aux policiers actifs et à l'administration.
-- ============================================================

alter table citoyens add column if not exists emprisonne_jusqua timestamptz;

create or replace function _paliers_infraction()
returns text[] language sql immutable as $$
  select array['Infraction mineure','Délit','Délit grave','Crime','Crime contre l''humanité','Crime contre la Couronne'];
$$;

create or replace function _nom_palier(p_palier int)
returns text language sql immutable as $$ select (_paliers_infraction())[greatest(1, least(6, p_palier))]; $$;

create or replace function _peut_dresser_palier(p_palier int)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_grade int; v_type text;
begin
  select mc.grade, co.type into v_grade, v_type from comisseriats_membres mc join comisseriats co on co.id = mc.comisseriat_id
    where mc.citoyen_id = auth.uid() and mc.statut = 'actif';
  if v_grade is null then return false; end if;
  if p_palier between 1 and 4 then
    return least(4, floor((v_grade - 1) / 4.0) + 1) >= p_palier;
  elsif p_palier = 5 then
    return v_type in ('police_militaire','police_royale_militaire','royal');
  elsif p_palier = 6 then
    return v_type = 'royal';
  end if;
  return false;
end; $$;
grant execute on function _peut_dresser_palier(int) to authenticated;

create table if not exists casier_judiciaire (
  id                 uuid primary key default gen_random_uuid(),
  citoyen_id         uuid not null references auth.users(id),
  agent_id           uuid not null references auth.users(id),
  comisseriat_id     uuid not null references comisseriats(id),
  palier             int not null check (palier between 1 and 6),
  titre              text not null,
  description        text not null,
  date_infraction    timestamptz not null default now(),
  lieu               text,
  preuves            jsonb not null default '[]'::jsonb,
  temoins            text,
  amende             numeric not null default 0 check (amende >= 0),
  duree_prison_jours numeric not null default 0 check (duree_prison_jours >= 0),
  statut             text not null default 'condamne' check (statut in ('condamne','annule')),
  motif_annulation   text,
  peine_debut        timestamptz,
  peine_fin          timestamptz,
  cree_le            timestamptz not null default now()
);
alter table casier_judiciaire enable row level security;
drop policy if exists "Casier : self, agent, policiers actifs, ou admin" on casier_judiciaire;
create policy "Casier : self, agent, policiers actifs, ou admin" on casier_judiciaire for select
  using (citoyen_id = auth.uid() or agent_id = auth.uid() or est_admin_actuel()
    or exists (select 1 from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif'));

create or replace function comisseriat_dresser_infraction(
  p_citoyen_username text, p_palier int, p_titre text, p_description text, p_lieu text default null,
  p_preuves jsonb default '[]'::jsonb, p_temoins text default null, p_amende numeric default 0, p_duree_prison_jours numeric default 0
) returns casier_judiciaire language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid; v_com uuid; v_debut timestamptz; v_fin timestamptz; v_row casier_judiciaire; v_actuel timestamptz;
begin
  if not _peut_dresser_palier(p_palier) then raise exception 'Votre grade ou le type de votre commissariat ne permet pas de dresser ce palier d''infraction.'; end if;
  select comisseriat_id into v_com from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif';
  select id into v_citoyen from citoyens where lower(username) = lower(trim(p_citoyen_username));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  if p_titre is null or char_length(trim(p_titre)) = 0 then raise exception 'Titre requis.'; end if;
  if p_description is null or char_length(trim(p_description)) = 0 then raise exception 'Description requise.'; end if;

  if p_duree_prison_jours > 0 then
    select emprisonne_jusqua into v_actuel from citoyens where id = v_citoyen;
    v_debut := greatest(now(), coalesce(v_actuel, now()));
    v_fin := v_debut + (p_duree_prison_jours || ' days')::interval;
    update citoyens set emprisonne_jusqua = v_fin where id = v_citoyen;
  end if;

  if p_amende > 0 then
    update citoyens set dettes = dettes + p_amende where id = v_citoyen;
  end if;

  insert into casier_judiciaire (citoyen_id, agent_id, comisseriat_id, palier, titre, description, lieu, preuves, temoins,
    amende, duree_prison_jours, peine_debut, peine_fin)
  values (v_citoyen, auth.uid(), v_com, p_palier, trim(p_titre), trim(p_description), p_lieu, coalesce(p_preuves, '[]'::jsonb), p_temoins,
    p_amende, p_duree_prison_jours, v_debut, v_fin)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function comisseriat_dresser_infraction(text, int, text, text, text, jsonb, text, numeric, numeric) to authenticated;

create or replace function comisseriat_annuler_infraction(p_id uuid, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
declare inf casier_judiciaire; v_nouvelle_fin timestamptz;
begin
  select * into inf from casier_judiciaire where id = p_id and statut = 'condamne';
  if inf.id is null then raise exception 'Infraction introuvable ou déjà annulée.'; end if;
  if not (_est_directeur(inf.comisseriat_id) or _est_superviseur_royal() or est_admin_actuel()) then raise exception 'Accès refusé.'; end if;
  if p_motif is null or char_length(trim(p_motif)) = 0 then raise exception 'Motif requis.'; end if;
  update casier_judiciaire set statut = 'annule', motif_annulation = trim(p_motif) where id = p_id;

  if inf.peine_fin is not null and exists (select 1 from citoyens where id = inf.citoyen_id and emprisonne_jusqua = inf.peine_fin) then
    select max(peine_fin) into v_nouvelle_fin from casier_judiciaire where citoyen_id = inf.citoyen_id and statut = 'condamne' and peine_fin is not null;
    update citoyens set emprisonne_jusqua = v_nouvelle_fin where id = inf.citoyen_id;
  end if;
end; $$;
grant execute on function comisseriat_annuler_infraction(uuid, text) to authenticated;

-- Consultation publique (minimale) : accessible à tous les citoyens connectés.
create or replace function casier_judiciaire_public(p_username text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'palier', cj.palier, 'nom_palier', _nom_palier(cj.palier), 'titre', cj.titre, 'date_infraction', cj.date_infraction,
    'statut', cj.statut, 'peine_fin', cj.peine_fin
  ) order by cj.date_infraction desc), '[]'::jsonb)
  from casier_judiciaire cj join citoyens c on c.id = cj.citoyen_id where lower(c.username) = lower(trim(p_username));
$$;
grant execute on function casier_judiciaire_public(text) to authenticated;

-- Détail complet : policiers actifs et administration seulement.
create or replace function casier_judiciaire_complet(p_citoyen_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (est_admin_actuel() or exists (select 1 from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif')) then
    raise exception 'Accès refusé.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', cj.id, 'palier', cj.palier, 'nom_palier', _nom_palier(cj.palier), 'titre', cj.titre, 'description', cj.description,
    'date_infraction', cj.date_infraction, 'lieu', cj.lieu, 'preuves', cj.preuves, 'temoins', cj.temoins,
    'amende', cj.amende, 'duree_prison_jours', cj.duree_prison_jours, 'statut', cj.statut, 'motif_annulation', cj.motif_annulation,
    'peine_debut', cj.peine_debut, 'peine_fin', cj.peine_fin, 'agent', a.username, 'comisseriat', co.nom
  ) order by cj.date_infraction desc) from casier_judiciaire cj join citoyens a on a.id = cj.agent_id join comisseriats co on co.id = cj.comisseriat_id
    where cj.citoyen_id = p_citoyen_id), '[]'::jsonb);
end; $$;
grant execute on function casier_judiciaire_complet(uuid) to authenticated;

-- Pratique côté front-end : éviter un aller-retour pour trouver l'ID avant le détail.
create or replace function casier_judiciaire_complet_par_username(p_username text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from citoyens where lower(username) = lower(trim(p_username));
  if v_id is null then raise exception 'Citoyen introuvable.'; end if;
  return casier_judiciaire_complet(v_id);
end; $$;
grant execute on function casier_judiciaire_complet_par_username(text) to authenticated;

-- ---- Blocage de connexion pendant l'emprisonnement ----
create or replace function verifier_acces_connexion()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c citoyens; v_etat record;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select * into c from citoyens where id = auth.uid();
  if c.compte_banni then
    return jsonb_build_object('ok', false, 'raison', 'banni', 'motif', c.compte_banni_motif);
  end if;
  if c.compte_suspendu_jusqua is not null and c.compte_suspendu_jusqua > now() then
    return jsonb_build_object('ok', false, 'raison', 'suspendu', 'motif', c.compte_suspendu_motif, 'jusqu_a', c.compte_suspendu_jusqua);
  end if;
  if c.emprisonne_jusqua is not null and c.emprisonne_jusqua > now() then
    return jsonb_build_object('ok', false, 'raison', 'emprisonne', 'jusqu_a', c.emprisonne_jusqua, 'casier', casier_judiciaire_public(c.username));
  end if;
  select portail_desactive, portail_message_desactivation into v_etat from parametres_fiscaux where id = 1;
  if v_etat.portail_desactive and not est_admin_actuel() then
    return jsonb_build_object('ok', false, 'raison', 'maintenance', 'message', v_etat.portail_message_desactivation);
  end if;
  return jsonb_build_object('ok', true);
end; $$;
grant execute on function verifier_acces_connexion() to authenticated;
