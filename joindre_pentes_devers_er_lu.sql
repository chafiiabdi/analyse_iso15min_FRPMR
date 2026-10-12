CREATE OR REPLACE VIEW iso15min.v_troncons_criteres_base
WITH (security_invoker = true) AS

SELECT
    t.*,

    -- Pente
    COALESCE(
        NULLIF(BTRIM(c.pente), ''),
        NULLIF(BTRIM(r.pente), '')
    ) AS pente,

    -- Dévers
    COALESCE(
        NULLIF(BTRIM(c.devers), ''),
        NULLIF(BTRIM(r.devers), '')
    ) AS devers,

    -- État du revêtement
    COALESCE(
        NULLIF(BTRIM(c.etarevet), ''),
        NULLIF(BTRIM(r.etarevet), ''),
        NULLIF(BTRIM(q."etatRevetment"), '')
    ) AS etarevet,

    -- Présence des fiches associées
    c.id IS NOT NULL AS fiche_circulation_presente,
    r.id IS NOT NULL AS fiche_rampe_presente,
    q.id IS NOT NULL AS fiche_quai_presente,

    -- Largeur utile
    COALESCE(
        NULLIF(BTRIM(c.largutile), ''),
        NULLIF(BTRIM(r.largutile), ''),
        NULLIF(BTRIM(q."largeurPassage"), '')
    ) AS largutile

FROM iso15min.v_troncons_pgrouting_pmr_v2 AS t

LEFT JOIN geo_standards.vue_circulation AS c
    ON c.gid_tronco = t.id_netex

LEFT JOIN geo_standards.rampe AS r
    ON r.gid_tronco = t.id_netex

LEFT JOIN geo_standards.quai AS q
    ON q.troncon_id_netex = t.id_netex;
