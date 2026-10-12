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

