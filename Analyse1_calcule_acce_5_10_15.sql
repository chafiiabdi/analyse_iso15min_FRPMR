-- ISOCHRONES EXPLORATOIRES DEPUIS transport.acces_arret_bus_prio
-- Exécuter TOUT le fichier dans une même session. En cas d'erreur : ROLLBACK;
-- 6 km/h sur les tronçons admissibles ou À vérifier ; autres états exclus.
-- Les règles actuelles utilisent les critères des fiches, sans ajout du MNT.
-- Quai choisi spatialement à 30 m maximum AVANT contrôle d'accessibilité.
-- Tous les raccords restent à vérifier : leur faisabilité physique n'est pas démontrée.
-- Temps du raccord inclus ; sa longueur exclue des longueurs de réseau.
-- Intervalles fusionnés par tronçon et durée avant création des géométries.
-- Couches globales tous arrêts confondus, cumulatives 0-300 / 0-600 / 0-900 s.
-- Le script remplace uniquement ses propres sorties *_exploratoire*.
BEGIN;
SET LOCAL statement_timeout='300s';
CREATE OR REPLACE VIEW iso15min.v_troncons_couts_exploratoire
WITH (security_invoker=true) AS
SELECT id,id_netex,source,target,typtronco,longueur_m,
CASE WHEN etat_analyse IN ('Admissible selon les critères contrôlés','À vérifier') THEN 6.0 ELSE 0.0 END AS vitesse_kmh,
etat_analyse,
CASE WHEN etat_analyse IN ('Admissible selon les critères contrôlés','À vérifier') AND longueur_m>0
THEN longueur_m*3.6/6.0 ELSE -1.0 END::float8 AS cost,
CASE WHEN etat_analyse IN ('Admissible selon les critères contrôlés','À vérifier') AND longueur_m>0
THEN longueur_m*3.6/6.0 ELSE -1.0 END::float8 AS reverse_cost,
geom::geometry(LineString,3943) AS geom
FROM iso15min.v_troncons_regles_pmr;

-- reseau
CREATE TEMP TABLE _iso_pmr_reseau ON COMMIT DROP AS
SELECT * FROM iso15min.v_troncons_couts_exploratoire;

CREATE UNIQUE INDEX ON _iso_pmr_reseau (id);
CREATE INDEX ON _iso_pmr_reseau (source);
CREATE INDEX ON _iso_pmr_reseau (target);
ANALYZE _iso_pmr_reseau;

DO $controle$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_temp._iso_pmr_reseau
        WHERE id IS NULL OR source IS NULL OR target IS NULL
           OR source <= 0 OR target <= 0
           OR longueur_m IS NULL OR longueur_m <= 0
           OR geom IS NULL OR ST_IsEmpty(geom) OR ST_Length(geom) <= 0
    ) THEN
        RAISE EXCEPTION 'Reseau incomplet : verifier noeuds, longueurs et geometries.';
    END IF;
END
$controle$;

-- Tous les points de la couche demandée (sans filtrage actif/prioritaire).
CREATE TEMP TABLE _iso_pmr_arrets ON COMMIT DROP AS
SELECT id::text AS stop_id,nom::text AS stop_name,geom::geometry(Point,3943) AS geom
FROM transport.acces_arret_bus_prio;

-- Association spatiale exploratoire : quai le plus proche à 30 m maximum.
-- Ne PAS filtrer les quais bloqués avant le choix du plus proche.
CREATE TEMP TABLE _iso_pmr_liaisons ON COMMIT DROP AS
WITH bruts AS (
SELECT a.stop_id,a.stop_name,t.id AS troncon_id,t.id_netex,
t.source,t.target,t.cost,t.reverse_cost,t.etat_analyse,
a.geom AS geom_stop,t.geom AS geom_quai,
(SELECT string_agg(DISTINCT q.quai_id,' / ' ORDER BY q.quai_id)
 FROM geo_standards.quai q WHERE q.troncon_id_netex=t.id_netex) AS quai_ids,
(SELECT count(*) FROM pg_temp._iso_pmr_reseau e
 WHERE lower(btrim(e.typtronco))='quai' AND ST_DWithin(a.geom,e.geom,30)) AS nb_quais_candidats
FROM pg_temp._iso_pmr_arrets a
LEFT JOIN LATERAL (
 SELECT e.* FROM pg_temp._iso_pmr_reseau e
 WHERE lower(btrim(e.typtronco))='quai' AND ST_DWithin(a.geom,e.geom,30)
 ORDER BY ST_Distance(a.geom,e.geom),e.id LIMIT 1
) t ON true
), projections AS (
SELECT b.*,ST_Distance(geom_stop,geom_quai) AS distance_raccord_m,
ST_LineLocatePoint(geom_quai,geom_stop) AS fraction,
ST_ClosestPoint(geom_quai,geom_stop) AS geom_projection
FROM bruts b
)
SELECT row_number() OVER(ORDER BY stop_id)::bigint AS lien_id,p.*,
distance_raccord_m*3.6/6.0 AS temps_raccord_s,
ST_MakeLine(geom_stop,geom_projection)::geometry(LineString,3943) AS geom,
true AS raccord_a_verifier,
CASE WHEN geom_stop IS NULL OR ST_IsEmpty(geom_stop) THEN 'geometrie_absente'
 WHEN troncon_id IS NULL THEN 'aucun_quai_a_30m'
 WHEN cost<=0 OR reverse_cost<=0 THEN 'quai_exclu'
 ELSE 'depart_calculable' END AS statut_raccord
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
SELECT COALESCE((to_jsonb(d)->>'start_vid')::bigint,
                (to_jsonb(d)->>'from_v')::bigint) AS from_v,
       d.node, d.agg_cost
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


-- Snapshot des 70 départs et de leurs raccords (y compris les échecs).
CREATE TABLE IF NOT EXISTS iso15min.raccords_arrets_exploratoire AS
SELECT * FROM pg_temp._iso_pmr_liaisons WITH NO DATA;
DELETE FROM iso15min.raccords_arrets_exploratoire;
INSERT INTO iso15min.raccords_arrets_exploratoire SELECT * FROM pg_temp._iso_pmr_liaisons;
CREATE UNIQUE INDEX IF NOT EXISTS raccords_arrets_exploratoire_id_idx
ON iso15min.raccords_arrets_exploratoire(lien_id);
CREATE INDEX IF NOT EXISTS raccords_arrets_exploratoire_geom_idx
ON iso15min.raccords_arrets_exploratoire USING gist(geom);
ALTER TABLE iso15min.raccords_arrets_exploratoire ENABLE ROW LEVEL SECURITY;

CREATE TEMP TABLE _iso_explo_resultat ON COMMIT DROP AS
WITH globaux AS (
SELECT duree_s,troncon_id,range_agg(numrange(f0::numeric,f1::numeric,'[]')) AS plages
FROM pg_temp._iso_pmr_intervalles WHERE f1>f0 GROUP BY duree_s,troncon_id
), portions AS (
SELECT g.duree_s,g.troncon_id,e.etat_analyse,
ST_LineSubstring(e.geom,lower(p.plage)::float8,upper(p.plage)::float8)::geometry(LineString,3943) AS geom
FROM globaux g JOIN pg_temp._iso_pmr_reseau e ON e.id=g.troncon_id
CROSS JOIN LATERAL unnest(g.plages) p(plage)
), synthese AS (
SELECT duree_s,count(DISTINCT troncon_id)::integer AS nb_troncons,
sum(ST_Length(geom))::float8 AS distance_reseau_m,
COALESCE(sum(ST_Length(geom)) FILTER(WHERE etat_analyse='À vérifier'),0)::float8 AS distance_a_verifier_m,
ST_Multi(ST_Collect(geom))::geometry(MultiLineString,3943) AS geom
FROM portions GROUP BY duree_s
)
SELECT b.duree_s::bigint AS gid,b.duree_s,b.duree_s/60 AS duree_minutes,
COALESCE(s.nb_troncons,0) AS nb_troncons,
COALESCE(s.distance_reseau_m,0)::float8 AS distance_reseau_m,
COALESCE(s.distance_a_verifier_m,0)::float8 AS distance_a_verifier_m,
'Exploratoire : accessibilité potentielle sous réserve de vérification'::text AS scenario,
CURRENT_TIMESTAMP AS date_calcul,s.geom
FROM (VALUES (300),(600),(900)) b(duree_s) LEFT JOIN synthese s USING(duree_s);

CREATE TABLE IF NOT EXISTS iso15min.isochrones_globaux_exploratoire AS
SELECT * FROM pg_temp._iso_explo_resultat WITH NO DATA;
DELETE FROM iso15min.isochrones_globaux_exploratoire;
INSERT INTO iso15min.isochrones_globaux_exploratoire SELECT * FROM pg_temp._iso_explo_resultat;
CREATE UNIQUE INDEX IF NOT EXISTS isochrones_globaux_exploratoire_id_idx
ON iso15min.isochrones_globaux_exploratoire(gid);
CREATE INDEX IF NOT EXISTS isochrones_globaux_exploratoire_geom_idx
ON iso15min.isochrones_globaux_exploratoire USING gist(geom);
ALTER TABLE iso15min.isochrones_globaux_exploratoire ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE VIEW iso15min.isochrones_exploratoire_300s
WITH (security_invoker=true) AS
SELECT * FROM iso15min.isochrones_globaux_exploratoire WHERE duree_s=300;

CREATE OR REPLACE VIEW iso15min.isochrones_exploratoire_600s
WITH (security_invoker=true) AS
SELECT * FROM iso15min.isochrones_globaux_exploratoire WHERE duree_s=600;

CREATE OR REPLACE VIEW iso15min.isochrones_exploratoire_900s
WITH (security_invoker=true) AS
SELECT * FROM iso15min.isochrones_globaux_exploratoire WHERE duree_s=900;

-- Vérifier que la longueur globale ne diminue jamais avec le temps.
DO $controle$
BEGIN
 IF EXISTS (SELECT 1 FROM (
 SELECT distance_reseau_m,LAG(distance_reseau_m) OVER(ORDER BY duree_s) AS precedente
 FROM iso15min.isochrones_globaux_exploratoire
 ) x WHERE distance_reseau_m < precedente - 0.000001)
 THEN RAISE EXCEPTION 'Erreur : distances non cumulatives'; END IF;
END
$controle$;
COMMIT;

SELECT duree_s,nb_troncons,round(distance_reseau_m::numeric,2) AS distance_reseau_m,
round(distance_a_verifier_m::numeric,2) AS distance_a_verifier_m
FROM iso15min.isochrones_globaux_exploratoire ORDER BY duree_s;

SELECT statut_raccord,count(*) AS nombre_arrets
FROM iso15min.raccords_arrets_exploratoire GROUP BY statut_raccord;
-- QGIS : ajouter les trois vues isochrones_exploratoire_*s ; identifiant gid.
-- SCR EPSG:3943. Pour GeoJSON web, exporter en EPSG:4326.
-- Les colonnes attributaires sont scalaires (pas de listes ni JSON).
