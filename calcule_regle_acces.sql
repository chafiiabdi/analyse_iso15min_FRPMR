CREATE OR REPLACE VIEW iso15min.v_troncons_regles_pmr AS

WITH
-- 1. Convertir les trois critères textuels en nombres.
nombres AS (
    SELECT
        t.*,
        n.pente_num,
        n.devers_num,
        n.largeur_num

    FROM iso15min.v_troncons_obstacles_largeur t

    CROSS JOIN LATERAL (
        SELECT
            MAX(x) FILTER (WHERE cle = 'p') AS pente_num,
            MAX(x) FILTER (WHERE cle = 'd') AS devers_num,
            MAX(x) FILTER (WHERE cle = 'l') AS largeur_num
        FROM (
            SELECT
                cle,
                CASE
                    WHEN REPLACE(BTRIM(val), ',', '.')
                         ~ '^[+-]?[0-9]+([.][0-9]+)?$'
                    THEN REPLACE(BTRIM(val), ',', '.')::numeric
                END AS x
            FROM (
                VALUES
                    ('p', t.pente),
                    ('d', t.devers),
                    ('l', t.largutile)
            ) v(cle, val)
        ) z
    ) n
),

-- 2. Préparer les mesures.
mesures AS (
    SELECT
        n.*,

        CASE
            WHEN ABS(pente_num) NOT IN (8888, 9999)
            THEN ABS(pente_num)
        END AS pente_abs_pct,

        CASE
            WHEN ABS(devers_num) NOT IN (8888, 9999)
            THEN ABS(devers_num)
        END AS devers_abs_pct,

        -- Minimum des largeurs exactes connues.
        -- Les codes restent disponibles dans largeur_num
        -- et nb_largeurs_sup_180.
        LEAST(
            CASE
                WHEN largeur_num IN (8888, 9999) THEN NULL
                WHEN largeur_num >= 0 THEN largeur_num
            END,
            largeur_min_mesuree_m
        ) AS largeur_min_exacte_m

    FROM nombres n
),

-- 3. Garder la hauteur et le type de chaque ressaut ensemble.
ressauts_individuels AS (
    SELECT
        o.gid_tronco,
        LOWER(BTRIM(o.typeobstac)) AS type,

        CASE
            WHEN REPLACE(BTRIM(o.htobstacso), ',', '.')
                 ~ '^[0-9]+([.][0-9]+)?$'
            THEN REPLACE(BTRIM(o.htobstacso), ',', '.')::numeric
        END AS h

    FROM geo_standards.obstacle o

    WHERE LOWER(BTRIM(o.typeobstac)) LIKE 'ressaut%'
       OR LOWER(BTRIM(o.typeobstac)) = 'rupture de niveau'
),

-- 4. Contrôler les ressauts, puis regrouper par tronçon.
ressauts AS (
    SELECT
        gid_tronco,
        COUNT(*) AS nb_ressauts,

        MAX(
            CASE
                WHEN h IS NULL OR h IN (8888, 9999) THEN 1

                WHEN h > 0.04 THEN 2

                WHEN type = 'ressaut avec profil arrondi'
                     AND h > 0.02 THEN 2

                WHEN type IN (
                    'ressaut avec profil arrondi',
                    'ressaut chanfreiné'
                ) AND h <= 0.02 THEN 0

                -- Chanfrein entre 2 et 4 cm :
                -- sa pente 1 pour 3 reste à vérifier.
                -- Rupture de niveau : forme à vérifier.
                ELSE 1
            END
        ) AS controle_individuel

    FROM ressauts_individuels
    GROUP BY gid_tronco
),

-- 5. Appliquer les règles par tronçon.
regles AS (
    SELECT
        m.*,
        COALESCE(r.nb_ressauts, 0) AS nb_ressauts,

        CASE
            WHEN LOWER(BTRIM(typtronco))
                 IN ('escalier', 'escaliers') THEN 2
            ELSE 0
        END AS regle_escalier,

        CASE
            -- Quais : configuration du passage à vérifier.
            WHEN LOWER(BTRIM(typtronco)) = 'quai' THEN
                CASE
                    WHEN largeur_min_exacte_m < 0.90 THEN 2
                    ELSE 1
                END

            -- largilot n'est pas la largeur de toute la traversée.
            WHEN LOWER(BTRIM(typtronco)) IN (
                'traversée piétonne',
                'îlot de traversée piétonne'
            ) THEN 1

            WHEN largeur_min_exacte_m < 1.20 THEN 2

            WHEN largeur_num IS NULL
              OR largeur_num < 0
              OR nb_largeurs_non_renseignees > 0 THEN 1

            -- Entre 1,20 et 1,40 m :
            -- absence d'obstacles latéraux à vérifier.
            WHEN largeur_min_exacte_m < 1.40 THEN 1

            WHEN largeur_min_exacte_m >= 1.40
              OR largeur_num IN (8888, 9999) THEN 0

            ELSE 1
        END AS regle_largeur,

        CASE
            WHEN pente_abs_pct IS NULL THEN 1
            WHEN pente_abs_pct > 12 THEN 2
            -- Longueur de la portion pentue et conditions
            -- de tolérance non vérifiées.
            WHEN pente_abs_pct >= 5 THEN 1
            ELSE 0
        END AS regle_pente,

        CASE
            WHEN pente_abs_pct IS NULL
              OR pente_abs_pct > 4 THEN 1
            ELSE 0
        END AS regle_paliers,

        CASE
            WHEN devers_abs_pct IS NULL THEN 1
            WHEN devers_abs_pct > 2 THEN 2
            ELSE 0
        END AS regle_devers,

        -- Classement du revêtement pour le scénario.
        CASE
            WHEN LOWER(BTRIM(etarevet)) IN (
                'meuble',
                'glissant',
                'dégradation entraînant un problème de sécurité immédiat'
            ) THEN 2

            WHEN LOWER(BTRIM(etarevet)) IN (
                'bon état',
                'roulant',
                'dégradation sans gravité'
            ) THEN 0

            ELSE 1
        END AS regle_revetement,

        GREATEST(
            COALESCE(r.controle_individuel, 0),
            -- Plusieurs ressauts : espacement à vérifier.
            CASE WHEN r.nb_ressauts > 1 THEN 1 ELSE 0 END
        ) AS regle_ressauts

    FROM mesures m
    LEFT JOIN ressauts r
        ON r.gid_tronco = m.id_netex
)

-- 6. Synthèse : exclusion prioritaire, puis vérification.
SELECT
    r.*,

    CASE s.niveau
        WHEN 2 THEN 'Exclu du scénario'
        WHEN 1 THEN 'À vérifier'
        ELSE 'Admissible selon les critères contrôlés'
    END AS etat_analyse,

    s.motifs

FROM regles r

CROSS JOIN LATERAL (
    SELECT
        MAX(code) AS niveau,

        STRING_AGG(
            nom || CASE code
                WHEN 2 THEN ' : exclusion'
                ELSE ' : à vérifier'
            END,
            ' ; ' ORDER BY nom
        ) FILTER (WHERE code > 0) AS motifs

    FROM (
        VALUES
            ('Escalier', regle_escalier),
            ('Largeur', regle_largeur),
            ('Pente', regle_pente),
            ('Paliers liés à la pente', regle_paliers),
            ('Dévers', regle_devers),
            ('Revêtement', regle_revetement),
            ('Ressauts', regle_ressauts)
    ) v(nom, code)
) s;
