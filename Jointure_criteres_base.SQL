CREATE OR REPLACE VIEW iso15min.v_troncons_criteres_base AS
SELECT
    t.*,

    CASE
        WHEN LOWER(BTRIM(t.typtronco)) = 'quai' THEN '0'
        ELSE COALESCE(
            NULLIF(BTRIM(c.pente), ''),
            NULLIF(BTRIM(tr.pente), ''),
            NULLIF(BTRIM(r.pente), '')
        )
    END AS pente,

    CASE
        WHEN LOWER(BTRIM(t.typtronco)) = 'quai' THEN '0'
        ELSE COALESCE(
            NULLIF(BTRIM(c.devers), ''),
            NULLIF(BTRIM(tr.devers), ''),
            NULLIF(BTRIM(r.devers), '')
        )
    END AS devers,

    COALESCE(
        NULLIF(BTRIM(c.largutile::text), ''),
        NULLIF(BTRIM(tr.largilot::text), ''),
        NULLIF(BTRIM(r.largutile::text), ''),
        NULLIF(BTRIM(q."largeurPassage"::text), '')
    ) AS largutile,

    COALESCE(
        NULLIF(BTRIM(c.etarevet), ''),
        NULLIF(BTRIM(tr.etarevet), ''),
        NULLIF(BTRIM(r.etarevet), '')
    ) AS etarevet

FROM iso15min.v_troncons_pgrouting_pmr_v2 t

LEFT JOIN geo_standards.vue_circulation c
    ON t.id_netex = c.gid_tronco

LEFT JOIN geo_standards.traversee tr
    ON t.id_netex = tr.gid_tronco

LEFT JOIN geo_standards.rampe r
    ON t.id_netex = r.gid_tronco

LEFT JOIN geo_standards.quai q
    ON t.id_netex = q.troncon_id_netex;
