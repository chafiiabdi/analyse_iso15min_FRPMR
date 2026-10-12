--calculer les règles PMR

CREATE OR REPLACE VIEW iso15min.v_troncons_regles_pmr
WITH (security_invoker = true) AS

WITH base AS MATERIALIZED (
    SELECT *
    FROM iso15min.v_troncons_criteres_obstacles
),

mesures_brutes AS (
    -- Pente et dévers : uniquement les valeurs du tronçon
    SELECT
        t.id,
        v.critere,
        v.texte

    FROM base AS t

    CROSS JOIN LATERAL (
        VALUES
            ('largeur', t.largutile),
            ('pente', t.pente),
            ('devers', t.devers)
    ) AS v(critere, texte)

    UNION ALL

    -- Obstacles : largeur disponible et hauteur des ressauts
    SELECT
        t.id,
        v.critere,
        v.texte

    FROM base AS t

    CROSS JOIN LATERAL
        JSONB_ARRAY_ELEMENTS(t.obstacles_details) AS e(fiche)

    CROSS JOIN LATERAL (
        SELECT
            'largeur'::text AS critere,
            e.fiche ->> 'largutile' AS texte

        UNION ALL

        SELECT
            'ressaut',
            e.fiche ->> 'htobstacso'

        WHERE LOWER(BTRIM(e.fiche ->> 'typeobstac'))
                  LIKE 'ressaut%'
           OR LOWER(BTRIM(e.fiche ->> 'typeobstac'))
                  = 'rupture de niveau'
    ) AS v
),

conversion AS (
    SELECT
        id,
        critere,

        CASE
            WHEN REPLACE(BTRIM(texte), ',', '.')
                 ~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$'
            THEN REPLACE(BTRIM(texte), ',', '.')::numeric
        END AS valeur

    FROM mesures_brutes
),

nettoyage AS (
    SELECT
        id,
        critere,

        CASE
            WHEN ABS(valeur) = 8888 THEN NULL

            -- Largeur 0 = non renseignée
            WHEN critere = 'largeur'
                 AND valeur <= 0 THEN NULL

            -- Le code 9999 reste utilisable pour la largeur
            WHEN critere <> 'largeur'
                 AND ABS(valeur) = 9999 THEN NULL

            WHEN critere = 'ressaut'
                 AND valeur < 0 THEN NULL

            ELSE valeur
        END AS valeur

    FROM conversion
),

resume AS (
    SELECT
        id,

        MIN(valeur) FILTER (
            WHERE critere = 'largeur'
              AND valeur <> 9999
        ) AS largeur_min_mesuree_m,

        COALESCE(
            BOOL_OR(valeur = 9999) FILTER (
                WHERE critere = 'largeur'
            ),
            false
        ) AS largeur_code_9999_present,

        MAX(ABS(valeur)) FILTER (
            WHERE critere = 'pente'
        ) AS pente_max_abs_pct,

        MAX(ABS(valeur)) FILTER (
            WHERE critere = 'devers'
        ) AS devers_max_abs_pct,

        COUNT(*) FILTER (
            WHERE valeur IS NULL
        ) AS nb_mesures_non_exploitables,

        MAX(valeur) FILTER (
            WHERE critere = 'ressaut'
        ) AS ressaut_max_m,

        COUNT(*) FILTER (
            WHERE critere = 'ressaut'
              AND valeur IS NULL
        ) AS nb_obstacles_hauteur_a_traiter

    FROM nettoyage
    GROUP BY id
),

regles AS (
    SELECT
        r.*,

        CASE
            WHEN r.largeur_min_mesuree_m < 0.80 THEN 0
            WHEN r.largeur_min_mesuree_m < 1.20 THEN 3
            ELSE 6
        END AS vitesse_largeur_kmh,

        CASE
            WHEN r.pente_max_abs_pct IS NULL THEN 6

            -- Pente courante strictement inférieure à 5 %
            WHEN r.pente_max_abs_pct < 5 THEN 6

            WHEN r.pente_max_abs_pct > 12 THEN 0

            -- Longueur inconnue : aucune pénalité liée à sa valeur
            WHEN t.longueur_m IS NULL
                 OR t.longueur_m <= 0 THEN 6

            -- Tolérances potentielles, à justifier
            WHEN r.pente_max_abs_pct <= 8
                 AND t.longueur_m <= 2 THEN 3

            WHEN r.pente_max_abs_pct <= 12
                 AND t.longueur_m <= 0.50 THEN 3

            ELSE 0
        END AS vitesse_pente_kmh,

        CASE
            WHEN r.devers_max_abs_pct > 4 THEN 0
            WHEN r.devers_max_abs_pct > 2 THEN 3
            ELSE 6
        END AS vitesse_devers_kmh,

        CASE
            WHEN LOWER(BTRIM(t.etarevet)) IN (
                'meuble',
                'glissant',
                'dégradation entraînant un problème de sécurité immédiat'
            ) THEN 0

            WHEN LOWER(BTRIM(t.etarevet)) = 'secouant'
                THEN 3

            ELSE 6
        END AS vitesse_revetement_kmh,

        CASE
            WHEN LOWER(BTRIM(t.typtronco)) = 'escalier'
                THEN 0
            ELSE 6
        END AS vitesse_type_kmh,

        -- Hauteurs stockées en mètres
        CASE
            WHEN r.ressaut_max_m > 0.04 THEN 0
            WHEN r.ressaut_max_m > 0.02 THEN 3
            ELSE 6
        END AS vitesse_ressaut_kmh

    FROM resume AS r

    JOIN base AS t
        ON t.id = r.id
),

vitesses AS (
    SELECT
        r.*,

        LEAST(
            vitesse_largeur_kmh,
            vitesse_pente_kmh,
            vitesse_devers_kmh,
            vitesse_revetement_kmh,
            vitesse_type_kmh,
            vitesse_ressaut_kmh
        ) AS vitesse_pmr_kmh

    FROM regles AS r
)

SELECT
    -- Conserver l'ordre des colonnes existantes
    t.*,
    v.largeur_min_mesuree_m,
    v.largeur_code_9999_present,
    v.pente_max_abs_pct,
    v.devers_max_abs_pct,
    v.nb_mesures_non_exploitables,
    v.vitesse_largeur_kmh,
    v.vitesse_pente_kmh,
    v.vitesse_devers_kmh,
    v.vitesse_revetement_kmh,
    v.vitesse_type_kmh,
    v.nb_obstacles_hauteur_a_traiter,
    v.vitesse_pmr_kmh,

    CASE
        WHEN v.vitesse_pmr_kmh = 0 THEN 'bloqué'
        WHEN v.vitesse_pmr_kmh = 3 THEN 'ralenti'
        ELSE 'sans pénalité connue'
    END AS etat_pmr,

    ARRAY_REMOVE(
        ARRAY[
            CASE WHEN v.vitesse_largeur_kmh < 6
                THEN 'largeur' END,

            CASE WHEN v.vitesse_pente_kmh < 6
                THEN 'pente' END,

            CASE WHEN v.vitesse_devers_kmh < 6
                THEN 'dévers' END,

            CASE WHEN v.vitesse_revetement_kmh < 6
                THEN 'revêtement' END,

            CASE WHEN v.vitesse_type_kmh < 6
                THEN 'escalier' END,

            CASE WHEN v.vitesse_ressaut_kmh < 6
                THEN 'ressaut / rupture de niveau' END
        ],
        NULL
    ) AS criteres_penalisants,

    -- Nouvelles colonnes ajoutées à la fin
    v.ressaut_max_m,
    v.vitesse_ressaut_kmh,
    v.vitesse_pente_kmh = 3 AS pente_tolerance_a_justifier,
    t.longueur_m AS longueur_pente_assimilee_m

FROM base AS t

JOIN vitesses AS v
    ON v.id = t.id;

COMMIT;
