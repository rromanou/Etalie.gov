-- ============================================================
-- patch-cib-entreprise-avancee-22.sql
-- À exécuter après patch-cib-entreprise-avancee-21.sql. Additif et rejouable.
--
-- MISE À JOUR DES PROVINCES (liste officielle à 44 provinces, avec
-- données complètes) + TERRITOIRE DU ROY.
--
-- HYPOTHÈSES :
--  - La colonne "Form" (Province / Land / Occupation zone / Territory /
--    Captaincy) décide le type de territoire fiscal déjà existant (TP,
--    TOM, TC) : Province -> TP, Land -> TOM, Captaincy -> TOM,
--    Occupation zone -> TC, Territory -> TC. Aucun nouveau taux n'étant
--    donné, le taux TAP par défaut (5 %) s'applique aux provinces
--    nouvellement ajoutées ; l'administration peut l'ajuster comme avant.
--  - La colonne "State" ("Romance" partout dans la liste donnée) est
--    stockée telle quelle (groupe culturel/faction), sans effet sur les
--    mécaniques actuelles.
--  - "Tonawa" (ancienne liste) n'existe plus telle quelle ; "Terre de
--    Towana" la remplace dans la nouvelle liste (même capitale au nom
--    très proche). Les citoyens résidant à "Tonawa" sont automatiquement
--    déplacés vers "Terre de Towana", et la province d'éligibilité
--    autochtone (patch 15) est mise à jour en conséquence.
--  - Les 3 autres anciens noms absents de la nouvelle liste
--    (Île-de-L'île, Hors-Orremaux, Waterland) n'ont pas d'équivalent
--    évident : leurs lignes de taxation restent en place (marquées
--    "historique") pour ne rien casser chez les citoyens qui y résident
--    encore, mais elles disparaissent du formulaire d'inscription/choix
--    de province, donc plus personne ne peut les choisir à l'avenir.
--  - Territoire du Roy : un DEUXIÈME indicateur sur le citoyen (pas une
--    province de résidence), qui s'AJOUTE à sa province normale sans la
--    remplacer, à 0 % de taxe et sans aucun commerce. Non sélectionnable
--    à l'inscription ; seule l'administration peut l'attribuer ou le
--    retirer, manuellement, à un citoyen précis.
-- ============================================================

create table if not exists provinces_info (
  province           text primary key,
  nom_complet         text,
  forme               text not null check (forme in ('Province','Land','Occupation zone','Territory','Captaincy')),
  etat                text,
  couleur             text,
  capitale            text,
  superficie_km2      numeric,
  population_totale   numeric,
  population_rurale   numeric,
  population_urbaine  numeric
);
alter table provinces_info enable row level security;
drop policy if exists "Lecture publique des infos provinces" on provinces_info;
create policy "Lecture publique des infos provinces" on provinces_info for select using (true);

insert into provinces_info (province, nom_complet, forme, etat, couleur, capitale, superficie_km2, population_totale, population_rurale, population_urbaine) values
  ('Gibaltage','Nom original; Jabal Jaleedi - Nom italianisé: Gibaltage - Nom Officiel: Quadèrnitophanilorezque','Province','Romance','#e5ae5d','Gibaltage',992,22050,8000,14050),
  ('Talon Étalien','Talon Étalien','Province','Romance','#cca34f','Maréchaux',34144,1592000,1554000,38000),
  ('Talon Andrien','Talon Andrien','Province','Romance','#e5ac39','Yara-Notre-Sauveur',25408,2221482,1656000,565482),
  ('Fleury','Fleury Province','Province','Romance','#f99436','Port-Aux-Souverains',34720,2637000,1596000,1041000),
  ('Baxe','Baxe','Province','Romance','#f99534','Lionnes',46608,6663410,2958000,3705410),
  ('Vénésie','Vénésie','Province','Romance','#e0884b','Oberied',21360,1343553,1341000,2553),
  ('Marcio','Marcio','Province','Romance','#e0884b','Lataylon',21008,1873036,1481000,392036),
  ('Romagna','Romagna','Province','Romance','#f68945',null,22352,1408000,1408000,0),
  ('Grâdes-Tivainne','L''union de Grâdes-Tivainne','Province','Romance','#cca74a','Roymont',17248,987000,559000,428000),
  ('Aloies','Aloies','Province','Romance','#d4ac3e','Orremaux',11760,685010,673000,12010),
  ('Balques','Union des Balques','Province','Romance','#eea734','Maréchaux',16352,1230000,1176000,54000),
  ('Alanbie-Brien-Jance','Union de l''Alanbie-Brien-Jance','Province','Romance','#f98c3f',null,17232,1090000,1090000,0),
  ('Île Saint-Étienne','Île Saint-Étienne','Province','Romance','#eca836','Port Saint-Étienne',912,97000,69000,28000),
  ('Ombrie','Ombrie Province','Province','Romance','#db8a4d',null,13184,875000,875000,0),
  ('Vénéz','Union de Vénéz','Province','Romance','#f28849','Braume',10752,671000,671000,0),
  ('Milela','L''union de Milela','Province','Romance','#ce9d54','Commori',22144,1216951,781000,435951),
  ('Pruxe','Pruxe','Province','Romance','#d79053','Angerce',1104,110244,58000,52244),
  ('Quoueta-Et-Milenniar-Étalois','Quoueta-Et-Milenniar-Étalois','Province','Romance','#c0ad4b','Valcourt',416,39000,22000,17000),
  ('Terre de Towana','Terre de Towana Land','Land','Romance','#cba34e','Chritsburg',6800,402000,212000,190000),
  ('Côte-Anglaise','Côte-Anglaise','Province','Romance','#f99436','Newhouse',13824,954000,647000,307000),
  ('Grande-Capitale','Grande-Capitale','Province','Romance','#ec874b','Calombre',384,3758391,29000,3729391),
  ('Zone Haute-Romanie','Zone d''occupation de la Haute-Romanie','Occupation zone','Romance','#dc884a','Wemin',51696,1602010,1602000,10),
  ('Bushard Bay','Bushard Bay','Province','Romance','#ceaa45','Roma',17600,1267344,1116000,151344),
  ('Hors-Grande-Vénésie','Hors-Grande-Vénésie','Province','Romance','#cca848',null,19552,655000,655000,0),
  ('Nouvelle-Braume-Chiranie','Nouvelle-Braume-Chiranie','Province','Romance','#f98b42',null,23968,729000,729000,0),
  ('Haute-Étalie-du-Glaive','Haute-Étalie-du-Glaive','Province','Romance','#f98d3d','Losterten',42512,1279244,1279000,244),
  ('Zone Dovintski','Zone Dovintski Territory','Territory','Romance','#f35fa2',null,6448,127000,127000,0),
  ('Alten','Alten','Province','Romance','#4fa22d',null,58688,1533000,1533000,0),
  ('Grand-Nord','Grand-Nord Province','Province','Romance','#64a526',null,18016,702000,702000,0),
  ('Terre des Opalves','Terre des Opalves Land','Land','Romance','#72951e','Ningâbishish',5280,123363,120000,3363),
  ('Terre des Tousques','Terre des Tousques Land','Land','Romance','#669324','Tuuski',7808,468583,464000,4583),
  ('Terre des Bosbins','Terre des Bosbins Land','Land','Romance','#4ca72c','Bosbuteso',2704,56181,56000,181),
  ('Alonse','Alonse','Province','Romance','#76961a',null,10944,551000,551000,0),
  ('Braume','Braume','Province','Romance','#589626',null,13104,439000,439000,0),
  ('Nouvelle-Étalie','Nouvelle-Étalie','Province','Romance','#769a14','Ðalymynäe',9216,494365,294000,200365),
  ('Nord','Nord','Province','Romance','#70ad09','Bakaldakao',49680,2046191,2046000,191),
  ('Chiranie','Chiranie','Province','Romance','#49ac29','Kriku',58320,946035,946000,35),
  ('Basse-Alten','Basse-Alten','Province','Romance','#49ae28',null,60096,2068000,2068000,0),
  ('Centre','Centre','Province','Romance','#4aab2b','Barga',51888,1824352,1815000,9352),
  ('Sud-Oriental','Sud-Oriental','Province','Romance','#529e2c',null,45856,1826000,1826000,0),
  ('Sud-Occidental','Sud-Occidental Province','Province','Romance','#6c9322',null,32160,1022000,1022000,0),
  ('Sud-Nordique','Sud-Nordique','Province','Romance','#48af27',null,41600,1378000,1378000,0),
  ('Muslimanie','Muslimanie','Province','Romance','#679324',null,6816,427000,427000,0),
  ('Place du Roy','Place du Roy','Captaincy','Romance','#49ac29',null,784,50000,50000,0)
on conflict (province) do update set nom_complet = excluded.nom_complet, forme = excluded.forme, etat = excluded.etat,
  couleur = excluded.couleur, capitale = excluded.capitale, superficie_km2 = excluded.superficie_km2,
  population_totale = excluded.population_totale, population_rurale = excluded.population_rurale, population_urbaine = excluded.population_urbaine;

-- Marque les anciennes provinces sans équivalent, pour que la lecture publique
-- de liste_provinces_taxation() puisse les distinguer si besoin.
alter table provinces_taxation add column if not exists historique boolean not null default false;
update provinces_taxation set historique = true where province in ('Île-de-L''île','Hors-Orremaux','Waterland');

-- Ajoute/actualise les 44 provinces officielles (type dérivé de la forme ci-dessus),
-- sans toucher aux lignes historiques déjà présentes.
insert into provinces_taxation (province, type_territoire)
select p.province, case p.forme when 'Occupation zone' then 'TC' when 'Territory' then 'TC' when 'Land' then 'TOM' when 'Captaincy' then 'TOM' else 'TP' end
from provinces_info p
on conflict (province) do update set type_territoire = excluded.type_territoire;

-- Migration : "Tonawa" -> "Terre de Towana" (voir HYPOTHÈSE en tête de fichier).
update citoyens set province_residence = 'Terre de Towana' where province_residence = 'Tonawa';
update marche_annonces set province_vente = 'Terre de Towana' where province_vente = 'Tonawa';

create or replace function s_enregistrer_autochtone(p_nom_famille text)
returns void language plpgsql security definer set search_path = public as $$
declare v_province text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select province_residence into v_province from citoyens where id = auth.uid();
  if _province_courte(v_province) not in ('Terre de Towana','Bushard Bay','Pruxe','Milela','Gibaltage') then
    raise exception 'Seuls les citoyens résidant à Terre de Towana, Bushard Bay, Pruxe, Milela ou Gibaltage peuvent s''enregistrer.';
  end if;
  if p_nom_famille is null or char_length(trim(p_nom_famille)) = 0 then raise exception 'Nom de famille requis.'; end if;
  update citoyens set autochtone = true, autochtone_famille = trim(p_nom_famille) where id = auth.uid();
end; $$;
grant execute on function s_enregistrer_autochtone(text) to authenticated;

create or replace function liste_provinces_info()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'province', p.province, 'nom_complet', p.nom_complet, 'forme', p.forme, 'etat', p.etat, 'couleur', p.couleur,
    'capitale', p.capitale, 'superficie_km2', p.superficie_km2, 'population_totale', p.population_totale,
    'population_rurale', p.population_rurale, 'population_urbaine', p.population_urbaine,
    'type_territoire', t.type_territoire, 'taux_tap', t.taux_tap
  ) order by p.province), '[]'::jsonb)
  from provinces_info p left join provinces_taxation t on t.province = p.province;
$$;
grant execute on function liste_provinces_info() to authenticated, anon;

-- ---- TERRITOIRE DU ROY ----
alter table citoyens add column if not exists territoire_du_roy boolean not null default false;

create or replace function gouv_attribuer_territoire_roy(p_username text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update citoyens set territoire_du_roy = true where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_attribuer_territoire_roy(text) to authenticated;

create or replace function gouv_retirer_territoire_roy(p_username text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update citoyens set territoire_du_roy = false where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_retirer_territoire_roy(text) to authenticated;
