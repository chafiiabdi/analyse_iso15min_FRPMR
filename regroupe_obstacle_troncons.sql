CREATE OR REPLACE VIEW iso15min.v_troncons_criteres_obstacles
WITH (security_invoker = true) AS

WITH groupes AS (
    SELECT
        o.gid_tronco,

        COUNT(*) FILTER (
            WHERE COALESCE(LOWER(BTRIM(o.typeobstac)), '')
            NOT IN (
                'travaux',
                'pente ponctuelle forte',
                'dévers ponctuel fort'
            )
        ) AS nb_obstacles,

        COUNT(*) FILTER (
            WHERE LOWER(BTRIM(o.typeobstac)) = 'travaux'
        ) AS nb_obstacles_travaux_exclus,

        STRING_AGG(
            DISTINCT NULLIF(BTRIM(o.typeobstac), ''),
            ' | ' ORDER BY NULLIF(BTRIM(o.typeobstac), '')
        ) FILTER (
            WHERE COALESCE(LOWER(BTRIM(o.typeobstac)), '')
            NOT IN (
                'travaux',
                'pente ponctuelle forte',
                'dévers ponctuel fort'
            )
        ) AS types_obstacles,

        STRING_AGG(
            DISTINCT NULLIF(BTRIM(o.posobstac), ''),
            ' | ' ORDER BY NULLIF(BTRIM(o.posobstac), '')
        ) FILTER (
            WHERE COALESCE(LOWER(BTRIM(o.typeobstac)), '')
            NOT IN (
                'travaux',
                'pente ponctuelle forte',
                'dévers ponctuel fort'
            )
        ) AS positions_obstacles,

        JSONB_AGG(
            TO_JSONB(o) ORDER BY o.id
        ) FILTER (
            WHERE COALESCE(LOWER(BTRIM(o.typeobstac)), '')
            NOT IN (
                'travaux',
                'pente ponctuelle forte',
                'dévers ponctuel fort'
            )
        ) AS obstacles_details

    FROM geo_standards.obstacle AS o
    GROUP BY o.gid_tronco
)

SELECT
    t.*,
    COALESCE(o.nb_obstacles, 0::bigint) AS nb_obstacles,
    COALESCE(o.nb_obstacles, 0::bigint) > 0 AS obstacle_reference,
    o.types_obstacles,
    o.positions_obstacles,
    COALESCE(o.obstacles_details, '[]'::jsonb) AS obstacles_details,
    COALESCE(o.nb_obstacles_travaux_exclus, 0::bigint)
        AS nb_obstacles_travaux_exclus

FROM iso15min.v_troncons_criteres_base AS t
LEFT JOIN groupes AS o
    ON o.gid_tronco = t.id_netex;
