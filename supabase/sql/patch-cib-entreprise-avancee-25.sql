-- ============================================================
-- patch-cib-entreprise-avancee-25.sql
-- À exécuter après patch-cib-entreprise-avancee-24.sql. Additif et rejouable.
--
-- CARTES DE PAIEMENT (banques publiques) + refonte du paiement du marché
-- public pour exiger un moyen de paiement (carte ou CIB d'envoi).
--
-- HYPOTHÈSES :
--  - Seuls les membres (titulaires d'un compte) d'une banque PUBLIQUE
--    peuvent demander une carte à cette banque — « ceux qui font partie
--    d'une banque publique ».
--  - « La trésorerie publique et privée » = les deux trésoreries du
--    GOUVERNEMENT (tresor_public.solde / solde_prive) — déjà strictement
--    réservées à l'administration partout sur le site ; rien à changer
--    là-dessus, c'était déjà le cas. La vraie demande ici est que les
--    ACHATS DES CITOYENS (ici : le marché public, premier chantier)
--    passent désormais par une carte ou un CIB d'envoi d'entreprise au
--    lieu de débiter directement la trésorerie personnelle.
--  - Carte à emprunt : le taux d'intérêt fixe OU le taux graduel
--    (jour/semaine/mois) sont mutuellement exclusifs, choisis par la
--    banque ; le graduel s'applique à la dette existante (intérêts
--    composés), pas seulement aux nouveaux achats.
--  - Une carte « emprunt » peut être dépensée au-delà de ce que couvre
--    la trésorerie réelle du citoyen (c'est tout l'intérêt d'un
--    emprunt) tant que la dette totale ne dépasse pas le plafond fixé.
--    Les taxes, elles, s'ajoutent aussi à la dette mais SANS intérêt.
--  - Autres méthodes de paiement du site (constats, permis, emprunts
--    classiques, etc.) ne sont PAS retouchées dans cette passe — seul
--    le marché public (le flux d'achat le plus direct) est migré ici,
--    à titre de référence ; les autres suivront dans un patch séparé.
-- ============================================================

-- ============================================================
-- patch-cib-entreprise-avancee-25.sql
-- À exécuter après patch-cib-entreprise-avancee-24.sql. Additif et rejouable.
--
-- CARTES DE PAIEMENT (banques publiques) + refonte du paiement du marché
-- public pour exiger un moyen de paiement (carte ou CIB d'envoi).
--
-- CORRECTION 42P01 :
-- La table cartes_associees est créée avant la politique RLS de cartes
-- qui la référence.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists cartes_config (
  id uuid primary key default gen_random_uuid(),
  banque_id uuid not null references banques_privees(id) on delete cascade,
  type text not null check (type in ('tresorerie','emprunt')),
  jours_expiration int not null default 365,
  prix_premiere numeric not null default 0,
  prix_renouvellement numeric not null default 0,
  age_minimum numeric not null default 0,
  achat_autorise boolean not null default true,
  taux_interet numeric,
  taux_periodique numeric,
  periode_taux text check (periode_taux in ('jour','semaine','mois')),
  montant_max numeric,
  maj_le timestamptz not null default now(),
  unique (banque_id, type)
);
alter table cartes_config enable row level security;
drop policy if exists "Lecture publique des configs de carte" on cartes_config;
create policy "Lecture publique des configs de carte"
on cartes_config for select using (true);

create table if not exists cartes (
  id uuid primary key default gen_random_uuid(),
  banque_id uuid not null references banques_privees(id),
  citoyen_id uuid not null references auth.users(id),
  type text not null check (type in ('tresorerie','emprunt')),
  numero text not null unique,
  nip_hash text not null,
  statut text not null default 'active' check (statut in ('active','expiree','bloquee')),
  date_expiration date not null,
  taux_interet numeric,
  taux_periodique numeric,
  periode_taux text,
  montant_max numeric,
  dette_actuelle numeric not null default 0,
  derniere_application_periodique timestamptz,
  cree_le timestamptz not null default now()
);
alter table cartes enable row level security;

-- Créée AVANT la politique de cartes qui la référence.
create table if not exists cartes_associees (
  id uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null references auth.users(id),
  carte_id uuid not null references cartes(id) on delete cascade,
  nip text not null,
  cree_le timestamptz not null default now(),
  unique (citoyen_id, carte_id)
);
alter table cartes_associees enable row level security;
drop policy if exists "Voir ses propres associations de carte" on cartes_associees;
create policy "Voir ses propres associations de carte"
on cartes_associees for select using (citoyen_id = auth.uid());

-- La politique est créée seulement après cartes_associees.
drop policy if exists "Voir ses cartes ou celles de sa banque" on cartes;
create policy "Voir ses cartes ou celles de sa banque"
on cartes for select
using (
  citoyen_id = auth.uid()
  or est_admin_actuel()
  or exists (
    select 1 from banques_privees b
    where b.id = cartes.banque_id and b.proprietaire_id = auth.uid()
  )
  or exists (
    select 1 from cartes_associees ca
    where ca.carte_id = cartes.id and ca.citoyen_id = auth.uid()
  )
);

create table if not exists cartes_changements (
  id uuid primary key default gen_random_uuid(),
  carte_id uuid not null references cartes(id) on delete cascade,
  taux_interet numeric,
  taux_periodique numeric,
  periode_taux text,
  montant_max numeric,
  statut text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  cree_le timestamptz not null default now()
);
alter table cartes_changements enable row level security;
drop policy if exists "Voir les changements de ses cartes" on cartes_changements;
create policy "Voir les changements de ses cartes"
on cartes_changements for select
using (
  est_admin_actuel()
  or exists (
    select 1 from cartes c
    where c.id = cartes_changements.carte_id and c.citoyen_id = auth.uid()
  )
  or exists (
    select 1 from cartes c
    join banques_privees b on b.id = c.banque_id
    where c.id = cartes_changements.carte_id and b.proprietaire_id = auth.uid()
  )
);

-- ---- Génération ----
create or replace function _generer_numero_carte()
returns text language plpgsql as $$
declare v text;
begin
  loop
    v := lpad(floor(random() * 1000000000000)::text, 12, '0');
    exit when not exists (select 1 from cartes where numero = v);
  end loop;
  return v;
end; $$;

create or replace function _hash_nip(p_nip text)
returns text language sql immutable as $$
  select encode(digest(trim(p_nip), 'sha256'), 'hex');
$$;

-- ---- Configuration ----
create or replace function banque_configurer_carte(
  p_banque_id uuid, p_type text, p_jours_expiration int, p_prix_premiere numeric,
  p_prix_renouvellement numeric, p_age_minimum numeric, p_achat_autorise boolean,
  p_taux_interet numeric default null, p_taux_periodique numeric default null,
  p_periode_taux text default null, p_montant_max numeric default null
) returns cartes_config language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_row cartes_config;
begin
  if p_type not in ('tresorerie','emprunt') then raise exception 'Type de carte invalide.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if b.proprietaire_id <> auth.uid() and not est_admin_actuel() then raise exception 'Réservé au propriétaire de la banque.'; end if;
  if not b.publique then raise exception 'Seules les banques publiques peuvent émettre des cartes.'; end if;
  if p_type = 'emprunt' then
    if p_taux_periodique is not null and p_taux_interet is not null then
      raise exception 'Choisissez soit un taux fixe par dépense, soit un taux graduel — pas les deux.';
    end if;
    if p_taux_periodique is not null and p_periode_taux not in ('jour','semaine','mois') then
      raise exception 'Période de taux invalide.';
    end if;
  end if;
  insert into cartes_config (
    banque_id, type, jours_expiration, prix_premiere, prix_renouvellement,
    age_minimum, achat_autorise, taux_interet, taux_periodique, periode_taux, montant_max
  ) values (
    p_banque_id, p_type, p_jours_expiration, p_prix_premiere, p_prix_renouvellement,
    p_age_minimum, p_achat_autorise, p_taux_interet, p_taux_periodique, p_periode_taux, p_montant_max
  )
  on conflict (banque_id, type) do update set
    jours_expiration = excluded.jours_expiration,
    prix_premiere = excluded.prix_premiere,
    prix_renouvellement = excluded.prix_renouvellement,
    age_minimum = excluded.age_minimum,
    achat_autorise = excluded.achat_autorise,
    taux_interet = excluded.taux_interet,
    taux_periodique = excluded.taux_periodique,
    periode_taux = excluded.periode_taux,
    montant_max = excluded.montant_max,
    maj_le = now()
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function banque_configurer_carte(uuid, text, int, numeric, numeric, numeric, boolean, numeric, numeric, text, numeric) to authenticated;

create or replace function banque_cartes_config(p_banque_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', type, 'jours_expiration', jours_expiration,
    'prix_premiere', prix_premiere, 'prix_renouvellement', prix_renouvellement,
    'age_minimum', age_minimum, 'achat_autorise', achat_autorise,
    'taux_interet', taux_interet, 'taux_periodique', taux_periodique,
    'periode_taux', periode_taux, 'montant_max', montant_max
  )), '[]'::jsonb)
  from cartes_config where banque_id = p_banque_id;
$$;
grant execute on function banque_cartes_config(uuid) to authenticated, anon;

-- ---- Demande de carte ----
create or replace function citoyen_demander_carte(p_banque_id uuid, p_type text, p_nip text)
returns cartes language plpgsql security definer set search_path = public as $$
declare cfg cartes_config; v_naissance date; v_row cartes;
begin
  if p_nip !~ '^[0-9]{6}$' then raise exception 'Le NIP doit comporter exactement 6 chiffres.'; end if;
  if not exists (select 1 from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid()) then
    raise exception 'Réservé aux membres (titulaires d''un compte) de cette banque.';
  end if;
  select * into cfg from cartes_config where banque_id = p_banque_id and type = p_type;
  if cfg.id is null or not cfg.achat_autorise then raise exception 'Cette banque n''offre pas (ou plus) ce type de carte.'; end if;
  select date_naissance into v_naissance from citoyens where id = auth.uid();
  if age_toutouien(v_naissance) < cfg.age_minimum then raise exception 'Âge minimum non atteint (% ans requis).', cfg.age_minimum; end if;
  if exists (select 1 from cartes where banque_id = p_banque_id and citoyen_id = auth.uid() and type = p_type and statut = 'active') then
    raise exception 'Vous avez déjà une carte active de ce type à cette banque.';
  end if;
  if cfg.prix_premiere > 0 then
    if _ma_tresorerie() < cfg.prix_premiere then raise exception 'Trésorerie insuffisante pour les frais d''émission (% R$).', cfg.prix_premiere; end if;
    perform _debiter_ma_tresorerie(cfg.prix_premiere);
    update banques_privees set tresorerie = tresorerie + cfg.prix_premiere where id = p_banque_id;
  end if;
  insert into cartes (
    banque_id, citoyen_id, type, numero, nip_hash, date_expiration,
    taux_interet, taux_periodique, periode_taux, montant_max
  ) values (
    p_banque_id, auth.uid(), p_type, _generer_numero_carte(), _hash_nip(p_nip),
    current_date + cfg.jours_expiration,
    case when p_type = 'emprunt' then cfg.taux_interet end,
    case when p_type = 'emprunt' then cfg.taux_periodique end,
    case when p_type = 'emprunt' then cfg.periode_taux end,
    case when p_type = 'emprunt' then coalesce(cfg.montant_max, 0) end
  ) returning * into v_row;
  return v_row;
end; $$;
grant execute on function citoyen_demander_carte(uuid, text, text) to authenticated;

create or replace function citoyen_renouveler_carte(p_carte_id uuid)
returns cartes language plpgsql security definer set search_path = public as $$
declare c cartes; cfg cartes_config; v_row cartes;
begin
  select * into c from cartes where id = p_carte_id and citoyen_id = auth.uid() for update;
  if c.id is null then raise exception 'Carte introuvable.'; end if;
  select * into cfg from cartes_config where banque_id = c.banque_id and type = c.type;
  if cfg.id is null then raise exception 'Cette banque n''offre plus ce type de carte.'; end if;
  if cfg.prix_renouvellement > 0 then
    if _ma_tresorerie() < cfg.prix_renouvellement then raise exception 'Trésorerie insuffisante pour le renouvellement (% R$).', cfg.prix_renouvellement; end if;
    perform _debiter_ma_tresorerie(cfg.prix_renouvellement);
    update banques_privees set tresorerie = tresorerie + cfg.prix_renouvellement where id = c.banque_id;
  end if;
  update cartes set statut = 'active', date_expiration = current_date + cfg.jours_expiration
  where id = c.id returning * into v_row;
  return v_row;
end; $$;
grant execute on function citoyen_renouveler_carte(uuid) to authenticated;

create or replace function banque_proposer_changement_carte(
  p_carte_id uuid, p_taux_interet numeric, p_taux_periodique numeric,
  p_periode_taux text, p_montant_max numeric
) returns cartes_changements language plpgsql security definer set search_path = public as $$
declare c cartes; v_row cartes_changements;
begin
  select c2.* into c
  from cartes c2 join banques_privees b on b.id = c2.banque_id
  where c2.id = p_carte_id and (b.proprietaire_id = auth.uid() or est_admin_actuel());
  if c.id is null then raise exception 'Carte introuvable ou accès refusé.'; end if;
  if c.type <> 'emprunt' then raise exception 'Réservé aux cartes à emprunt.'; end if;
  if p_taux_periodique is not null and p_taux_interet is not null then raise exception 'Choisissez un seul mode de taux.'; end if;
  if p_taux_periodique is not null and p_periode_taux not in ('jour','semaine','mois') then raise exception 'Période de taux invalide.'; end if;
  insert into cartes_changements (carte_id, taux_interet, taux_periodique, periode_taux, montant_max)
  values (p_carte_id, p_taux_interet, p_taux_periodique, p_periode_taux, p_montant_max)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function banque_proposer_changement_carte(uuid, numeric, numeric, text, numeric) to authenticated;

create or replace function citoyen_traiter_changement_carte(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare ch cartes_changements; c cartes;
begin
  select * into ch from cartes_changements where id = p_id and statut = 'en_attente' for update;
  if ch.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  select * into c from cartes where id = ch.carte_id and citoyen_id = auth.uid();
  if c.id is null then raise exception 'Réservé au titulaire de la carte.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update cartes_changements set statut = p_decision where id = p_id;
  if p_decision = 'acceptee' then
    update cartes set taux_interet = ch.taux_interet, taux_periodique = ch.taux_periodique,
      periode_taux = ch.periode_taux, montant_max = coalesce(ch.montant_max, montant_max)
    where id = c.id;
  end if;
end; $$;
grant execute on function citoyen_traiter_changement_carte(uuid, text) to authenticated;

create or replace function citoyen_associer_carte(p_numero text, p_nip text)
returns void language plpgsql security definer set search_path = public as $$
declare c cartes;
begin
  select * into c from cartes where numero = trim(p_numero);
  if c.id is null then raise exception 'Carte introuvable.'; end if;
  if c.statut <> 'active' or c.date_expiration < current_date then raise exception 'Carte inactive ou expirée.'; end if;
  if c.nip_hash <> _hash_nip(p_nip) then raise exception 'NIP incorrect.'; end if;
  insert into cartes_associees (citoyen_id, carte_id, nip)
  values (auth.uid(), c.id, trim(p_nip))
  on conflict (citoyen_id, carte_id) do update set nip = excluded.nip;
end; $$;
grant execute on function citoyen_associer_carte(text, text) to authenticated;

create or replace function citoyen_dissocier_carte(p_carte_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from cartes_associees where carte_id = p_carte_id and citoyen_id = auth.uid();
end; $$;
grant execute on function citoyen_dissocier_carte(uuid) to authenticated;

create or replace function mes_cartes()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by proprietaire desc, numero), '[]'::jsonb)
  from (
    select true as proprietaire, c.id, c.numero, c.type, c.statut, c.date_expiration,
      c.dette_actuelle, c.montant_max, c.taux_interet, c.taux_periodique,
      c.periode_taux, b.nom as banque, null::text as nip_sauvegarde
    from cartes c join banques_privees b on b.id = c.banque_id
    where c.citoyen_id = auth.uid()
    union all
    select false, c.id, c.numero, c.type, c.statut, c.date_expiration,
      c.dette_actuelle, c.montant_max, c.taux_interet, c.taux_periodique,
      c.periode_taux, b.nom, ca.nip
    from cartes_associees ca join cartes c on c.id = ca.carte_id
    join banques_privees b on b.id = c.banque_id
    where ca.citoyen_id = auth.uid()
  ) x;
$$;
grant execute on function mes_cartes() to authenticated;

create or replace function mes_demandes_changement_carte_recues()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ch.id, 'carte_numero', c.numero, 'titulaire', ct.username,
    'taux_interet', ch.taux_interet, 'taux_periodique', ch.taux_periodique,
    'periode_taux', ch.periode_taux, 'montant_max', ch.montant_max, 'cree_le', ch.cree_le
  ) order by ch.cree_le), '[]'::jsonb)
  from cartes_changements ch
  join cartes c on c.id = ch.carte_id
  join citoyens ct on ct.id = c.citoyen_id
  where ch.statut = 'en_attente' and c.citoyen_id = auth.uid();
$$;
grant execute on function mes_demandes_changement_carte_recues() to authenticated;

create or replace function _appliquer_interet_periodique_carte(p_carte_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c cartes; v_unites int; v_intervalle interval;
begin
  select * into c from cartes where id = p_carte_id for update;
  if c.id is null or c.type <> 'emprunt' or c.taux_periodique is null
     or c.taux_periodique <= 0 or c.dette_actuelle <= 0 then return; end if;
  v_intervalle := case c.periode_taux
    when 'jour' then interval '1 day'
    when 'semaine' then interval '1 week'
    else interval '1 month'
  end;
  v_unites := floor(
    extract(epoch from (now() - coalesce(c.derniere_application_periodique, c.cree_le)))
    / extract(epoch from v_intervalle)
  );
  if v_unites <= 0 then return; end if;
  update cartes
  set dette_actuelle = round(dette_actuelle * power(1 + c.taux_periodique / 100.0, v_unites), 2),
      derniere_application_periodique =
        coalesce(c.derniere_application_periodique, c.cree_le) + (v_unites * v_intervalle)
  where id = c.id;
end; $$;

create or replace function _debiter_carte(
  p_numero text, p_nip text, p_montant_net numeric, p_montant_taxes numeric
) returns void language plpgsql security definer set search_path = public as $$
declare c cartes; v_interet numeric := 0; v_ajout_dette numeric;
begin
  if p_montant_net < 0 or p_montant_taxes < 0 then raise exception 'Montant invalide.'; end if;
  select * into c from cartes where numero = trim(p_numero) for update;
  if c.id is null then raise exception 'Carte introuvable.'; end if;
  if c.citoyen_id <> auth.uid() and not exists (
    select 1 from cartes_associees ca where ca.carte_id = c.id and ca.citoyen_id = auth.uid()
  ) then raise exception 'Cette carte n''est pas associée à votre compte.'; end if;
  if c.statut = 'bloquee' then raise exception 'Carte bloquée.'; end if;
  if c.date_expiration < current_date then
    update cartes set statut = 'expiree' where id = c.id;
    raise exception 'Carte expirée.';
  end if;
  if c.statut <> 'active' then raise exception 'Carte inactive.'; end if;
  if c.nip_hash <> _hash_nip(p_nip) then raise exception 'NIP incorrect.'; end if;

  if c.type = 'tresorerie' then
    if (select tresorerie from citoyens where id = c.citoyen_id) < (p_montant_net + p_montant_taxes) then
      raise exception 'Trésorerie insuffisante sur cette carte.';
    end if;
    update citoyens set tresorerie = tresorerie - (p_montant_net + p_montant_taxes)
    where id = c.citoyen_id;
  else
    perform _appliquer_interet_periodique_carte(c.id);
    select * into c from cartes where id = c.id;
    if c.taux_interet is not null and c.taux_interet > 0 then
      v_interet := round(p_montant_net * c.taux_interet / 100.0, 2);
    end if;
    v_ajout_dette := p_montant_net + v_interet + p_montant_taxes;
    if c.dette_actuelle + v_ajout_dette > coalesce(c.montant_max, 0) then
      raise exception 'Plafond d''emprunt dépassé (disponible : % R$).',
        greatest(0, coalesce(c.montant_max, 0) - c.dette_actuelle);
    end if;
    update cartes set dette_actuelle = dette_actuelle + v_ajout_dette where id = c.id;
  end if;
end; $$;
grant execute on function _debiter_carte(text, text, numeric, numeric) to authenticated;

create or replace function _debiter_moyen_paiement(
  p_moyen text, p_carte_numero text, p_carte_nip text, p_cib text,
  p_montant_net numeric, p_montant_taxes numeric
) returns void language plpgsql security definer set search_path = public as $$
declare v_ent_id uuid;
begin
  if p_moyen = 'carte' then
    if p_carte_numero is null or p_carte_nip is null then raise exception 'Numéro de carte et NIP requis.'; end if;
    perform _debiter_carte(p_carte_numero, p_carte_nip, p_montant_net, p_montant_taxes);
  elsif p_moyen = 'cib' then
    if p_cib is null then raise exception 'CIB d''envoi requis.'; end if;
    select entreprise_id into v_ent_id from entreprises_cib where cib_envoi = trim(p_cib);
    if v_ent_id is null then raise exception 'CIB d''envoi introuvable.'; end if;
    if (select tresorerie from entreprises where id = v_ent_id) < (p_montant_net + p_montant_taxes) then
      raise exception 'Trésorerie de l''entreprise insuffisante.';
    end if;
    update entreprises set tresorerie = tresorerie - (p_montant_net + p_montant_taxes) where id = v_ent_id;
  else
    raise exception 'Moyen de paiement invalide (carte ou cib).';
  end if;
end; $$;
grant execute on function _debiter_moyen_paiement(text, text, text, text, numeric, numeric) to authenticated;

create or replace function marche_acheter(
  p_annonce_id uuid, p_quantite int, p_mode_paiement text, p_moyen text,
  p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns marche_achats language plpgsql security definer set search_path = public as $$
declare
  a marche_annonces; v_cat marche_categories; v_montant_objet numeric;
  v_taxe_tp numeric; v_taxe_tap numeric; v_taxe_tan numeric; v_taxe_tr numeric;
  v_montant_taxes numeric; v_montant_objet_majore numeric; v_total_du_maintenant numeric;
  v_row marche_achats; v_tan numeric; v_autochtone boolean; v_vendeur_tresorerie_id uuid;
begin
  if p_mode_paiement not in ('comptant','albatros') then raise exception 'Mode de paiement invalide.'; end if;
  if p_moyen not in ('carte','cib') then raise exception 'Moyen de paiement invalide (carte ou cib).'; end if;
  select * into a from marche_annonces where id = p_annonce_id and statut = 'active' for update;
  if a.id is null then raise exception 'Annonce introuvable ou retirée.'; end if;
  if p_quantite <= 0 or p_quantite > a.quantite_disponible then
    raise exception 'Quantité indisponible (reste : %).', a.quantite_disponible;
  end if;
  if a.vendeur_id = auth.uid() then raise exception 'Impossible d''acheter sa propre annonce.'; end if;
  if p_mode_paiement = 'albatros' and not a.albatros then
    raise exception 'Le paiement Albatros n''est pas proposé pour cette annonce.';
  end if;

  select * into v_cat from marche_categories where code = a.categorie_tp;
  v_montant_objet := a.prix_unitaire * p_quantite;
  v_taxe_tp := round(v_montant_objet * v_cat.taux / 100.0, 2);
  if a.categorie_tp = 'TP-TAE' and a.importe then
    v_taxe_tp := v_taxe_tp + round(v_montant_objet * 0.10, 2);
  end if;

  if v_cat.taux > 0 then
    v_taxe_tap := 0; v_taxe_tan := 0;
  else
    select taux_tap into v_taxe_tap from provinces_taxation where province = a.province_vente;
    v_taxe_tap := round(v_montant_objet * v_taxe_tap / 100.0, 2);
    v_tan := taux_tan_province(a.province_vente);
    v_taxe_tan := round(v_montant_objet * v_tan / 100.0, 2);
  end if;

  select autochtone into v_autochtone from citoyens where id = auth.uid();
  v_taxe_tr := case when v_autochtone then round(v_montant_objet * 0.0495, 2) else 0 end;
  v_montant_taxes := v_taxe_tp + v_taxe_tap + v_taxe_tan + v_taxe_tr;

  if p_mode_paiement = 'albatros' then
    v_montant_objet_majore := round(v_montant_objet * 1.20, 2);
    v_total_du_maintenant := v_montant_taxes;
    perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, 0, v_total_du_maintenant);
    update tresor_public
    set solde = solde + v_taxe_tp + v_taxe_tap + v_taxe_tan,
        solde_prive = solde_prive + v_taxe_tr
    where id = 1;

    insert into marche_achats (
      annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire,
      montant_objet, taxe_tp, taxe_tap, taxe_tan, taxe_tr, montant_total, mode_paiement
    ) values (
      p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire,
      v_montant_objet, v_taxe_tp, v_taxe_tap, v_taxe_tan, v_taxe_tr,
      v_montant_objet_majore + v_montant_taxes, 'albatros'
    ) returning * into v_row;

    insert into albatros_factures (achat_id, mois_total, montant_mensuel)
    values (v_row.id, a.albatros_mois, round(v_montant_objet_majore / a.albatros_mois, 2));
  else
    v_total_du_maintenant := v_montant_objet + v_montant_taxes;
    perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_montant_objet, v_montant_taxes);
    if a.entreprise_vendeuse_id is not null then
      update entreprises set tresorerie = tresorerie + v_montant_objet where id = a.entreprise_vendeuse_id;
    else
      update citoyens set tresorerie = tresorerie + v_montant_objet where id = a.vendeur_id;
    end if;
    update tresor_public
    set solde = solde + v_taxe_tp + v_taxe_tap + v_taxe_tan,
        solde_prive = solde_prive + v_taxe_tr
    where id = 1;

    insert into marche_achats (
      annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire,
      montant_objet, taxe_tp, taxe_tap, taxe_tan, taxe_tr, montant_total, mode_paiement
    ) values (
      p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire,
      v_montant_objet, v_taxe_tp, v_taxe_tap, v_taxe_tan, v_taxe_tr,
      v_total_du_maintenant, 'comptant'
    ) returning * into v_row;
  end if;

  update marche_annonces
  set quantite_disponible = quantite_disponible - p_quantite
  where id = p_annonce_id;
  return v_row;
end; $$;
grant execute on function marche_acheter(uuid, int, text, text, text, text, text) to authenticated;
