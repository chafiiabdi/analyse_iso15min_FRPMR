
CREATE OR REPLACE VIEW iso15min.v_simulation_pmr_isochrones AS
SELECT
    p.gid,
    p.acces_id,
    d.nom AS nom_acces,
    p.reseau,
    p.duree_s,
    p.troncon_id,
    r.id_netex,
    r.typtronco,
    r.origine,
    r.classe_pmr,
    r.motifs,
    r.informations_manquantes,
    r.vitesse_kmh,
    r.pente_pct,
    r.devers_pct,
    r.largeur_effective_m,
    r.largeur_superieure_180,
    r.ressaut_m,
    r.etat_revetement,
    p.fraction_debut,
    p.fraction_fin,
    p.longueur_atteinte_m,
    d.statut_raccord,
    p.date_calcul,

    ST_LineSubstring(
        r.geom,
        p.fraction_debut,
        p.fraction_fin
    )::geometry(LineString, 3943) AS geom

FROM iso15min.mv_simulation_pmr_portions p

JOIN iso15min.mv_simulation_pmr_reseau r
    ON r.reseau = p.reseau
   AND r.id = p.troncon_id

JOIN iso15min.v_simulation_pmr_departs d
    ON d.reseau = p.reseau
   AND d.acces_id = p.acces_id;

CREATE OR REPLACE VIEW iso15min.v_simulation_pmr_300s AS
SELECT *
FROM iso15min.v_simulation_pmr_isochrones
WHERE duree_s = 300;


CREATE OR REPLACE VIEW iso15min.v_simulation_pmr_600s AS
SELECT *
FROM iso15min.v_simulation_pmr_isochrones
WHERE duree_s = 600;


CREATE OR REPLACE VIEW iso15min.v_simulation_pmr_900s AS
SELECT *
FROM iso15min.v_simulation_pmr_isochrones
WHERE duree_s = 900;

