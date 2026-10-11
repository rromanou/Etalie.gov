-- ============================================================
-- patch-cib-entreprise-avancee-18.sql
-- À exécuter après patch-cib-entreprise-avancee-17.sql. Additif et rejouable.
--
-- Corrige 2 bugs signalés :
--  1) Les banques privées (non publiques) étaient lisibles par TOUT LE MONDE
--     (politique RLS "using (true)" + liste_banques() security definer qui
--     ne filtrait rien). Désormais une banque n'est visible que si elle est
--     publique, ou si le citoyen en est propriétaire/conseiller/membre, ou
--     s'il est admin.
--  2) entreprise_avancer_paiement_auto plantait (erreur 400) à chaque tick
--     de 10 secondes pour tout employé sans salaire_horaire défini — le
--     client ne peut pas savoir ça d'avance (la liste "mes entreprises" ne
--     distingue pas qui a un salaire fixé). Elle se termine maintenant
--     silencieusement dans ce cas au lieu de lever une exception.
-- ============================================================

-- 1) Confidentialité des banques privées.
drop policy if exists "Lecture publique des banques privées" on banques_privees;
create policy "Lecture des banques privées (publiques, membres, ou admin)" on banques_privees for select
  using (
    publique
    or proprietaire_id = auth.uid()
    or conseiller_id = auth.uid()
    or est_admin_actuel()
    or exists (select 1 from banques_comptes bc where bc.banque_id = banques_privees.id and bc.citoyen_id = auth.uid())
  );

create or replace function liste_banques()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'nom', b.nom, 'type', b.type, 'proprietaire', c.username, 'conseiller', cc.username,
    'publique', b.publique, 'degre_gouvernemental', b.degre_gouvernemental, 'description', b.description,
    'tresorerie', case when b.type = 'conseil' then b.tresorerie end,
    'total_fructification', case when b.type = 'fructification' then (select coalesce(sum(_valeur_compte_banque(bc.id)), 0) from banques_comptes bc where bc.banque_id = b.id) end
  ) order by b.nom), '[]'::jsonb)
  from banques_privees b join citoyens c on c.id = b.proprietaire_id left join citoyens cc on cc.id = b.conseiller_id
  where b.publique
    or b.proprietaire_id = auth.uid()
    or b.conseiller_id = auth.uid()
    or est_admin_actuel()
    or exists (select 1 from banques_comptes bc where bc.banque_id = b.id and bc.citoyen_id = auth.uid());
$$;
grant execute on function liste_banques() to authenticated, anon;

-- 2) Ne pas planter quand l'employé n'a pas (encore) de salaire défini.
create or replace function entreprise_avancer_paiement_auto(p_entreprise_id uuid, p_secondes numeric default 1)
returns void language plpgsql security definer set search_path = public as $$
declare v_taux numeric; v_mode text; v_montant numeric; v_tresor numeric;
begin
  select mode_paiement into v_mode from entreprises where id = p_entreprise_id;
  if v_mode is distinct from 'automatique' then return; end if;
  select salaire_horaire into v_taux from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_taux is null then return; end if;

  v_montant := (v_taux / 60.0) * p_secondes;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor >= v_montant then
    update entreprises set tresorerie = tresorerie - v_montant where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + v_montant where id = auth.uid();
    perform _entreprise_log(p_entreprise_id, 'paiement_employe',
      jsonb_build_object('citoyen_id', auth.uid(), 'montant', v_montant, 'secondes', p_secondes, 'taux', v_taux));
  else
    perform _entreprise_gerer_manque_paie(p_entreprise_id, auth.uid(), v_montant, v_taux);
    perform _entreprise_log(p_entreprise_id, 'paiement_employe',
      jsonb_build_object('citoyen_id', auth.uid(), 'montant', v_montant, 'secondes', p_secondes, 'taux', v_taux, 'defaillance', true));
  end if;
end; $$;
grant execute on function entreprise_avancer_paiement_auto(uuid, numeric) to authenticated;

-- Ajoute les chemins des captures d'écran (manquants côté recherche) pour une vignette
-- dans les résultats, et la province/catégorie/importé pour afficher toutes les infos.
create or replace function marche_liste_annonces(p_recherche text default null, p_categorie text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'titre', a.titre, 'prix_unitaire', a.prix_unitaire, 'quantite_disponible', a.quantite_disponible,
    'categorie_tp', a.categorie_tp, 'vendeur', c.username, 'albatros', a.albatros, 'mode_livraison', a.mode_livraison,
    'confiance_vendeur', (citoyen_confiance(a.vendeur_id)->>'score')::numeric,
    'screenshot_objet_chemin', a.screenshot_objet_chemin, 'province_vente', a.province_vente, 'importe', a.importe
  ) order by a.cree_le desc), '[]'::jsonb)
  from marche_annonces a join citoyens c on c.id = a.vendeur_id
  where a.statut = 'active' and a.quantite_disponible > 0
    and (p_recherche is null or a.titre ilike '%' || p_recherche || '%')
    and (p_categorie is null or a.categorie_tp = p_categorie);
$$;
grant execute on function marche_liste_annonces(text, text) to authenticated, anon;
