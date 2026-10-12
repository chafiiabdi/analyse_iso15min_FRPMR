CREATE OR REPLACE VIEW iso15min.v_troncons_criteres_obstacles
WITH (security_invoker = true) AS

WITH obstacles_groupes AS (
    SELECT
        o.gid_tronco,

        -- Nombre d'obstacles retenus, hors travaux
        COUNT(*) FILTER (
            WHERE LOWER(BTRIM(o.typeobstac))
                  IS DISTINCT FROM 'travaux'
        ) AS nb_obstacles,

        -- Traçabilité des obstacles exclus
        COUNT(*) FILTER (
            WHERE LOWER(BTRIM(o.typeobstac)) = 'travaux'
        ) AS nb_obstacles_travaux_exclus,

        -- Liste des types d'obstacles présents
        STRING_AGG(
            DISTINCT NULLIF(BTRIM(o.typeobstac), ''),
            ' | ' ORDER BY NULLIF(BTRIM(o.typeobstac), '')
        ) FILTER (
            WHERE LOWER(BTRIM(o.typeobstac))
                  IS DISTINCT FROM 'travaux'
        ) AS types_obstacles,

        -- Liste des positions : au sol, en surface, etc.
        STRING_AGG(
            DISTINCT NULLIF(BTRIM(o.posobstac), ''),
            ' | ' ORDER BY NULLIF(BTRIM(o.posobstac), '')
        ) FILTER (
            WHERE LOWER(BTRIM(o.typeobstac))
                  IS DISTINCT FROM 'travaux'
        ) AS positions_obstacles,

        -- Conservation de toutes les caractéristiques
        -- de chaque obstacle retenu
        JSONB_AGG(
            TO_JSONB(o) ORDER BY o.id
        ) FILTER (
            WHERE LOWER(BTRIM(o.typeobstac))
                  IS DISTINCT FROM 'travaux'
        ) AS obstacles_details

    FROM geo_standards.obstacle AS o

    GROUP BY o.gid_tronco
)

SELECT
    t.*,

    COALESCE(o.nb_obstacles, 0::bigint)
        AS nb_obstacles,

    COALESCE(o.nb_obstacles, 0::bigint) > 0
        AS obstacle_reference,

    o.types_obstacles,

    o.positions_obstacles,

    COALESCE(o.obstacles_details, '[]'::jsonb)
        AS obstacles_details,

    COALESCE(o.nb_obstacles_travaux_exclus, 0::bigint)
        AS nb_obstacles_travaux_exclus

FROM iso15min.v_troncons_criteres_base AS t

LEFT JOIN obstacles_groupes AS o
    ON o.gid_tronco = t.id_netex;
