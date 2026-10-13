CREATE OR REPLACE VIEW analyses.v_troncons_pgrouting_pmr_v2
WITH (security_invoker = true) AS

WITH troncons AS (
    SELECT
        t."idTroncon"::bigint AS id,
        t.troncon_id_netex AS id_netex,

        t.noeud_depart_id::bigint AS source,
        t.noeud_arrivee_id::bigint AS target,

        t.typetronco AS typtronco,
        t.statutvoi,

        CASE
            WHEN NULLIF(
                REPLACE(BTRIM(t.distance), ',', '.'),
                ''
            )::double precision > 0
            THEN REPLACE(
                BTRIM(t.distance), ',', '.'
            )::double precision

            ELSE ST_Length(t.geom)
        END::double precision AS longueur_m,

        t.geom::geometry(LineString, 3943) AS geom

    FROM geo_standards.troncon_cheminement AS t
)

SELECT
    id,
    id_netex,
    source,
    target,
    typtronco,
    statutvoi,
    longueur_m,
    longueur_m AS cost,
    longueur_m AS reverse_cost,
    geom
FROM troncons;
