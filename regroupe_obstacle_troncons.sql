CREATE OR REPLACE VIEW iso15min.v_troncons_obstacles_largeur AS

WITH valeurs AS (
    SELECT
        gid_tronco,
        typeobstac,
        CASE
            WHEN REPLACE(BTRIM(largutile), ',', '.')
                 ~ '^[0-9]+([.][0-9]+)?$'
            THEN REPLACE(BTRIM(largutile), ',', '.')::numeric
        END AS largeur
    FROM geo_standards.obstacle
),

regroupement AS (
    SELECT
        gid_tronco,
        COUNT(*) AS nb_obstacles,

        STRING_AGG(
            DISTINCT typeobstac,
            ' ; ' ORDER BY typeobstac
        ) AS types_obstacles,

        MIN(largeur) FILTER (
            WHERE largeur NOT IN (8888, 9999)
        ) AS largeur_min_mesuree_m,

        COUNT(*) FILTER (
            WHERE largeur IN (8888, 9999)
        ) AS nb_largeurs_sup_180,

        COUNT(*) FILTER (
            WHERE largeur IS NULL
        ) AS nb_largeurs_non_renseignees

    FROM valeurs
    GROUP BY gid_tronco
)

SELECT
    t.*,
    COALESCE(o.nb_obstacles, 0) AS nb_obstacles,
    o.types_obstacles,
    o.largeur_min_mesuree_m,
    COALESCE(o.nb_largeurs_sup_180, 0) AS nb_largeurs_sup_180,
    COALESCE(o.nb_largeurs_non_renseignees, 0)
        AS nb_largeurs_non_renseignees,

    CASE
        WHEN o.gid_tronco IS NULL
            THEN 'Aucun obstacle'

        WHEN o.largeur_min_mesuree_m <= 1.80
            THEN 'Minimum mesuré disponible'

        WHEN o.nb_largeurs_sup_180 > 0
            THEN 'Supérieur à 1,80 m : minimum exact indéterminé'

        WHEN o.largeur_min_mesuree_m IS NOT NULL
            THEN 'Minimum mesuré disponible'

        ELSE 'Largeur non renseignée'
    END AS information_largeur_obstacles

FROM iso15min.v_troncons_criteres_base t

LEFT JOIN regroupement o
    ON t.id_netex = o.gid_tronco;
