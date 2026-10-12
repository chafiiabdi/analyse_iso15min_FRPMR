CREATE OR REPLACE VIEW iso15min.v_troncons_criteres_base
WITH (security_invoker = true) AS

WITH parametres AS (
    -- Distance entre les deux points de chaque profil transversal.
    -- C'est un paramètre de calcul, pas une largeur mesurée.
    SELECT 1.0::double precision AS ecartement_m
),

base AS MATERIALIZED (
    SELECT
        t.*,

        COALESCE(
            NULLIF(BTRIM(c.pente), ''),
            NULLIF(BTRIM(r.pente), '')
        ) AS pente_initiale,

        COALESCE(
            NULLIF(BTRIM(c.devers), ''),
            NULLIF(BTRIM(r.devers), '')
        ) AS devers_initial,

        COALESCE(
            NULLIF(BTRIM(c.etarevet), ''),
            NULLIF(BTRIM(r.etarevet), ''),
            NULLIF(BTRIM(q."etatRevetment"), '')
        ) AS etarevet,

        c.id IS NOT NULL AS fiche_circulation_presente,
        r.id IS NOT NULL AS fiche_rampe_presente,
        q.id IS NOT NULL AS fiche_quai_presente,

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
        ON q.troncon_id_netex = t.id_netex
),

lignes AS MATERIALIZED (
    -- Préparer uniquement les tronçons ayant une valeur manquante.
    -- Le MNT est en EPSG:2154.
    SELECT
        id,
        ST_Transform(geom, 2154) AS g,
        pente_initiale IS NULL AS calcul_pente,
        devers_initial IS NULL AS calcul_devers

    FROM base
    WHERE pente_initiale IS NULL
       OR devers_initial IS NULL
),

profils AS (
    -- Profils transversaux à 25 %, 50 % et 75 % du tronçon.
    SELECT
        l.id,
        f.numero,

        ST_LineInterpolatePoint(
            l.g, f.fraction
        ) AS centre,

        ST_Azimuth(
            ST_LineInterpolatePoint(l.g, f.fraction - 0.01),
            ST_LineInterpolatePoint(l.g, f.fraction + 0.01)
        ) AS azimut,

        p.ecartement_m

    FROM lignes AS l
    CROSS JOIN parametres AS p
    CROSS JOIN (
        VALUES
            (1, 0.25),
            (2, 0.50),
            (3, 0.75)
    ) AS f(numero, fraction)

    WHERE l.calcul_devers
),

points AS (
    -- Points utilisés pour la pente longitudinale.
    SELECT
        id,
        0 AS numero,
        'debut' AS role,
        ST_StartPoint(g) AS geom
    FROM lignes
    WHERE calcul_pente

    UNION ALL

    SELECT
        id,
        0,
        'fin',
        ST_EndPoint(g)
    FROM lignes
    WHERE calcul_pente

    UNION ALL

    -- Points situés à gauche du cheminement.
    SELECT
        id,
        numero,
        'gauche',
        ST_Translate(
            centre,
            -ecartement_m / 2 * COS(azimut),
             ecartement_m / 2 * SIN(azimut)
        )
    FROM profils

    UNION ALL

    -- Points situés à droite du cheminement.
    SELECT
        id,
        numero,
        'droite',
        ST_Translate(
            centre,
             ecartement_m / 2 * COS(azimut),
            -ecartement_m / 2 * SIN(azimut)
        )
    FROM profils
),

altitudes AS MATERIALIZED (
    SELECT
        p.id,
        p.numero,
        p.role,
        z.altitude

    FROM points AS p

    LEFT JOIN LATERAL (
        SELECT
            ST_Value(
                m.rast, 1, p.geom, true, 'bilinear'
            ) AS altitude

        FROM mnt.mnt_anglet AS m

        WHERE ST_Intersects(m.rast, p.geom)
          AND ST_Value(
              m.rast, 1, p.geom, true, 'bilinear'
          ) IS NOT NULL

        ORDER BY m.rid
        LIMIT 1
    ) AS z ON true
),

pentes AS (
    -- Pente moyenne signée, en pourcentage.
    SELECT
        a.id,

        100.0 * (
            MAX(a.altitude) FILTER (WHERE a.role = 'fin')
            -
            MAX(a.altitude) FILTER (WHERE a.role = 'debut')
        ) / NULLIF(ST_Length(l.g), 0) AS pente_mnt

    FROM altitudes AS a
    JOIN lignes AS l
        ON l.id = a.id

    WHERE a.role IN ('debut', 'fin')

    GROUP BY a.id, l.g
),

profils_devers AS (
    SELECT
        id,
        numero,

        MAX(altitude) FILTER (
            WHERE role = 'gauche'
        ) AS z_gauche,

        MAX(altitude) FILTER (
            WHERE role = 'droite'
        ) AS z_droite

    FROM altitudes
    WHERE role IN ('gauche', 'droite')

    GROUP BY id, numero
),

devers AS (
    -- Dévers moyen en valeur absolue, en pourcentage.
    -- Les trois profils doivent posséder leurs deux altitudes.
    SELECT
        d.id,

        CASE
            WHEN COUNT(*) FILTER (
                WHERE z_gauche IS NOT NULL
                  AND z_droite IS NOT NULL
            ) = 3

            THEN 100.0
                 * AVG(ABS(z_droite - z_gauche))
                 / p.ecartement_m
        END AS devers_mnt

    FROM profils_devers AS d
    CROSS JOIN parametres AS p

    GROUP BY d.id, p.ecartement_m
)

SELECT
    -- Conserver l'ordre et les types des colonnes existantes.
    b.id,
    b.id_netex,
    b.source,
    b.target,
    b.typtronco,
    b.statutvoi,
    b.longueur_m,
    b.cost,
    b.reverse_cost,
    b.geom,

    -- La valeur existante reste prioritaire.
    COALESCE(
        b.pente_initiale,
        ROUND(p.pente_mnt::numeric, 2)::text
    ) AS pente,

    COALESCE(
        b.devers_initial,
        ROUND(d.devers_mnt::numeric, 2)::text
    ) AS devers,

    b.etarevet,
    b.fiche_circulation_presente,
    b.fiche_rampe_presente,
    b.fiche_quai_presente,
    b.largutile,

    -- Traçabilité des valeurs.
    CASE
        WHEN b.pente_initiale IS NOT NULL
            THEN 'Donnée existante'
        WHEN p.pente_mnt IS NOT NULL
            THEN 'Estimation MNT'
        ELSE 'Non renseigné'
    END AS source_pente,

    CASE
        WHEN b.devers_initial IS NOT NULL
            THEN 'Donnée existante'
        WHEN d.devers_mnt IS NOT NULL
            THEN 'Estimation MNT'
        ELSE 'Non renseigné'
    END AS source_devers,

    CASE
        WHEN b.devers_initial IS NULL
            THEN (SELECT ecartement_m FROM parametres)
    END AS ecartement_devers_m

FROM base AS b

LEFT JOIN pentes AS p
    ON p.id = b.id

LEFT JOIN devers AS d
    ON d.id = b.id;
