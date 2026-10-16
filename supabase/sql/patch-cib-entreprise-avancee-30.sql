-- ============================================================
-- patch-cib-entreprise-avancee-30.sql
-- À exécuter après le patch 29. Additif et rejouable.
-- Achat de capital sur le marché public : payé par carte, CIB d'envoi
-- ou (gouvernement seulement) trésoreries publiques, jamais directement
-- par la trésorerie personnelle. Aucun intérêt à calculer sur des taxes
-- (il n'y en a pas sur le capital) : tout est prix net.
-- ============================================================
drop function if exists entreprise_acheter_capital(uuid, numeric);
create or replace function entreprise_acheter_capital(p_entreprise_id uuid, p_pourcentage numeric, p_moyen text,
  p_carte_numero text default null, p_carte_nip text default null, p_cib text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_deja numeric; v_dispo numeric; v_bonus numeric; v_tresor_apres_cout numeric;
begin
  select * into v_ent from entreprises where id = p_entreprise_id and statut = 'acceptee' for update;
  if v_ent.id is null then raise exception 'Entreprise introuvable.'; end if;
  if v_ent.capital_prix_par_centieme is null then raise exception 'Aucune offre en cours.'; end if;
  if p_pourcentage < v_ent.capital_min_achat_pct then raise exception 'Minimum achetable : % %%.', v_ent.capital_min_achat_pct; end if;
  if p_pourcentage > v_ent.capital_en_vente_pct then raise exception 'Il ne reste que % %% en vente.', v_ent.capital_en_vente_pct; end if;
  select coalesce(pourcentage, 0) into v_deja from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_ent.capital_max_par_individu is not null and (coalesce(v_deja, 0) + p_pourcentage) > v_ent.capital_max_par_individu then
    raise exception 'Maximum par individu dépassé (max : % %%).', v_ent.capital_max_par_individu;
  end if;

  v_cout := (p_pourcentage / 0.01) * v_ent.capital_prix_par_centieme;

  v_bonus := round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2);
  v_tresor_apres_cout := v_ent.tresorerie + v_cout;
  v_bonus := least(v_bonus, greatest(v_tresor_apres_cout, 0));

  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_cout, 0);
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout - v_bonus, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage, solde, solde_all_time)
    values (p_entreprise_id, auth.uid(), p_pourcentage, v_bonus, v_bonus)
    on conflict (entreprise_id, citoyen_id) do update set
      pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
      solde = entreprises_capital_detenteurs.solde + v_bonus,
      solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_bonus;
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_log(p_entreprise_id, 'vente_capital',
    jsonb_build_object('acheteur_username', (select username from citoyens where id = auth.uid()), 'pourcentage', p_pourcentage, 'cout', v_cout, 'montant', v_cout, 'bonus_halgeberg', v_bonus));
  perform _entreprise_maj_pdg_capital(p_entreprise_id);
end; $$;
grant execute on function entreprise_acheter_capital(uuid, numeric, text, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- Listes avec numéros de suivi (plus aucun UUID à afficher ou saisir)
-- ------------------------------------------------------------
create or replace function liste_comisseriats()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'code', c.code, 'nom', c.nom, 'type', c.type, 'directeur', d.username, 'adresse', c.adresse, 'statut', c.statut,
    'effectif', (select count(*) from comisseriats_membres m where m.comisseriat_id = c.id and m.statut = 'actif')
  ) order by c.nom), '[]'::jsonb)
  from comisseriats c left join citoyens d on d.id = c.directeur_id;
$$;
grant execute on function liste_comisseriats() to authenticated, anon;

-- Traduit des identifiants internes en noms d'utilisateur (affichage seulement).
create or replace function noms_citoyens(p_ids uuid[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(id::text, username), '{}'::jsonb) from citoyens where id = any(p_ids) and auth.uid() is not null;
$$;
grant execute on function noms_citoyens(uuid[]) to authenticated;

create or replace function mes_annonces_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'titre', a.titre) order by a.titre), '[]'::jsonb)
  from marche_annonces a where a.vendeur_id = auth.uid();
$$;
grant execute on function mes_annonces_marche() to authenticated;

notify pgrst, 'reload schema';
