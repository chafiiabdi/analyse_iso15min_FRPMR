-- ISOCHRONES : SCENARIO SANS ESCALIERS, 6 KM/H, 300 / 600 / 900 SECONDES
-- Prepare le 12 octobre 2026 pour Anglet.
-- Executer TOUT le script dans une seule session SQL (DBeaver ou pgAdmin).
-- En cas d'erreur : ROLLBACK; puis corriger et relancer.
--
-- Seule exclusion de cheminement : typtronco = escalier (ou escaliers).
-- Pente, devers, largeur, revetement, obstacles et chantiers IGNORES.
-- Vitesse constante de 6 km/h dans les deux sens pour les autres troncons.
-- Aucune dependance a la vue v_troncons_regles_pmr ou au MNT.
-- Ce scenario ne constitue pas une validation d'accessibilite PMR.
-- Le reseau conserve ses connexions existantes : aucun lien fictif n'est ajoute.
--
-- Entrees : iso15min.v_troncons_pgrouting_pmr_v2,
-- transport.vue_stops_quai, geo_standards.quai.
-- Jointure : s.quai_id = q.quai_id puis q.troncon_id_netex = t.id_netex.
-- Projection de chaque arret sur son quai associe. Raccord droit <= 30 m
-- suppose parcourable a 6 km/h : temps inclus, passage reel a verifier.
-- Plusieurs quais pour un arret : combinaison des acces possibles.
-- GTFS wheelchair_boarding conserve a titre informatif, sans exclusion.
--
-- Sorties NOUVELLES :
-- iso15min.v_troncons_couts_sans_escaliers (inclut les escaliers avec cout -1)
-- iso15min.isochrones_sans_escaliers_300_600_900
-- iso15min.v_iso_sans_escaliers_300s
-- iso15min.v_iso_sans_escaliers_600s
-- iso15min.v_iso_sans_escaliers_900s
-- iso15min.controle_stops_sans_escaliers
-- iso15min.raccords_sans_escaliers
-- Les sorties du scenario PMR precedent ne sont pas modifiees.
-- Une reexecution actualise seulement les trois nouvelles tables ci-dessus.
--
-- Isochrones lineaires cumulatifs : 0-300, 0-600 et 0-900 secondes.
-- Les troncons partiellement atteints sont decoupes au budget disponible.
-- pgRouting 3.4.1 : pgr_drivingDistance, from_v, equicost=false.
-- QGIS : cle gid et geometrie geom ; reseau : cle id.
-- SCR : EPSG:3943.
-- Documentation : https://docs.pgrouting.org/3.4/en/pgr_drivingDistance.html
-- https://postgis.net/docs/ST_LineSubstring.html

BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE VIEW iso15min.v_troncons_couts_sans_escaliers
WITH (security_invoker = true) AS
SELECT id, id_netex, source, target, typtronco, longueur_m,
CASE WHEN LOWER(BTRIM(COALESCE(typtronco,''))) IN ('escalier','escaliers')
     THEN 0 ELSE 6 END::integer AS vitesse_kmh,
CASE WHEN LOWER(BTRIM(COALESCE(typtronco,''))) IN ('escalier','escaliers')
     THEN 'escalier_exclu' ELSE 'praticable_scenario' END::text AS etat_reseau,
CASE WHEN LOWER(BTRIM(COALESCE(typtronco,''))) IN ('escalier','escaliers')
     THEN ARRAY['escalier']::text[] ELSE ARRAY[]::text[] END AS motifs_exclusion,
CASE WHEN LOWER(BTRIM(COALESCE(typtronco,''))) IN ('escalier','escaliers')
     THEN -1.0 ELSE longueur_m * 3.6 / 6.0 END::double precision AS cost,
CASE WHEN LOWER(BTRIM(COALESCE(typtronco,''))) IN ('escalier','escaliers')
     THEN -1.0 ELSE longueur_m * 3.6 / 6.0 END::double precision AS reverse_cost,
geom::geometry(LineString,3943) AS geom
FROM iso15min.v_troncons_pgrouting_pmr_v2;

-- Instantane du reseau : aucune lecture des criteres ou du MNT.

-- reseau
CREATE TEMP TABLE _iso_se_reseau ON COMMIT DROP AS
SELECT * FROM iso15min.v_troncons_couts_sans_escaliers;

CREATE UNIQUE INDEX ON _iso_se_reseau (id);
CREATE INDEX ON _iso_se_reseau (source);
CREATE INDEX ON _iso_se_reseau (target);
ANALYZE _iso_se_reseau;

DO $controle$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_temp._iso_se_reseau
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
CREATE TEMP TABLE _iso_se_arrets ON COMMIT DROP AS
SELECT DISTINCT ON (stop_id)
stop_id::text AS stop_id, stop_name::text AS stop_name,
wheelchair_boarding::text AS wheelchair_boarding,
geom::geometry(Point,3943) AS geom
FROM transport.vue_stops_quai
WHERE stop_id IS NOT NULL
ORDER BY stop_id, id;

-- liaisons
CREATE TEMP TABLE _iso_se_liaisons ON COMMIT DROP AS
WITH bruts AS (
SELECT DISTINCT
s.stop_id::text AS stop_id, s.stop_name::text AS stop_name,
s.wheelchair_boarding::text AS wheelchair_boarding,
s.quai_id::text AS quai_id, q.troncon_id_netex::text AS quai_troncon_id_netex,
t.id AS troncon_id, t.source, t.target, t.cost, t.reverse_cost,
t.etat_reseau, t.motifs_exclusion,
s.geom::geometry(Point,3943) AS geom_stop,
t.geom AS geom_quai
FROM transport.vue_stops_quai s
LEFT JOIN geo_standards.quai q ON q.quai_id = s.quai_id
LEFT JOIN pg_temp._iso_se_reseau t ON t.id_netex = q.troncon_id_netex
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
CREATE TEMP TABLE _iso_se_origines ON COMMIT DROP AS
SELECT * FROM pg_temp._iso_se_liaisons WHERE statut_raccord='depart_calculable';

-- amorces
CREATE TEMP TABLE _iso_se_amorces ON COMMIT DROP AS
SELECT o.stop_id, o.lien_id, a.noeud, MIN(a.temps_initial_s) AS temps_initial_s
FROM pg_temp._iso_se_origines o
CROSS JOIN LATERAL (VALUES
 (o.source, o.temps_raccord_s + o.fraction * o.reverse_cost),
 (o.target, o.temps_raccord_s + (1.0-o.fraction) * o.cost)
) a(noeud,temps_initial_s)
WHERE a.temps_initial_s <= 900
GROUP BY o.stop_id,o.lien_id,a.noeud;

-- sql_graphe
CREATE TEMP TABLE _iso_se_sql_graphe ON COMMIT DROP AS
SELECT 'SELECT id, source, target, cost, reverse_cost FROM pg_temp._iso_se_reseau WHERE cost > 0 AND reverse_cost > 0'::text AS sql_reseau;

-- distances_graphe
CREATE TEMP TABLE _iso_se_distances_graphe ON COMMIT DROP AS
SELECT d.from_v,d.node,d.agg_cost
FROM pg_temp._iso_se_sql_graphe g
CROSS JOIN LATERAL public.pgr_drivingDistance(
 g.sql_reseau,
 COALESCE((SELECT ARRAY_AGG(DISTINCT noeud) FROM pg_temp._iso_se_amorces),ARRAY[-1::bigint]),
 900::double precision, true, false
) d;

-- distances
CREATE TEMP TABLE _iso_se_distances ON COMMIT DROP AS
SELECT stop_id,node,MIN(temps_s) AS temps_s FROM (
 SELECT a.stop_id,d.node,a.temps_initial_s+d.agg_cost AS temps_s
 FROM pg_temp._iso_se_amorces a JOIN pg_temp._iso_se_distances_graphe d ON d.from_v=a.noeud
 WHERE a.temps_initial_s+d.agg_cost<=900
 UNION ALL
 SELECT stop_id,noeud,temps_initial_s FROM pg_temp._iso_se_amorces
) x GROUP BY stop_id,node;

-- intervalles
CREATE TEMP TABLE _iso_se_intervalles ON COMMIT DROP AS
SELECT d.stop_id,b.duree_s,e.id AS troncon_id,
0.0::double precision AS f0,
LEAST(1.0,(b.duree_s-d.temps_s)/e.cost) AS f1
FROM pg_temp._iso_se_distances d
JOIN pg_temp._iso_se_reseau e ON e.source=d.node AND e.cost>0
CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
WHERE d.temps_s<b.duree_s
UNION ALL
SELECT d.stop_id,b.duree_s,e.id,
GREATEST(0.0,1.0-(b.duree_s-d.temps_s)/e.reverse_cost),1.0
FROM pg_temp._iso_se_distances d
JOIN pg_temp._iso_se_reseau e ON e.target=d.node AND e.reverse_cost>0
CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
WHERE d.temps_s<b.duree_s
UNION ALL
SELECT o.stop_id,b.duree_s,o.troncon_id,
GREATEST(0.0,o.fraction-(b.duree_s-o.temps_raccord_s)/o.reverse_cost),
LEAST(1.0,o.fraction+(b.duree_s-o.temps_raccord_s)/o.cost)
FROM pg_temp._iso_se_origines o
CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
WHERE o.temps_raccord_s<b.duree_s;

-- intervalles_fusionnes
CREATE TEMP TABLE _iso_se_intervalles_fusionnes ON COMMIT DROP AS
SELECT stop_id,duree_s,troncon_id,
RANGE_AGG(NUMRANGE(f0::numeric,f1::numeric,'[]')) AS plages
FROM pg_temp._iso_se_intervalles WHERE f1>f0 GROUP BY stop_id,duree_s,troncon_id;

-- portions
CREATE TEMP TABLE _iso_se_portions ON COMMIT DROP AS
SELECT i.stop_id,i.duree_s,i.troncon_id,
ST_LineSubstring(e.geom,LOWER(p.plage)::double precision,UPPER(p.plage)::double precision)
::geometry(LineString,3943) AS geom
FROM pg_temp._iso_se_intervalles_fusionnes i
JOIN pg_temp._iso_se_reseau e ON e.id=i.troncon_id
CROSS JOIN LATERAL UNNEST(i.plages) p(plage);

-- isochrones
CREATE TEMP TABLE _iso_se_isochrones ON COMMIT DROP AS
SELECT stop_id,duree_s,COUNT(DISTINCT troncon_id)::integer AS nb_troncons,
ST_Multi(ST_CollectionExtract(ST_UnaryUnion(ST_Collect(geom)),2))
::geometry(MultiLineString,3943) AS geom
FROM pg_temp._iso_se_portions GROUP BY stop_id,duree_s;

-- controle_arrets
CREATE TEMP TABLE _iso_se_controle_arrets ON COMMIT DROP AS
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
FROM pg_temp._iso_se_liaisons GROUP BY stop_id;

-- resultat
CREATE TEMP TABLE _iso_se_resultat ON COMMIT DROP AS
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
FROM pg_temp._iso_se_arrets s CROSS JOIN (VALUES (300),(600),(900)) b(duree_s)
LEFT JOIN pg_temp._iso_se_controle_arrets a ON a.stop_id=s.stop_id
LEFT JOIN pg_temp._iso_se_isochrones i ON i.stop_id=s.stop_id AND i.duree_s=b.duree_s;

-- Table cartographique : 3 lignes par arret, y compris les departs bloques.
CREATE TABLE IF NOT EXISTS iso15min.isochrones_sans_escaliers_300_600_900 AS
SELECT * FROM pg_temp._iso_se_resultat WITH NO DATA;

DELETE FROM iso15min.isochrones_sans_escaliers_300_600_900;
INSERT INTO iso15min.isochrones_sans_escaliers_300_600_900
SELECT * FROM pg_temp._iso_se_resultat;

CREATE UNIQUE INDEX IF NOT EXISTS iso_sans_esc_gid_uidx
ON iso15min.isochrones_sans_escaliers_300_600_900 (gid);
CREATE UNIQUE INDEX IF NOT EXISTS iso_sans_esc_stop_duree_uidx
ON iso15min.isochrones_sans_escaliers_300_600_900 (stop_id, duree_s);
CREATE INDEX IF NOT EXISTS iso_sans_esc_geom_gix
ON iso15min.isochrones_sans_escaliers_300_600_900 USING GIST (geom);

-- Une couche de points permet de voir aussi les arrets sans isochrone.
CREATE TEMP TABLE _iso_se_controle_sortie ON COMMIT DROP AS
SELECT ROW_NUMBER() OVER (ORDER BY s.stop_id)::bigint AS gid,
s.stop_id, s.stop_name, s.wheelchair_boarding,
r.alerte_accessibilite_gtfs, r.quai_ids, r.quai_ids_utilises,
r.nb_departs_calculables, r.statut,
r.raccord_a_verifier, r.distance_raccord_min_m, r.distance_raccord_max_m,
r.temps_raccord_min_s, r.temps_raccord_max_s, r.date_calcul,
s.geom
FROM pg_temp._iso_se_arrets s
JOIN pg_temp._iso_se_resultat r ON r.stop_id=s.stop_id AND r.duree_s=900;

CREATE TABLE IF NOT EXISTS iso15min.controle_stops_sans_escaliers AS
SELECT * FROM pg_temp._iso_se_controle_sortie WITH NO DATA;

DELETE FROM iso15min.controle_stops_sans_escaliers;
INSERT INTO iso15min.controle_stops_sans_escaliers
SELECT * FROM pg_temp._iso_se_controle_sortie;

CREATE UNIQUE INDEX IF NOT EXISTS controle_stops_sans_escaliers_gid_uidx
ON iso15min.controle_stops_sans_escaliers (gid);
CREATE UNIQUE INDEX IF NOT EXISTS controle_stops_sans_escaliers_stop_uidx
ON iso15min.controle_stops_sans_escaliers (stop_id);
CREATE INDEX IF NOT EXISTS controle_stops_sans_escaliers_geom_gix
ON iso15min.controle_stops_sans_escaliers USING GIST (geom);

-- Raccords droits a verifier visuellement/terrain.
CREATE TEMP TABLE _iso_se_raccords_sortie ON COMMIT DROP AS
SELECT lien_id AS gid, stop_id, stop_name, wheelchair_boarding, quai_id,
quai_troncon_id_netex, troncon_id, source, target,
fraction, distance_raccord_m, temps_raccord_s,
cost AS cout_quai_s, etat_reseau AS etat_quai, motifs_exclusion,
statut_raccord, raccord_a_verifier,
CURRENT_TIMESTAMP AS date_calcul,
CASE WHEN distance_raccord_m > 0
     THEN geom ELSE NULL END::geometry(LineString,3943) AS geom
FROM pg_temp._iso_se_liaisons;

CREATE TABLE IF NOT EXISTS iso15min.raccords_sans_escaliers AS
SELECT * FROM pg_temp._iso_se_raccords_sortie WITH NO DATA;

DELETE FROM iso15min.raccords_sans_escaliers;
INSERT INTO iso15min.raccords_sans_escaliers
SELECT * FROM pg_temp._iso_se_raccords_sortie;

CREATE UNIQUE INDEX IF NOT EXISTS raccords_sans_escaliers_gid_uidx
ON iso15min.raccords_sans_escaliers (gid);
CREATE INDEX IF NOT EXISTS raccords_sans_escaliers_geom_gix
ON iso15min.raccords_sans_escaliers USING GIST (geom);

COMMENT ON TABLE iso15min.isochrones_sans_escaliers_300_600_900 IS
'Scenario theorique a 6 km/h, uniquement les escaliers exclus. Pente, devers, largeur, revetement, obstacles et travaux ignores. Raccords droits supposes praticables a 6 km/h, a verifier. Les arrets GTFS wheelchair_boarding=2 sont signales.';
COMMENT ON TABLE iso15min.controle_stops_sans_escaliers IS
'Controle des departs : un point par stop, y compris ceux dont le quai est bloque.';
COMMENT ON TABLE iso15min.raccords_sans_escaliers IS
'Raccords geometriques au quai associe : leur praticabilite reste a verifier. Aucun raccord a un autre troncon ne contourne un quai bloque.';

ANALYZE iso15min.isochrones_sans_escaliers_300_600_900;
ANALYZE iso15min.controle_stops_sans_escaliers;
ANALYZE iso15min.raccords_sans_escaliers;

-- Trois couches separees pour QGIS, une par duree.
CREATE OR REPLACE VIEW iso15min.v_iso_sans_escaliers_300s
WITH (security_invoker = true) AS
SELECT * FROM iso15min.isochrones_sans_escaliers_300_600_900
WHERE duree_s = 300;

CREATE OR REPLACE VIEW iso15min.v_iso_sans_escaliers_600s
WITH (security_invoker = true) AS
SELECT * FROM iso15min.isochrones_sans_escaliers_300_600_900
WHERE duree_s = 600;

CREATE OR REPLACE VIEW iso15min.v_iso_sans_escaliers_900s
WITH (security_invoker = true) AS
SELECT * FROM iso15min.isochrones_sans_escaliers_300_600_900
WHERE duree_s = 900;

COMMIT;

-- CONTROLE 1 : nombre de resultats par duree.
SELECT duree_s, statut, COUNT(*) AS nb_arrets
FROM iso15min.isochrones_sans_escaliers_300_600_900
GROUP BY duree_s, statut
ORDER BY duree_s, statut;

-- CONTROLE 2 : aucune ligne attendue (unicite stop/duree).
SELECT stop_id, duree_s, COUNT(*)
FROM iso15min.isochrones_sans_escaliers_300_600_900
GROUP BY stop_id, duree_s
HAVING COUNT(*) > 1;

-- CONTROLE 3 : arrets a examiner.
SELECT stop_id, stop_name, wheelchair_boarding, statut,
       distance_raccord_max_m, raccord_a_verifier
FROM iso15min.controle_stops_sans_escaliers
WHERE statut <> 'calcule'
   OR alerte_accessibilite_gtfs
   OR raccord_a_verifier
ORDER BY stop_id;

-- QGIS
-- Ajouter iso15min.isochrones_sans_escaliers_300_600_900 :
--   geometrie = geom ; identifiant unique = gid ; SCR = EPSG:3943.
-- Symbologie categorisee sur duree_s : 300, 600, 900.
-- Afficher d'abord 900, puis 600, puis 300 pour eviter le masquage.
-- Filtre pour les seules geometries calculees : "statut" = 'calcule'.
-- Pour les stops avec embarquement declare accessible, ajouter :
--   AND "wheelchair_boarding" = '1'
-- Ajouter controle_stops_sans_escaliers et raccords_sans_escaliers pour le diagnostic.
-- Reexecuter ce script apres toute modification du reseau ou des stops.


