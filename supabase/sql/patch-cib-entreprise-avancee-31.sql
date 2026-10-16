-- ============================================================
-- patch-cib-entreprise-avancee-31.sql
-- À exécuter après le patch 30. Additif et rejouable.
--
-- Contenu (éléments de la liste qui manquaient ou étaient incorrects) :
--  1. Bureau de poste : vote clos dès que tout le monde a voté ; prix par
--     mètre converti en km à la facturation ; note SÉPARÉE de l'entreprise
--     de livraison (bureau) et du livreur.
--  2. Notes du marché : une seule note par couple acheteur/vendeur (ou
--     acheteur/livreur, acheteur/bureau), modifiable à chaque rachat.
--  3. Banques : une seule banque publique par civil (garde-fou), quitter une
--     banque privée (le propriétaire/conseiller qui part supprime la banque).
--  4. Banque publique : gestion de l'épargne des membres sans permission
--     (investir en capital, virer vers le membre).
--  5. Albatros sur les achats de capital d'entreprise.
--  6. Casiers : 6 types d'infractions, tous les champs requis, peines
--     purgées une à la fois, modification de peine (h/m/s + motif).
--  7. Recrutement policier : demande au gouvernement (num_CAS.txt), matricule
--     à 7 chiffres choisi par le directeur, permanent et unique.
--  8. Transfert entre commissariats : demande du commissariat d'accueil,
--     accord du commissariat d'origine, puis accord du policier.
--  9. Police royale militaire : peut grader un civil en Recrue militaire.
-- ============================================================

-- ------------------------------------------------------------
-- 1) BUREAU DE POSTE
-- ------------------------------------------------------------
create or replace function _bp_resoudre_vote(p_vote_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v bureau_poste_votes; v_oui int; v_non int;
begin
  select * into v from bureau_poste_votes where id = p_vote_id and statut = 'en_cours';
  if v.id is null then return; end if;
  select count(*) filter (where choix), count(*) filter (where not choix) into v_oui, v_non from bureau_poste_votes_reponses where vote_id = v.id;
  if v_oui > v_non then   -- égalité = non
    update bureau_poste_votes set statut = 'acceptee' where id = v.id;
    if v.poste = 'livreur' then update entreprises set pourcentage_livreurs = v.nouveau_pourcentage where id = v.bureau_poste_id;
    else update entreprises set pourcentage_analystes = v.nouveau_pourcentage where id = v.bureau_poste_id; end if;
  else
    update bureau_poste_votes set statut = 'refusee' where id = v.id;
  end if;
end; $$;

create or replace function bureau_poste_cloturer_votes_expires()
returns integer language plpgsql security definer set search_path = public as $$
declare v record; v_n int := 0;
begin
  for v in select id from bureau_poste_votes where statut = 'en_cours' and expire_le < now() loop
    perform _bp_resoudre_vote(v.id); v_n := v_n + 1;
  end loop;
  return v_n;
end; $$;

create or replace function bureau_poste_voter(p_vote_id uuid, p_choix boolean)
returns void language plpgsql security definer set search_path = public as $$
declare vote_v bureau_poste_votes; v_poste text; v_membres int; v_repondu int;
begin
  select * into vote_v from bureau_poste_votes where id = p_vote_id and statut = 'en_cours';
  if vote_v.id is null then raise exception 'Vote introuvable ou terminé.'; end if;
  if now() > vote_v.expire_le then raise exception 'Le délai de vote est terminé.'; end if;
  select poste_bureau into v_poste from entreprises_membres where entreprise_id = vote_v.bureau_poste_id and citoyen_id = auth.uid();
  if v_poste is distinct from vote_v.poste then raise exception 'Seuls les % de ce bureau de poste peuvent voter.', vote_v.poste; end if;
  insert into bureau_poste_votes_reponses (vote_id, citoyen_id, choix) values (p_vote_id, auth.uid(), p_choix)
    on conflict (vote_id, citoyen_id) do update set choix = p_choix;
  select count(*) into v_membres from entreprises_membres where entreprise_id = vote_v.bureau_poste_id and poste_bureau = vote_v.poste;
  select count(*) into v_repondu from bureau_poste_votes_reponses r
    join entreprises_membres em on em.citoyen_id = r.citoyen_id and em.entreprise_id = vote_v.bureau_poste_id and em.poste_bureau = vote_v.poste
    where r.vote_id = p_vote_id;
  if v_repondu >= v_membres then perform _bp_resoudre_vote(p_vote_id); end if;
end; $$;

-- Facturation : le prix saisi à l'affiliation peut être par mètre ; la distance de l'analyste est en km.
create or replace function bureau_poste_analyser_livraison(p_achat_id uuid, p_distance numeric)
returns void language plpgsql security definer set search_path = public as $$
declare m marche_achats; v_poste text; a bureau_poste_affiliations; v_taux numeric; v_prix_carburant numeric;
  v_montant_facture numeric; v_cout_carburant numeric; v_marge numeric; v_part_livreur numeric; v_part_analyste numeric; v_reste numeric;
begin
  select * into m from marche_achats where id = p_achat_id;
  if m.id is null or m.bureau_poste_id is null then raise exception 'Achat introuvable ou non assigné à un bureau de poste.'; end if;
  if m.statut_livraison <> 'recu' then raise exception 'La livraison doit d''abord être marquée reçue par l''acheteur.'; end if;
  if m.livraison_facturee then raise exception 'Cette livraison a déjà été facturée.'; end if;
  if m.livraison_delai_analyse is not null and now() > m.livraison_delai_analyse then raise exception 'Le délai de 60 jours pour facturer est dépassé.'; end if;
  select poste_bureau into v_poste from entreprises_membres where entreprise_id = m.bureau_poste_id and citoyen_id = auth.uid();
  if v_poste is distinct from 'analyste' then raise exception 'Réservé aux analystes de ce bureau de poste.'; end if;
  if p_distance <= 0 then raise exception 'Distance invalide.'; end if;

  select * into a from bureau_poste_affiliations where bureau_poste_id = m.bureau_poste_id and statut in ('acceptee','dissociee','expiree')
    and (annonce_id = m.annonce_id or entreprise_cible_id = m.entreprise_vendeuse_id) order by cree_le desc limit 1;
  v_taux := coalesce(a.prix_par_unite, 0) * (case when a.unite = 'm' then 1000 else 1 end);   -- R$ par km
  select prix_carburant_km into v_prix_carburant from parametres_fiscaux where id = 1;

  v_montant_facture := round(p_distance * v_taux, 5);
  v_cout_carburant := round(p_distance * v_prix_carburant, 5);
  v_marge := v_montant_facture - v_cout_carburant;

  select pourcentage_livreurs, pourcentage_analystes into v_part_livreur, v_part_analyste from entreprises where id = m.bureau_poste_id;
  v_part_livreur := round(v_marge * coalesce(v_part_livreur, 0) / 100.0, 5);
  v_part_analyste := round(v_marge * coalesce(v_part_analyste, 0) / 100.0, 5);
  v_reste := v_marge - v_part_livreur - v_part_analyste;

  if m.entreprise_vendeuse_id is not null then
    if (select tresorerie from entreprises where id = m.entreprise_vendeuse_id) >= v_montant_facture then
      update entreprises set tresorerie = tresorerie - v_montant_facture where id = m.entreprise_vendeuse_id;
    else
      update entreprises set tresorerie = tresorerie - v_montant_facture, dette_salariale_employes = dette_salariale_employes + v_montant_facture where id = m.entreprise_vendeuse_id;
    end if;
  else
    if (select tresorerie from citoyens where id = m.vendeur_id) >= v_montant_facture then
      update citoyens set tresorerie = tresorerie - v_montant_facture where id = m.vendeur_id;
    else
      update citoyens set tresorerie = tresorerie - v_montant_facture, argent_attendu = argent_attendu + v_montant_facture where id = m.vendeur_id;
      insert into argent_attendu_detail (citoyen_id, montant, description) values (m.vendeur_id, v_montant_facture, 'Frais de livraison — ' || m.titre);
    end if;
  end if;

  update tresor_public set solde = solde + v_cout_carburant where id = 1;
  if m.livreur_id is not null then update citoyens set tresorerie = tresorerie + v_part_livreur where id = m.livreur_id; end if;
  update citoyens set tresorerie = tresorerie + v_part_analyste where id = auth.uid();
  update entreprises set tresorerie = tresorerie + v_reste where id = m.bureau_poste_id;

  update marche_achats set analyste_id = auth.uid(), distance_parcourue = p_distance, prix_livraison_facture = v_montant_facture, livraison_facturee = true where id = p_achat_id;
end; $$;

-- ------------------------------------------------------------
-- 2) NOTES : une seule note par couple, modifiable à chaque rachat
-- ------------------------------------------------------------
alter table marche_achats add column if not exists note_bureau numeric;

create or replace function marche_modifier_evaluation(p_achat_id uuid, p_rapidite numeric, p_aide numeric, p_gentillesse numeric)
returns void language plpgsql security definer set search_path = public as $$
declare a marche_achats; v_cible uuid;
begin
  if p_rapidite not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_aide not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_gentillesse not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then
    raise exception 'Notes invalides (0,5 à 5 par demi-étoile).';
  end if;
  select * into a from marche_achats where id = p_achat_id and acheteur_id = auth.uid() and statut_livraison = 'recu';
  if a.id is null then raise exception 'Achat introuvable ou pas encore marqué reçu.'; end if;
  -- Déjà noté ce vendeur lors d'un achat précédent : on modifie cette note-là.
  select id into v_cible from marche_achats
    where acheteur_id = a.acheteur_id and vendeur_id = a.vendeur_id and note_aide is not null order by cree_le desc limit 1;
  update marche_achats set note_rapidite = p_rapidite, note_aide = p_aide, note_gentillesse = p_gentillesse where id = coalesce(v_cible, p_achat_id);
end; $$;

create or replace function marche_noter_livreur(p_achat_id uuid, p_rapidite numeric, p_etat numeric)
returns void language plpgsql security definer set search_path = public as $$
declare a marche_achats; v_cible uuid;
begin
  if p_rapidite not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_etat not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then
    raise exception 'Notes invalides (0,5 à 5 par demi-étoile).';
  end if;
  select * into a from marche_achats where id = p_achat_id and acheteur_id = auth.uid() and livreur_id is not null;
  if a.id is null then raise exception 'Achat introuvable, ou aucun livreur assigné.'; end if;
  select id into v_cible from marche_achats
    where acheteur_id = a.acheteur_id and livreur_id = a.livreur_id and note_livreur_etat is not null order by cree_le desc limit 1;
  update marche_achats set note_livreur_rapidite = p_rapidite, note_livreur_etat = p_etat where id = coalesce(v_cible, p_achat_id);
end; $$;

-- Note de l'entreprise de livraison (bureau de poste), distincte de celle du livreur.
create or replace function marche_noter_bureau_poste(p_achat_id uuid, p_note numeric)
returns void language plpgsql security definer set search_path = public as $$
declare a marche_achats; v_cible uuid;
begin
  if p_note not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then raise exception 'Note invalide (0,5 à 5 par demi-étoile).'; end if;
  select * into a from marche_achats where id = p_achat_id and acheteur_id = auth.uid() and bureau_poste_id is not null;
  if a.id is null then raise exception 'Achat introuvable, ou aucun bureau de poste assigné.'; end if;
  select id into v_cible from marche_achats
    where acheteur_id = a.acheteur_id and bureau_poste_id = a.bureau_poste_id and note_bureau is not null order by cree_le desc limit 1;
  update marche_achats set note_bureau = p_note where id = coalesce(v_cible, p_achat_id);
end; $$;
grant execute on function marche_noter_bureau_poste(uuid, numeric) to authenticated;

create or replace function note_moyenne_bureau_poste(p_bureau_poste_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then jsonb_build_object('note', null, 'nb_avis', 0)
    else jsonb_build_object('note', round(avg(note_bureau), 2), 'nb_avis', count(*)) end
  from marche_achats where bureau_poste_id = p_bureau_poste_id and note_bureau is not null;
$$;

-- ------------------------------------------------------------
-- 3) BANQUES : une seule banque publique ; quitter une banque privée
-- ------------------------------------------------------------
create or replace function _banque_publique_unique() returns trigger language plpgsql as $$
begin
  if exists (select 1 from banques_privees where id = new.banque_id and publique)
     and exists (select 1 from banques_comptes bc join banques_privees b on b.id = bc.banque_id
                 where bc.citoyen_id = new.citoyen_id and b.publique and bc.banque_id <> new.banque_id) then
    raise exception 'Un civil ne peut appartenir qu''à une seule banque publique.';
  end if;
  return new;
end; $$;
drop trigger if exists trg_banque_publique_unique on banques_comptes;
create trigger trg_banque_publique_unique before insert on banques_comptes
  for each row execute function _banque_publique_unique();

-- Quitter une banque (publique ou privée). Un client récupère son solde.
-- Le propriétaire ou le conseiller qui la quitte entraîne la suppression de la banque
-- (tous les clients sont remboursés).
create or replace function banque_quitter(p_banque_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; bc banques_comptes; r record;
begin
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if b.proprietaire_id = auth.uid() or b.conseiller_id = auth.uid() then
    if exists (select 1 from entreprises_capital_detenteurs where banque_id = p_banque_id and pourcentage > 0) then
      raise exception 'La banque détient encore du capital d''entreprise : retirez-le d''abord.';
    end if;
    for r in select * from banques_comptes where banque_id = p_banque_id loop
      update citoyens set tresorerie = tresorerie + (case when b.type = 'fructification' then _valeur_compte_banque(r.id) else r.solde end) where id = r.citoyen_id;
    end loop;
    update citoyens set tresorerie = tresorerie + coalesce(b.tresorerie, 0) where id = b.proprietaire_id and b.type = 'fructification';
    delete from banques_privees where id = p_banque_id;
  else
    select * into bc from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid() for update;
    if bc.id is null then raise exception 'Vous n''êtes pas client de cette banque.'; end if;
    update citoyens set tresorerie = tresorerie + (case when b.type = 'fructification' then _valeur_compte_banque(bc.id) else bc.solde end) where id = auth.uid();
    if b.type = 'conseil' then update banques_privees set tresorerie = greatest(0, tresorerie - bc.solde) where id = p_banque_id; end if;
    delete from banques_comptes where id = bc.id;
  end if;
end; $$;
grant execute on function banque_quitter(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4) BANQUE PUBLIQUE : gestion de l'épargne des membres sans permission
--    (comme un conseiller financier)
-- ------------------------------------------------------------
create or replace function _solde_compte_membre(p_banque banques_privees, p_compte banques_comptes)
returns numeric language sql stable as $$
  select case when p_banque.type = 'fructification' then _valeur_compte_banque(p_compte.id) else p_compte.solde end;
$$;

create or replace function _debiter_compte_membre(p_banque_id uuid, p_citoyen uuid, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; bc banques_comptes; v_val numeric;
begin
  select * into b from banques_privees where id = p_banque_id;
  select * into bc from banques_comptes where banque_id = p_banque_id and citoyen_id = p_citoyen for update;
  if bc.id is null then raise exception 'Ce citoyen n''a pas de compte dans cette banque.'; end if;
  v_val := _solde_compte_membre(b, bc);
  if v_val < p_montant then raise exception 'Solde du compte insuffisant (% R$).', v_val; end if;
  if b.type = 'fructification' then
    update banques_comptes set solde = v_val - p_montant, inflation_base = inflation_pourcentage() where id = bc.id;
  else
    if b.tresorerie < p_montant then raise exception 'Trésorerie de la banque insuffisante (argent investi en capital).'; end if;
    update banques_comptes set solde = solde - p_montant where id = bc.id;
    update banques_privees set tresorerie = tresorerie - p_montant where id = p_banque_id;
  end if;
end; $$;

create or replace function banque_publique_investir_pour_membre(p_banque_id uuid, p_username text, p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_citoyen uuid; v_ent entreprises; v_cout numeric; v_bonus numeric; v_deja numeric;
begin
  select * into b from banques_privees where id = p_banque_id and publique;
  if b.id is null then raise exception 'Banque publique introuvable.'; end if;
  if not _est_gestionnaire_banque(p_banque_id) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;
  select id into v_citoyen from citoyens where lower(username) = lower(ltrim(trim(p_username), '@'));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  select * into v_ent from entreprises where id = p_entreprise_id and statut = 'acceptee' for update;
  if v_ent.id is null or v_ent.capital_prix_par_centieme is null then raise exception 'Aucune offre en cours pour cette entreprise.'; end if;
  if p_pourcentage < v_ent.capital_min_achat_pct or p_pourcentage > v_ent.capital_en_vente_pct then raise exception 'Pourcentage invalide.'; end if;
  select coalesce(pourcentage, 0) into v_deja from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and citoyen_id = v_citoyen;
  if v_ent.capital_max_par_individu is not null and coalesce(v_deja, 0) + p_pourcentage > v_ent.capital_max_par_individu then
    raise exception 'Maximum par individu dépassé.';
  end if;
  v_cout := (p_pourcentage / 0.01) * v_ent.capital_prix_par_centieme;
  perform _debiter_compte_membre(p_banque_id, v_citoyen, v_cout);

  v_bonus := least(round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2), greatest(v_ent.tresorerie + v_cout, 0));
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout - v_bonus, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage, solde, solde_all_time)
    values (p_entreprise_id, v_citoyen, p_pourcentage, v_bonus, v_bonus)
  on conflict (entreprise_id, citoyen_id) do update set
    pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
    solde = entreprises_capital_detenteurs.solde + v_bonus,
    solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_bonus;
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_maj_pdg_capital(p_entreprise_id);
end; $$;
grant execute on function banque_publique_investir_pour_membre(uuid, text, uuid, numeric) to authenticated;

create or replace function banque_publique_virer_vers_membre(p_banque_id uuid, p_username text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid;
begin
  if not exists (select 1 from banques_privees where id = p_banque_id and publique) then raise exception 'Banque publique introuvable.'; end if;
  if not _est_gestionnaire_banque(p_banque_id) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select id into v_citoyen from citoyens where lower(username) = lower(ltrim(trim(p_username), '@'));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  perform _debiter_compte_membre(p_banque_id, v_citoyen, p_montant);
  update citoyens set tresorerie = tresorerie + p_montant where id = v_citoyen;
end; $$;
grant execute on function banque_publique_virer_vers_membre(uuid, text, numeric) to authenticated;

create or replace function banque_publique_membres(p_banque_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b banques_privees;
begin
  select * into b from banques_privees where id = p_banque_id and publique;
  if b.id is null then raise exception 'Banque publique introuvable.'; end if;
  if not _est_gestionnaire_banque(p_banque_id) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('username', c.username, 'solde', round(_solde_compte_membre(b, bc), 2)) order by c.username)
    from banques_comptes bc join citoyens c on c.id = bc.citoyen_id where bc.banque_id = p_banque_id), '[]'::jsonb);
end; $$;
grant execute on function banque_publique_membres(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5) ALBATROS SUR LES ACHATS DE CAPITAL
-- ------------------------------------------------------------
alter table entreprises add column if not exists capital_albatros boolean not null default false;
alter table entreprises add column if not exists capital_albatros_mois int;

create table if not exists albatros_capital_factures (
  id              uuid primary key default gen_random_uuid(),
  entreprise_id   uuid not null references entreprises(id) on delete cascade,
  acheteur_id     uuid not null references citoyens(id) on delete cascade,
  pourcentage     numeric not null,
  cout_total      numeric not null,
  mois_total      int not null,
  montant_mensuel numeric not null,
  mois_payes      int not null default 1,
  prochain_du     timestamptz not null default (now() + interval '1 month'),
  statut          text not null default 'active' check (statut in ('active','complete')),
  cree_le         timestamptz not null default now()
);
alter table albatros_capital_factures enable row level security;
drop policy if exists "Voir ses factures Albatros capital" on albatros_capital_factures;
create policy "Voir ses factures Albatros capital" on albatros_capital_factures for select
  using (acheteur_id = auth.uid() or est_admin_actuel());

create or replace function entreprise_configurer_capital_albatros(p_entreprise_id uuid, p_actif boolean, p_mois int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid() and role = 'pdg') then
    raise exception 'Réservé au PDG de l''entreprise.';
  end if;
  if p_actif and (p_mois is null or p_mois < 2 or p_mois > 60) then raise exception 'Nombre de mois invalide (2 à 60).'; end if;
  update entreprises set capital_albatros = coalesce(p_actif, false), capital_albatros_mois = case when p_actif then p_mois end where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_configurer_capital_albatros(uuid, boolean, int) to authenticated;

create or replace function entreprise_acheter_capital_albatros(
  p_entreprise_id uuid, p_pourcentage numeric, p_moyen text,
  p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_mensualite numeric; v_deja numeric; v_bonus numeric;
begin
  select * into v_ent from entreprises where id = p_entreprise_id and statut = 'acceptee' for update;
  if v_ent.id is null then raise exception 'Entreprise introuvable.'; end if;
  if not v_ent.capital_albatros then raise exception 'Cette entreprise n''offre pas le programme Albatros sur son capital.'; end if;
  if v_ent.capital_prix_par_centieme is null then raise exception 'Aucune offre en cours.'; end if;
  if p_pourcentage < v_ent.capital_min_achat_pct then raise exception 'Minimum achetable : % %%.', v_ent.capital_min_achat_pct; end if;
  if p_pourcentage > v_ent.capital_en_vente_pct then raise exception 'Il ne reste que % %% en vente.', v_ent.capital_en_vente_pct; end if;
  select coalesce(pourcentage, 0) into v_deja from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_ent.capital_max_par_individu is not null and coalesce(v_deja, 0) + p_pourcentage > v_ent.capital_max_par_individu then
    raise exception 'Maximum par individu dépassé (max : % %%).', v_ent.capital_max_par_individu;
  end if;

  v_cout := (p_pourcentage / 0.01) * v_ent.capital_prix_par_centieme;
  v_mensualite := round(v_cout / v_ent.capital_albatros_mois, 2);
  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_mensualite, 0);

  v_bonus := least(round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2), greatest(v_ent.tresorerie + v_mensualite, 0));
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_mensualite - v_bonus, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage, solde, solde_all_time)
    values (p_entreprise_id, auth.uid(), p_pourcentage, v_bonus, v_bonus)
  on conflict (entreprise_id, citoyen_id) do update set
    pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
    solde = entreprises_capital_detenteurs.solde + v_bonus,
    solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_bonus;
  insert into albatros_capital_factures (entreprise_id, acheteur_id, pourcentage, cout_total, mois_total, montant_mensuel)
    values (p_entreprise_id, auth.uid(), p_pourcentage, v_cout, v_ent.capital_albatros_mois, v_mensualite);
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_maj_pdg_capital(p_entreprise_id);
end; $$;
grant execute on function entreprise_acheter_capital_albatros(uuid, numeric, text, text, text, text) to authenticated;

create or replace function payer_versement_capital_albatros(
  p_facture_id uuid, p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns void language plpgsql security definer set search_path = public as $$
declare f albatros_capital_factures;
begin
  select * into f from albatros_capital_factures where id = p_facture_id and statut = 'active' for update;
  if f.id is null then raise exception 'Facture introuvable ou déjà complétée.'; end if;
  if f.acheteur_id <> auth.uid() then raise exception 'Réservé à l''acheteur.'; end if;
  if f.prochain_du > now() then raise exception 'Le prochain versement n''est pas encore dû (le %).', f.prochain_du; end if;
  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, f.montant_mensuel, 0);
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + f.montant_mensuel where id = f.entreprise_id;
  perform _sans_partage(false);
  update albatros_capital_factures set mois_payes = mois_payes + 1, prochain_du = prochain_du + interval '1 month',
    statut = case when mois_payes + 1 >= mois_total then 'complete' else 'active' end where id = p_facture_id;
  perform _entreprise_regler_dette_employes(f.entreprise_id);
end; $$;
grant execute on function payer_versement_capital_albatros(uuid, text, text, text, text) to authenticated;

create or replace function mes_factures_albatros_capital()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', f.id, 'entreprise', e.nom, 'entreprise_code', e.code, 'pourcentage', f.pourcentage, 'cout_total', f.cout_total,
    'mois_payes', f.mois_payes, 'mois_total', f.mois_total, 'montant_mensuel', f.montant_mensuel,
    'prochain_du', f.prochain_du, 'statut', f.statut) order by f.cree_le desc), '[]'::jsonb)
  from albatros_capital_factures f join entreprises e on e.id = f.entreprise_id where f.acheteur_id = auth.uid();
$$;
grant execute on function mes_factures_albatros_capital() to authenticated;

create or replace function capital_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'entreprises', coalesce((select jsonb_agg(jsonb_build_object(
      'entreprise_id', e.id, 'code', e.code, 'nom', e.nom, 'en_vente_pct', e.capital_en_vente_pct,
      'prix_par_centieme', e.capital_prix_par_centieme, 'min_achat_pct', e.capital_min_achat_pct,
      'max_par_individu', e.capital_max_par_individu, 'description', e.capital_description,
      'albatros', e.capital_albatros, 'albatros_mois', e.capital_albatros_mois) order by e.nom)
      from entreprises e where e.statut = 'acceptee' and e.capital_en_vente_pct > 0 and e.capital_prix_par_centieme is not null), '[]'::jsonb),
    'tiers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'entreprise_id', e.id, 'nom', e.nom, 'vendeur', c.username, 'pourcentage', o.pourcentage,
      'prix_par_dixieme', o.prix_par_dixieme, 'description', o.description) order by o.cree_le desc)
      from capital_offres_tiers o join entreprises e on e.id = o.entreprise_id join citoyens c on c.id = o.vendeur_id
      where e.statut = 'acceptee'), '[]'::jsonb)
  );
$$;

create or replace function entreprise_capital_albatros(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('actif', capital_albatros, 'mois', capital_albatros_mois) from entreprises where id = p_entreprise_id;
$$;
grant execute on function entreprise_capital_albatros(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6) CASIERS JUDICIAIRES : 6 types, champs requis, peines purgées une à la fois
-- ------------------------------------------------------------
create or replace function _paliers_infraction()
returns text[] language sql immutable as $$
  select array['Infraction mineure','Infraction majeure','Infraction perpétuité','Infraction post-mortem',
               'Infraction contre l''humanité','Infraction royale'];
$$;

alter table casier_judiciaire add column if not exists matricule_agent text;
alter table casier_judiciaire add column if not exists matricule_temoin text;
alter table casier_judiciaire add column if not exists numero_comparaison text;
alter table casier_judiciaire add column if not exists prison_comisseriat_id uuid references comisseriats(id) on delete set null;

create table if not exists casier_modifications (
  id               uuid primary key default gen_random_uuid(),
  infraction_id    uuid not null references casier_judiciaire(id) on delete cascade,
  agent_id         uuid not null references citoyens(id),
  matricule_agent  text,
  secondes         numeric not null,
  motif            text not null,
  cree_le          timestamptz not null default now()
);
alter table casier_modifications enable row level security;
drop policy if exists "Voir les modifications de peine (police/admin)" on casier_modifications;
create policy "Voir les modifications de peine (police/admin)" on casier_modifications for select
  using (est_admin_actuel() or exists (select 1 from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif'));

-- Remplace toutes les anciennes versions (évite l'ambiguïté PGRST203).
do $$ declare r record; begin
  for r in select oid::regprocedure as sig from pg_proc where pronamespace = 'public'::regnamespace and proname = 'comisseriat_dresser_infraction' loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

create function comisseriat_dresser_infraction(
  p_citoyen_username text, p_palier int, p_titre text, p_description text,
  p_lieu text, p_date_incident timestamptz,
  p_preuves jsonb default '[]'::jsonb, p_temoins text default null,
  p_matricule_temoin text default null, p_numero_comparaison text default null,
  p_amende numeric default 0, p_duree_prison_jours numeric default 0, p_prison_code text default null
) returns casier_judiciaire language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid; v_com uuid; v_prison uuid; v_debut timestamptz; v_fin timestamptz; v_row casier_judiciaire;
  v_actuel timestamptz; v_mat text; v_jours numeric := coalesce(p_duree_prison_jours, 0);
begin
  if not _peut_dresser_palier(p_palier) then raise exception 'Votre grade ou le type de votre commissariat ne permet pas de dresser ce type d''infraction.'; end if;
  select comisseriat_id, matricule into v_com, v_mat from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif';
  select id into v_citoyen from citoyens where lower(username) = lower(ltrim(trim(p_citoyen_username), '@'));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  if p_titre is null or char_length(trim(p_titre)) = 0 then raise exception 'Titre requis.'; end if;
  if p_description is null or char_length(trim(p_description)) = 0 then raise exception 'Description (rapport) requise.'; end if;
  if p_lieu is null or char_length(trim(p_lieu)) < 5 then raise exception 'Le lieu complet de l''incident est requis.'; end if;
  if p_date_incident is null then raise exception 'La date et l''heure de l''incident sont requises.'; end if;
  if p_date_incident > now() then raise exception 'La date de l''incident ne peut pas être dans le futur.'; end if;
  if p_matricule_temoin is not null and p_matricule_temoin <> '' and not exists (select 1 from matricules_policiers where matricule = p_matricule_temoin) then
    raise exception 'Matricule de l''agent témoin introuvable.';
  end if;

  if p_palier = 1 then
    if v_jours > 0 then raise exception 'Une infraction mineure ne mène pas à la prison (elle mène à un constat/amende).'; end if;
  else
    if p_numero_comparaison is null or char_length(trim(p_numero_comparaison)) = 0 then
      raise exception 'Le numéro de suivi de la comparaison est requis : à partir d''une infraction majeure, une comparaison doit avoir eu lieu et le juge doit avoir criminalisé la personne.';
    end if;
    if p_palier = 3 then v_jours := 36500;
    elsif p_palier in (4, 6) and v_jours <= 36500 then raise exception 'Ce type d''infraction implique plus de 100 ans de prison (plus de 36500 jours).';
    elsif v_jours <= 0 then raise exception 'La durée de prison décidée au tribunal est requise.'; end if;
    if p_prison_code is not null and trim(p_prison_code) <> '' then
      select id into v_prison from comisseriats where upper(code) = upper(trim(p_prison_code));
      if v_prison is null then raise exception 'Prison introuvable (numéro de suivi : %).', p_prison_code; end if;
    else v_prison := v_com; end if;
  end if;

  if v_jours > 0 then
    -- Peines qui se chevauchent : purgées une à la fois, à la suite.
    select emprisonne_jusqua into v_actuel from citoyens where id = v_citoyen;
    v_debut := greatest(now(), coalesce(v_actuel, now()));
    v_fin := v_debut + (v_jours || ' days')::interval;
    update citoyens set emprisonne_jusqua = v_fin where id = v_citoyen;
  end if;
  if coalesce(p_amende, 0) > 0 then update citoyens set dettes = dettes + p_amende where id = v_citoyen; end if;

  insert into casier_judiciaire (citoyen_id, agent_id, comisseriat_id, palier, titre, description, date_infraction, lieu, preuves, temoins,
    amende, duree_prison_jours, peine_debut, peine_fin, matricule_agent, matricule_temoin, numero_comparaison, prison_comisseriat_id)
  values (v_citoyen, auth.uid(), v_com, p_palier, trim(p_titre), trim(p_description), p_date_incident, trim(p_lieu), coalesce(p_preuves, '[]'::jsonb), p_temoins,
    coalesce(p_amende, 0), v_jours, v_debut, v_fin, v_mat, nullif(trim(p_matricule_temoin), ''), nullif(trim(p_numero_comparaison), ''), v_prison)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function comisseriat_dresser_infraction(text, int, text, text, text, timestamptz, jsonb, text, text, text, numeric, numeric, text) to authenticated;

-- Modifier une peine : ajouter ou retirer du temps (secondes, négatif = retirer), motif valable obligatoire.
create or replace function comisseriat_modifier_peine(p_infraction_id uuid, p_secondes numeric, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
declare inf casier_judiciaire; v_mat text; v_fin timestamptz; v_emp timestamptz;
begin
  select * into inf from casier_judiciaire where id = p_infraction_id and statut <> 'annule';
  if inf.id is null then raise exception 'Infraction introuvable ou annulée.'; end if;
  if inf.peine_fin is null then raise exception 'Cette infraction n''a pas de peine de prison à modifier.'; end if;
  if not (est_admin_actuel() or _est_directeur(inf.comisseriat_id) or _peut_dresser_palier(4)) then
    raise exception 'Votre grade ne permet pas de modifier une peine.';
  end if;
  if p_secondes is null or p_secondes = 0 then raise exception 'Indiquez le temps à ajouter ou à retirer (heures, minutes, secondes).'; end if;
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Un motif valable est requis (10 caractères minimum).'; end if;
  select matricule into v_mat from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif';
  v_fin := inf.peine_fin + make_interval(secs => p_secondes);
  if v_fin < coalesce(inf.peine_debut, v_fin) then v_fin := inf.peine_debut; end if;
  update casier_judiciaire set peine_fin = v_fin,
    duree_prison_jours = round(extract(epoch from (v_fin - coalesce(inf.peine_debut, v_fin))) / 86400.0, 6) where id = inf.id;
  -- Le temps total restant du citoyen suit (peines purgées à la suite).
  select emprisonne_jusqua into v_emp from citoyens where id = inf.citoyen_id;
  update citoyens set emprisonne_jusqua = greatest(now(), coalesce(v_emp, now()) + make_interval(secs => p_secondes)) where id = inf.citoyen_id;
  insert into casier_modifications (infraction_id, agent_id, matricule_agent, secondes, motif) values (inf.id, auth.uid(), v_mat, p_secondes, trim(p_motif));
end; $$;
grant execute on function comisseriat_modifier_peine(uuid, numeric, text) to authenticated;

create or replace function casier_judiciaire_complet(p_citoyen_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (est_admin_actuel() or exists (select 1 from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif')) then
    raise exception 'Accès refusé.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', cj.id, 'palier', cj.palier, 'nom_palier', _nom_palier(cj.palier), 'titre', cj.titre, 'description', cj.description,
    'date_infraction', cj.date_infraction, 'lieu', cj.lieu, 'preuves', cj.preuves, 'temoins', cj.temoins,
    'matricule_agent', cj.matricule_agent, 'matricule_temoin', cj.matricule_temoin, 'numero_comparaison', cj.numero_comparaison,
    'prison', pr.nom, 'prison_code', pr.code,
    'amende', cj.amende, 'duree_prison_jours', cj.duree_prison_jours, 'statut', cj.statut, 'motif_annulation', cj.motif_annulation,
    'peine_debut', cj.peine_debut, 'peine_fin', cj.peine_fin, 'agent', a.username, 'comisseriat', co.nom,
    'modifications', coalesce((select jsonb_agg(jsonb_build_object('secondes', mo.secondes, 'motif', mo.motif, 'matricule', mo.matricule_agent, 'cree_le', mo.cree_le) order by mo.cree_le)
                                from casier_modifications mo where mo.infraction_id = cj.id), '[]'::jsonb)
  ) order by cj.date_infraction desc)
  from casier_judiciaire cj join citoyens a on a.id = cj.agent_id join comisseriats co on co.id = cj.comisseriat_id
  left join comisseriats pr on pr.id = cj.prison_comisseriat_id
  where cj.citoyen_id = p_citoyen_id), '[]'::jsonb);
end; $$;

-- Casier montré à la connexion d'une personne incarcérée : complet pour elle-même.
create or replace function casier_judiciaire_public(p_username text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'palier', cj.palier, 'nom_palier', _nom_palier(cj.palier), 'titre', cj.titre, 'date_infraction', cj.date_infraction,
    'statut', cj.statut, 'peine_fin', cj.peine_fin,
    'description', case when c.id = auth.uid() or est_admin_actuel() then cj.description end,
    'lieu', case when c.id = auth.uid() or est_admin_actuel() then cj.lieu end,
    'temoins', case when c.id = auth.uid() or est_admin_actuel() then cj.temoins end,
    'matricule_agent', case when c.id = auth.uid() or est_admin_actuel() then cj.matricule_agent end,
    'numero_comparaison', case when c.id = auth.uid() or est_admin_actuel() then cj.numero_comparaison end,
    'amende', case when c.id = auth.uid() or est_admin_actuel() then cj.amende end,
    'peine_debut', case when c.id = auth.uid() or est_admin_actuel() then cj.peine_debut end,
    'duree_prison_jours', case when c.id = auth.uid() or est_admin_actuel() then cj.duree_prison_jours end
  ) order by cj.date_infraction desc), '[]'::jsonb)
  from casier_judiciaire cj join citoyens c on c.id = cj.citoyen_id where lower(c.username) = lower(trim(p_username));
$$;

-- ------------------------------------------------------------
-- 7) RECRUTEMENT POLICIER : demande au gouvernement (num_CAS.txt)
--    Le directeur choisit un matricule de 7 chiffres, permanent et unique.
-- ------------------------------------------------------------
create table if not exists comisseriats_recrutements (
  id              uuid primary key default gen_random_uuid(),
  comisseriat_id  uuid not null references comisseriats(id) on delete cascade,
  citoyen_id      uuid not null references citoyens(id) on delete cascade,
  demandeur_id    uuid not null references citoyens(id),
  matricule       text,
  statut          text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  cree_le         timestamptz not null default now()
);
alter table comisseriats_recrutements enable row level security;
drop policy if exists "Voir ses demandes de recrutement" on comisseriats_recrutements;
create policy "Voir ses demandes de recrutement" on comisseriats_recrutements for select
  using (est_admin_actuel() or demandeur_id = auth.uid());

drop function if exists comisseriat_embaucher(uuid, text);
create or replace function comisseriat_embaucher(p_comisseriat_id uuid, p_username text, p_matricule text default null)
returns comisseriats_recrutements language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid; v_existant text; v_row comisseriats_recrutements;
begin
  if not (_est_directeur(p_comisseriat_id) or _est_superviseur_royal() or est_admin_actuel()) then raise exception 'Réservé au Directeur du commissariat.'; end if;
  select id into v_citoyen from citoyens where lower(username) = lower(ltrim(trim(p_username), '@'));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  if exists (select 1 from comisseriats_membres where citoyen_id = v_citoyen and statut = 'actif') then
    raise exception 'Ce citoyen occupe déjà un poste actif dans un commissariat.';
  end if;
  if exists (select 1 from comisseriats_recrutements where citoyen_id = v_citoyen and statut = 'en_attente') then
    raise exception 'Une demande de recrutement est déjà en attente pour ce citoyen.';
  end if;
  select matricule into v_existant from matricules_policiers where citoyen_id = v_citoyen;
  if v_existant is not null then
    p_matricule := v_existant;   -- le matricule est attribué à vie et ne change jamais
  elsif p_matricule is not null and trim(p_matricule) <> '' then
    if p_matricule !~ '^[0-9]{7}$' then raise exception 'Le matricule doit comporter exactement 7 chiffres.'; end if;
    if exists (select 1 from matricules_policiers where matricule = p_matricule) then raise exception 'Ce matricule est déjà attribué à une autre personne.'; end if;
  else
    p_matricule := null;
  end if;
  insert into comisseriats_recrutements (comisseriat_id, citoyen_id, demandeur_id, matricule)
    values (p_comisseriat_id, v_citoyen, auth.uid(), p_matricule) returning * into v_row;
  return v_row;
end; $$;
grant execute on function comisseriat_embaucher(uuid, text, text) to authenticated;

create or replace function gouv_liste_recrutements()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', r.id, 'username', c.username, 'nom', c.nom_complet, 'cas_encrypte', c.code_social_encrypte,
    'comisseriat', co.nom, 'comisseriat_code', co.code, 'matricule', r.matricule, 'cree_le', r.cree_le) order by r.cree_le)
    from comisseriats_recrutements r join citoyens c on c.id = r.citoyen_id join comisseriats co on co.id = r.comisseriat_id
    where r.statut = 'en_attente'), '[]'::jsonb);
end; $$;
grant execute on function gouv_liste_recrutements() to authenticated;

-- « Monter de rang » : après avoir modifié num_CAS.txt, le gouvernement accepte et la personne devient Recrue.
create or replace function gouv_traiter_recrutement(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare r comisseriats_recrutements; v_mat text;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  select * into r from comisseriats_recrutements where id = p_id and statut = 'en_attente' for update;
  if r.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if p_decision = 'acceptee' then
    select matricule into v_mat from matricules_policiers where citoyen_id = r.citoyen_id;
    if v_mat is null then
      v_mat := coalesce(r.matricule, _generer_matricule());
      if exists (select 1 from matricules_policiers where matricule = v_mat) then raise exception 'Le matricule demandé est maintenant pris : demandez-en un autre.'; end if;
      insert into matricules_policiers (citoyen_id, matricule) values (r.citoyen_id, v_mat);
    end if;
    perform _embaucher_policier(r.comisseriat_id, r.citoyen_id, 1, 1);
    update citoyens set est_agent_paix = true where id = r.citoyen_id;
  end if;
  update comisseriats_recrutements set statut = p_decision where id = p_id;
end; $$;
grant execute on function gouv_traiter_recrutement(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 8) TRANSFERT ENTRE COMMISSARIATS
--    Le commissariat d'accueil demande (matricule du policier) -> le commissariat
--    d'origine accepte -> le policier accepte -> il repart au bas des grades.
-- ------------------------------------------------------------
alter table comisseriats_transferts drop constraint if exists comisseriats_transferts_statut_check;
alter table comisseriats_transferts add constraint comisseriats_transferts_statut_check
  check (statut in ('en_attente','en_attente_policier','acceptee','refusee'));

drop function if exists comisseriat_demander_transfert(uuid);
create or replace function comisseriat_demander_policier(p_comisseriat_dest uuid, p_matricule text)
returns comisseriats_transferts language plpgsql security definer set search_path = public as $$
declare m comisseriats_membres; v_row comisseriats_transferts;
begin
  if not (_est_directeur(p_comisseriat_dest) or est_admin_actuel()) then raise exception 'Réservé au Directeur du commissariat qui fait la demande.'; end if;
  select * into m from comisseriats_membres where matricule = trim(p_matricule) and statut = 'actif';
  if m.id is null then raise exception 'Aucun policier actif avec ce matricule.'; end if;
  if m.comisseriat_id = p_comisseriat_dest then raise exception 'Ce policier est déjà dans votre commissariat.'; end if;
  if exists (select 1 from comisseriats_transferts where citoyen_id = m.citoyen_id and statut in ('en_attente','en_attente_policier')) then
    raise exception 'Une demande de transfert est déjà en cours pour ce policier.';
  end if;
  insert into comisseriats_transferts (citoyen_id, comisseriat_source, comisseriat_dest)
    values (m.citoyen_id, m.comisseriat_id, p_comisseriat_dest) returning * into v_row;
  return v_row;
end; $$;
grant execute on function comisseriat_demander_policier(uuid, text) to authenticated;

-- Étape 2 : le directeur du commissariat d'origine accepte ou refuse.
create or replace function comisseriat_traiter_transfert(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare t comisseriats_transferts;
begin
  select * into t from comisseriats_transferts where id = p_id and statut = 'en_attente';
  if t.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if not (_est_directeur(t.comisseriat_source) or est_admin_actuel()) then raise exception 'Réservé au Directeur du commissariat d''origine.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update comisseriats_transferts set statut = case when p_decision = 'acceptee' then 'en_attente_policier' else 'refusee' end where id = p_id;
end; $$;

-- Étape 3 : le policier accepte ou refuse.
create or replace function comisseriat_repondre_transfert(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare t comisseriats_transferts;
begin
  select * into t from comisseriats_transferts where id = p_id and statut = 'en_attente_policier' and citoyen_id = auth.uid();
  if t.id is null then raise exception 'Demande introuvable.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  if p_decision = 'acceptee' then
    update comisseriats_membres set comisseriat_id = t.comisseriat_dest, grade = 1, sous_grade = 1
      where citoyen_id = auth.uid() and statut = 'actif';
  end if;
  update comisseriats_transferts set statut = p_decision where id = p_id;
end; $$;
grant execute on function comisseriat_repondre_transfert(uuid, text) to authenticated;

create or replace function mes_demandes_transfert_recues()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_com uuid;
begin
  select comisseriat_id into v_com from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif';
  if v_com is null then return '[]'::jsonb; end if;
  if not (_est_directeur(v_com) or _est_superviseur_royal()) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', t.id, 'citoyen', c.username, 'comisseriat_dest', cd.nom, 'cree_le', t.cree_le
  ) order by t.cree_le) from comisseriats_transferts t join citoyens c on c.id = t.citoyen_id join comisseriats cd on cd.id = t.comisseriat_dest
    where t.comisseriat_source = v_com and t.statut = 'en_attente'), '[]'::jsonb);
end; $$;

create or replace function mes_transferts_policier()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'comisseriat_source', cs.nom, 'comisseriat_dest', cd.nom, 'cree_le', t.cree_le) order by t.cree_le), '[]'::jsonb)
  from comisseriats_transferts t join comisseriats cs on cs.id = t.comisseriat_source join comisseriats cd on cd.id = t.comisseriat_dest
  where t.citoyen_id = auth.uid() and t.statut = 'en_attente_policier';
$$;
grant execute on function mes_transferts_policier() to authenticated;

-- ------------------------------------------------------------
-- 9) POLICE ROYALE MILITAIRE : grade un civil en Recrue militaire (pas plus haut)
-- ------------------------------------------------------------
create or replace function police_militaire_recruter(p_username text, p_cas_encrypte text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cible citoyens;
begin
  if not (est_admin_actuel() or exists (
      select 1 from comisseriats_membres m join comisseriats c on c.id = m.comisseriat_id
      where m.citoyen_id = auth.uid() and m.statut = 'actif' and c.type = 'police_royale_militaire')) then
    raise exception 'Réservé à la police royale militaire.';
  end if;
  select * into v_cible from citoyens where lower(username) = lower(ltrim(trim(p_username), '@'));
  if v_cible.id is null then raise exception 'Citoyen introuvable.'; end if;
  if v_cible.code_social_encrypte is distinct from trim(p_cas_encrypte) then raise exception 'Le code d''assurance sociale ne correspond pas à ce citoyen.'; end if;
  if v_cible.grade_militaire is not null then raise exception 'Cette personne est déjà dans l''armée.'; end if;
  update citoyens set grade_militaire = 'recrue' where id = v_cible.id;
end; $$;
grant execute on function police_militaire_recruter(text, text) to authenticated;

notify pgrst, 'reload schema';
