-- ISOCHRONES LINEAIRES PMR : 300, 600 ET 900 SECONDES
-- Projet : Anglet / iso15min
-- Prepare le 12 octobre 2026, teste en lecture seule sur la base pmr.
-- Versions verifiees : PostgreSQL 17, PostGIS 3.3.7, pgRouting 3.4.1.
--
-- UTILISATION
-- Executer TOUT le script dans une seule session SQL (DBeaver, pgAdmin,
-- gestionnaire de bases QGIS ou editeur SQL Supabase).
-- Dans DBeaver : executer comme script, pas uniquement la ligne courante.
-- En cas d'erreur : ROLLBACK; corriger puis relancer le script complet.
--
-- ENTREES
-- iso15min.v_troncons_regles_pmr : regles deja validees et executees.
-- transport.vue_stops_quai      : nom exact present dans cette base.
-- geo_standards.quai            : jointure s.quai_id = q.quai_id.
--
-- SORTIES PERSISTANTES
-- iso15min.v_troncons_couts_pmr                  : couts en secondes.
-- iso15min.isochrones_stops_pmr_300_600_900       : une ligne par stop/duree.
-- iso15min.controle_stops_pmr                    : controle des 62 arrets.
-- iso15min.raccords_stops_quais_pmr              : controle des raccords.
-- Une nouvelle execution remplace le contenu des TROIS tables de sortie
-- dans une transaction. Les donnees metier et les regles ne sont pas modifiees.
--
-- HYPOTHESES
-- 1. cost = longueur_m * 3.6 / vitesse_pmr_kmh ; blocage = -1.
-- 2. Meme vitesse dans les deux sens, comme dans les regles validees.
-- 3. Projection de l'arret sur SON quai associe, jamais sur un autre
--    troncon pour contourner un quai bloque.
-- 4. Raccord droit stop-quai : maximum 30 m, vitesse supposee 6 km/h.
--    Le temps du raccord est compte. Sa praticabilite n'est pas validee :
--    verifier la table des raccords et le champ raccord_a_verifier.
--    La geometrie des isochrones contient seulement le reseau, pas ces raccords.
-- 5. Si plusieurs quais sont lies au meme stop, leurs acces possibles
--    sont combines, en comptant le temps de chaque raccord.
-- 6. Tous les stops de la vue sont conserves. wheelchair_boarding='2'
--    est signale, sans ajouter un blocage absent de vos regles de cheminement.
--    Pour les arrets avec embarquement declare accessible, filtrer la sortie
--    sur wheelchair_boarding = '1'.
-- 7. Les resultats sont cumulatifs : 0-300, 0-600 et 0-900 secondes.
--    Les troncons frontieres sont coupes a la fraction reellement accessible.
-- 8. La vue des regles reste responsable des hypotheses de pente/MNT,
--    de l'exclusion des chantiers et des obstacles de pente/devers ponctuels.
--
-- RESULTATS DU TEST DU 12/10/2026
-- 1184 troncons, dont 788 parcourables et 396 bloques.
-- 62 stops, 24 calculables et 38 dont tous les quais associes sont bloques.
-- 186 lignes finales : 72 geometries d'isochrones, 114 lignes sans geometrie.
-- 23 des 24 stops calculables ont deja parcouru toute leur composante
-- accessible avant 300 s. Seul LOUI01 (Louillot) s'etend entre 300 et 600 s.
-- Aucun resultat ne s'etend entre 600 et 900 s dans cet etat du reseau.
-- Les faibles etendues resultent du reseau et des contraintes retenues.
--
-- METHODES
-- pgr_drivingDistance en multi-origines, directed=true, equicost=false.
-- Projection interieure au quai : cout initial vers chacune des extremites,
-- plus traitement direct de la portion du quai autour du point projete.
-- Toutes les aretes incidentes aux noeuds atteints sont examinees :
-- on ne conserve pas seulement l'arbre de plus courts chemins.
-- RANGE_AGG fusionne les intervalles qui se chevauchent, sans remplir
-- artificiellement un intervalle non accessible entre les deux extremites.
--
-- REFERENCES
-- https://docs.pgrouting.org/3.4/en/pgr_drivingDistance.html
-- https://postgis.net/docs/ST_LineSubstring.html
-- https://gtfs.org/documentation/schedule/reference/#stopstxt

BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE VIEW iso15min.v_troncons_couts_pmr
WITH (security_invoker = true) AS
SELECT id, id_netex, source, target, typtronco, longueur_m, vitesse_pmr_kmh,
etat_pmr, criteres_penalisants, pente_tolerance_a_justifier,
CASE WHEN vitesse_pmr_kmh > 0 AND longueur_m > 0
     THEN longueur_m * 3.6 / vitesse_pmr_kmh ELSE -1.0 END::double precision AS cost,
CASE WHEN vitesse_pmr_kmh > 0 AND longueur_m > 0
     THEN longueur_m * 3.6 / vitesse_pmr_kmh ELSE -1.0 END::double precision AS reverse_cost,
geom::geometry(LineString,3943) AS geom
FROM iso15min.v_troncons_regles_pmr;

-- Un instantane du reseau evite de recalculer le MNT a chaque parcours.

-- reseau
CREATE TEMP TABLE _iso_pmr_reseau ON COMMIT DROP AS
SELECT * FROM iso15min.v_troncons_couts_pmr;

CREATE UNIQUE INDEX ON _iso_pmr_reseau (id);
CREATE INDEX ON _iso_pmr_reseau (source);
CREATE INDEX ON _iso_pmr_reseau (target);
ANALYZE _iso_pmr_reseau;

DO $controle$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_temp._iso_pmr_reseau
        WHERE source IS NULL OR target IS NULL
           OR source <= 0 OR target <= 0
           OR longueur_m IS NULL OR longueur_m <= 0
           OR geom IS NULL OR ST_IsEmpty(geom)
    ) THEN
        RAISE EXCEPTION 'Reseau incomplet : verifier noeuds, longueurs et geometries.';
    END IF;
END
$controle$;

-- arrets
CREATE TEMP TABLE _iso_pmr_arrets ON COMMIT DROP AS
SELECT DISTINCT ON (stop_id)
stop_id::text AS stop_id, stop_name::text AS stop_name,
wheelchair_boarding::text AS wheelchair_boarding,
geom::geometry(Point,3943) AS geom
FROM transport.vue_stops_quai
WHERE stop_id IS NOT NULL
ORDER BY stop_id, id;

-- liaisons
CREATE TEMP TABLE _iso_pmr_liaisons ON COMMIT DROP AS
WITH bruts AS (
SELECT DISTINCT
s.stop_id::text AS stop_id, s.stop_name::text AS stop_name,
s.wheelchair_boarding::text AS wheelchair_boarding,
s.quai_id::text AS quai_id, q.troncon_id_netex::text AS quai_troncon_id_netex,
t.id AS troncon_id, t.source, t.target, t.cost, t.reverse_cost,
t.etat_pmr, t.criteres_penalisants,
s.geom::geometry(Point,3943) AS geom_stop,
t.geom AS geom_quai
FROM transport.vue_stops_quai s
LEFT JOIN geo_standards.quai q ON q.quai_id = s.quai_id
LEFT JOIN pg_temp._iso_pmr_reseau t ON t.id_netex = q.troncon_id_netex
WHERE s.stop_id IS NOT NULL
),
projections AS (
SELECT b.*,
ST_Distance(geom_stop,geom_quai) AS distance_raccord_m,
ST_LineLocatePoint(geom_quai,geom_stop) AS fraction,
ST_ClosestPoint(geom_quai,geom_stop)::geometry(Point,3943) AS geom_projection
FROM bruts b
)
SELECT ROW_NUMBER() OVER (ORDER BY stop_id,quai_id NULLS FIRST,troncon_id NULLS FIRST)::bigint AS lien_id,
p.*, distance_raccord_m * 3.6 / 6.0 AS temps_raccord_s,
ST_MakeLine(geom_stop,geom_projection)::geometry(LineString,3943) AS geom,
CASE
 WHEN quai_id IS NULL THEN 'quai_non_renseigne'
 WHEN troncon_id IS NULL THEN 'quai_hors_reseau'
 WHEN geom_stop IS NULL OR ST_IsEmpty(geom_stop) OR geom_quai IS NULL OR ST_IsEmpty(geom_quai) THEN 'geometrie_absente'
 WHEN cost <= 0 OR reverse_cost <= 0 THEN 'quai_bloque'
 WHEN distance_raccord_m > 30.0 THEN 'raccord_trop_long'
 ELSE 'depart_calculable'
END AS statut_raccord,
distance_raccord_m > 0.01 AS raccord_a_verifier
FROM projections p;

-- origines
CREATE TEMP TABLE _iso_pmr_origines ON COMMIT DROP AS
SELECT * FROM pg_temp._iso_pmr_liaisons WHERE statut_raccord='depart_calculable';

-- amorces
CREATE TEMP TABLE _iso_pmr_amorces ON COMMIT DROP AS
SELECT o.stop_id, o.lien_id, a.noeud, MIN(a.temps_initial_s) AS temps_initial_s
FROM pg_temp._iso_pmr_origines o
CROSS JOIN LATERAL (VALUES
 (o.source, o.temps_raccord_s + o.fraction * o.reverse_cost),
 (o.target, o.temps_raccord_s + (1.0-o.fraction) * o.cost)
) a(noeud,temps_initial_s)
WHERE a.temps_initial_s <= 900
GROUP BY o.stop_id,o.lien_id,a.noeud;

-- sql_graphe
CREATE TEMP TABLE _iso_pmr_sql_graphe ON COMMIT DROP AS
SELECT 'SELECT id, source, target, cost, reverse_cost FROM pg_temp._iso_pmr_reseau WHERE cost > 0 AND reverse_cost > 0'::text AS sql_reseau;

-- distances_graphe
CREATE TEMP TABLE _iso_pmr_distances_graphe ON COMMIT DROP AS
SELECT d.from_v,d.node,d.agg_cost
FROM pg_temp._iso_pmr_sql_graphe g
CROSS JOIN LATERAL public.pgr_drivingDistance(
 g.sql_reseau,
 COALESCE((SELECT ARRAY_AGG(DISTINCT noeud) FROM pg_temp._iso_pmr_amorces),ARRAY[-1::bigint]),
 900::double precision, true, false
) d;

-- distances
CREATE TEMP TABLE _iso_pmr_distances ON COMMIT DROP AS
SELECT stop_id,node,MIN(temps_s) AS temps_s FROM (
 SELECT a.stop_id,d.node,a.temps_initial_s+d.agg_cost AS temps_s
 FROM pg_temp._iso_pmr_amorces a JOIN pg_temp._iso_pmr_distances_graphe d ON d.from_v=a.noeud
 WHERE a.temps_initial_s+d.agg_cost<=900
 UNION ALL
 SELECT stop_id,noeud,temps_initial_s FROM pg_temp._iso_pmr_amorces
) x GROUP BY stop_id,node;

-- intervalles
CREATE TEMP TABLE _iso_pmr_intervalles ON COMMIT DROP AS
SELECT d.stop_id,b.duree_s,e.id AS troncon_id,
0.0::double precision AS f0,
LEAST(1.0,(b.duree_s-d.temps_s)/e.cost) AS f1
FROM pg_temp._iso_pmr_distances d
JOIN pg_temp._iso_pmr_reseau e ON e.source=d.node AND e.cost>0
CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
WHERE d.temps_s<b.duree_s
UNION ALL
SELECT d.stop_id,b.duree_s,e.id,
GREATEST(0.0,1.0-(b.duree_s-d.temps_s)/e.reverse_cost),1.0
FROM pg_temp._iso_pmr_distances d
JOIN pg_temp._iso_pmr_reseau e ON e.target=d.node AND e.reverse_cost>0
CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
WHERE d.temps_s<b.duree_s
UNION ALL
SELECT o.stop_id,b.duree_s,o.troncon_id,
GREATEST(0.0,o.fraction-(b.duree_s-o.temps_raccord_s)/o.reverse_cost),
LEAST(1.0,o.fraction+(b.duree_s-o.temps_raccord_s)/o.cost)
FROM pg_temp._iso_pmr_origines o
CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
WHERE o.temps_raccord_s<b.duree_s;

-- intervalles_fusionnes
CREATE TEMP TABLE _iso_pmr_intervalles_fusionnes ON COMMIT DROP AS
SELECT stop_id,duree_s,troncon_id,
RANGE_AGG(NUMRANGE(f0::numeric,f1::numeric,'[]')) AS plages
FROM pg_temp._iso_pmr_intervalles WHERE f1>f0 GROUP BY stop_id,duree_s,troncon_id;

-- portions
CREATE TEMP TABLE _iso_pmr_portions ON COMMIT DROP AS
SELECT i.stop_id,i.duree_s,i.troncon_id,
ST_LineSubstring(e.geom,LOWER(p.plage)::double precision,UPPER(p.plage)::double precision)
::geometry(LineString,3943) AS geom
FROM pg_temp._iso_pmr_intervalles_fusionnes i
JOIN pg_temp._iso_pmr_reseau e ON e.id=i.troncon_id
CROSS JOIN LATERAL UNNEST(i.plages) p(plage);

-- isochrones
CREATE TEMP TABLE _iso_pmr_isochrones ON COMMIT DROP AS
SELECT stop_id,duree_s,COUNT(DISTINCT troncon_id)::integer AS nb_troncons,
ST_Multi(ST_CollectionExtract(ST_UnaryUnion(ST_Collect(geom)),2))
::geometry(MultiLineString,3943) AS geom
FROM pg_temp._iso_pmr_portions GROUP BY stop_id,duree_s;

-- controle_arrets
CREATE TEMP TABLE _iso_pmr_controle_arrets ON COMMIT DROP AS
SELECT stop_id,
COALESCE(ARRAY_AGG(DISTINCT quai_id ORDER BY quai_id) FILTER(WHERE quai_id IS NOT NULL),'{}'::text[]) AS quai_ids,
COALESCE(ARRAY_AGG(DISTINCT quai_id ORDER BY quai_id) FILTER(WHERE statut_raccord='depart_calculable'),'{}'::text[]) AS quai_ids_utilises,
COUNT(*) FILTER(WHERE statut_raccord='depart_calculable')::integer AS nb_departs_calculables,
BOOL_OR(statut_raccord='quai_bloque') AS quai_bloque_present,
BOOL_OR(raccord_a_verifier) FILTER(WHERE statut_raccord='depart_calculable') AS raccord_a_verifier,
MIN(distance_raccord_m) FILTER(WHERE statut_raccord='depart_calculable') AS distance_raccord_min_m,
MAX(distance_raccord_m) FILTER(WHERE statut_raccord='depart_calculable') AS distance_raccord_max_m,
MIN(temps_raccord_s) FILTER(WHERE statut_raccord='depart_calculable') AS temps_raccord_min_s,
MAX(temps_raccord_s) FILTER(WHERE statut_raccord='depart_calculable') AS temps_raccord_max_s
FROM pg_temp._iso_pmr_liaisons GROUP BY stop_id;

-- resultat
CREATE TEMP TABLE _iso_pmr_resultat ON COMMIT DROP AS
SELECT ROW_NUMBER() OVER (ORDER BY s.stop_id,b.duree_s)::bigint AS gid,
s.stop_id,s.stop_name,s.wheelchair_boarding,
s.wheelchair_boarding='2' AS alerte_accessibilite_gtfs,
a.quai_ids,a.quai_ids_utilises,b.duree_s,
a.nb_departs_calculables,COALESCE(i.nb_troncons,0) AS nb_troncons,
COALESCE(ST_Length(i.geom),0.0)::double precision AS longueur_accessible_m,
CASE WHEN i.geom IS NOT NULL THEN 'calcule'
 WHEN a.nb_departs_calculables=0 AND a.quai_bloque_present THEN 'quai_bloque'
 WHEN a.nb_departs_calculables=0 THEN 'aucun_raccord_utilisable'
 ELSE 'aucune_portion_accessible' END::text AS statut,
COALESCE(a.raccord_a_verifier,false) AS raccord_a_verifier,
a.distance_raccord_min_m,a.distance_raccord_max_m,
a.temps_raccord_min_s,a.temps_raccord_max_s,
CURRENT_TIMESTAMP AS date_calcul,
i.geom
FROM pg_temp._iso_pmr_arrets s CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
LEFT JOIN pg_temp._iso_pmr_controle_arrets a ON a.stop_id=s.stop_id
LEFT JOIN pg_temp._iso_pmr_isochrones i ON i.stop_id=s.stop_id AND i.duree_s=b.duree_s;

-- Table cartographique : 3 lignes par arret, y compris les departs bloques.
CREATE TABLE IF NOT EXISTS iso15min.isochrones_stops_pmr_300_600_900 AS
SELECT * FROM pg_temp._iso_pmr_resultat WITH NO DATA;

DELETE FROM iso15min.isochrones_stops_pmr_300_600_900;
INSERT INTO iso15min.isochrones_stops_pmr_300_600_900
SELECT * FROM pg_temp._iso_pmr_resultat;

CREATE UNIQUE INDEX IF NOT EXISTS isochrones_stops_pmr_gid_uidx
ON iso15min.isochrones_stops_pmr_300_600_900 (gid);
CREATE UNIQUE INDEX IF NOT EXISTS isochrones_stops_pmr_stop_duree_uidx
ON iso15min.isochrones_stops_pmr_300_600_900 (stop_id, duree_s);
CREATE INDEX IF NOT EXISTS isochrones_stops_pmr_geom_gix
ON iso15min.isochrones_stops_pmr_300_600_900 USING GIST (geom);

-- Une couche de points permet de voir aussi les arrets sans isochrone.
CREATE TEMP TABLE _iso_pmr_controle_sortie ON COMMIT DROP AS
SELECT ROW_NUMBER() OVER (ORDER BY s.stop_id)::bigint AS gid,
s.stop_id, s.stop_name, s.wheelchair_boarding,
r.alerte_accessibilite_gtfs, r.quai_ids, r.quai_ids_utilises,
r.nb_departs_calculables, r.statut,
r.raccord_a_verifier, r.distance_raccord_min_m, r.distance_raccord_max_m,
r.temps_raccord_min_s, r.temps_raccord_max_s, r.date_calcul,
s.geom
FROM pg_temp._iso_pmr_arrets s
JOIN pg_temp._iso_pmr_resultat r ON r.stop_id=s.stop_id AND r.duree_s=900;

CREATE TABLE IF NOT EXISTS iso15min.controle_stops_pmr AS
SELECT * FROM pg_temp._iso_pmr_controle_sortie WITH NO DATA;

DELETE FROM iso15min.controle_stops_pmr;
INSERT INTO iso15min.controle_stops_pmr
SELECT * FROM pg_temp._iso_pmr_controle_sortie;

CREATE UNIQUE INDEX IF NOT EXISTS controle_stops_pmr_gid_uidx
ON iso15min.controle_stops_pmr (gid);
CREATE UNIQUE INDEX IF NOT EXISTS controle_stops_pmr_stop_uidx
ON iso15min.controle_stops_pmr (stop_id);
CREATE INDEX IF NOT EXISTS controle_stops_pmr_geom_gix
ON iso15min.controle_stops_pmr USING GIST (geom);

-- Raccords droits a verifier visuellement/terrain.
CREATE TEMP TABLE _iso_pmr_raccords_sortie ON COMMIT DROP AS
SELECT lien_id AS gid, stop_id, stop_name, wheelchair_boarding, quai_id,
quai_troncon_id_netex, troncon_id, source, target,
fraction, distance_raccord_m, temps_raccord_s,
cost AS cout_quai_s, etat_pmr AS etat_quai, criteres_penalisants,
statut_raccord, raccord_a_verifier,
CURRENT_TIMESTAMP AS date_calcul,
CASE WHEN distance_raccord_m > 0
     THEN geom ELSE NULL END::geometry(LineString,3943) AS geom
FROM pg_temp._iso_pmr_liaisons;

CREATE TABLE IF NOT EXISTS iso15min.raccords_stops_quais_pmr AS
SELECT * FROM pg_temp._iso_pmr_raccords_sortie WITH NO DATA;

DELETE FROM iso15min.raccords_stops_quais_pmr;
INSERT INTO iso15min.raccords_stops_quais_pmr
SELECT * FROM pg_temp._iso_pmr_raccords_sortie;

CREATE UNIQUE INDEX IF NOT EXISTS raccords_stops_quais_pmr_gid_uidx
ON iso15min.raccords_stops_quais_pmr (gid);
CREATE INDEX IF NOT EXISTS raccords_stops_quais_pmr_geom_gix
ON iso15min.raccords_stops_quais_pmr USING GIST (geom);

COMMENT ON TABLE iso15min.isochrones_stops_pmr_300_600_900 IS
'Isochrones lineaires cumulatifs PMR en secondes. Hypotheses de la vue v_troncons_regles_pmr. Raccords droits supposes praticables a 6 km/h, a verifier. Les arrets GTFS wheelchair_boarding=2 sont signales.';
COMMENT ON TABLE iso15min.controle_stops_pmr IS
'Controle des departs : un point par stop, y compris ceux dont le quai est bloque.';
COMMENT ON TABLE iso15min.raccords_stops_quais_pmr IS
'Raccords geometriques au quai associe : leur praticabilite reste a verifier. Aucun raccord a un autre troncon ne contourne un quai bloque.';

ANALYZE iso15min.isochrones_stops_pmr_300_600_900;
ANALYZE iso15min.controle_stops_pmr;
ANALYZE iso15min.raccords_stops_quais_pmr;

COMMIT;

-- CONTROLE 1 : attendu au 12/10/2026 : 24 calcules et 38 bloques par duree.
SELECT duree_s, statut, COUNT(*) AS nb_arrets
FROM iso15min.isochrones_stops_pmr_300_600_900
GROUP BY duree_s, statut
ORDER BY duree_s, statut;

-- CONTROLE 2 : aucune ligne attendue (unicite stop/duree).
SELECT stop_id, duree_s, COUNT(*)
FROM iso15min.isochrones_stops_pmr_300_600_900
GROUP BY stop_id, duree_s
HAVING COUNT(*) > 1;

-- CONTROLE 3 : arrets a examiner.
SELECT stop_id, stop_name, wheelchair_boarding, statut,
       distance_raccord_max_m, raccord_a_verifier
FROM iso15min.controle_stops_pmr
WHERE statut <> 'calcule'
   OR alerte_accessibilite_gtfs
   OR raccord_a_verifier
ORDER BY stop_id;

-- QGIS
-- Ajouter iso15min.isochrones_stops_pmr_300_600_900 :
--   geometrie = geom ; identifiant unique = gid ; SCR = EPSG:3943.
-- Symbologie categorisee sur duree_s : 300, 600, 900.
-- Afficher d'abord 900, puis 600, puis 300 pour eviter le masquage.
-- Filtre pour les seules geometries calculees : "statut" = 'calcule'.
-- Pour les stops avec embarquement declare accessible, ajouter :
--   AND "wheelchair_boarding" = '1'
-- Ajouter controle_stops_pmr et raccords_stops_quais_pmr pour le diagnostic.
-- Reexecuter ce script apres toute modification du reseau, des regles ou stops.

