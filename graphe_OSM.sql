
CREATE MATERIALIZED VIEW iso15min.mv_simulation_osm_reseau AS

-- ÉTAPE 1 : Sélection et découpage des cheminements OSM
WITH segments AS (
    SELECT
        ROW_NUMBER() OVER (
            ORDER BY t.gid, s.path
        )::bigint AS id,

        t.gid::bigint AS osm_gid,
        t.id::text AS id_netex,
        t.highway::text AS typtronco,
        t.access_fauteuil::text AS access_fauteuil_source,
        t.vitesse_kmh::double precision AS vitesse_source_kmh,

        ST_Force2D(s.geom)::geometry(LineString, 3943) AS geom

    FROM analyses_recup.osm_troncon_anglet t

    CROSS JOIN LATERAL
        ST_DumpSegments(t.geom) AS s

    WHERE t.type_reseau = 'PIETON'
      AND COALESCE(t.access, '') NOT IN ('no', 'private')
      AND COALESCE(t.foot, '') <> 'no'
      AND COALESCE(t.wheelchair, '') <> 'no'
      AND ST_Length(s.geom) > 0.01
),

-- ÉTAPE 2 : Extraction des coordonnées des extrémités
coords AS (
    SELECT
        id,
        osm_gid,
        id_netex,
        typtronco,
        access_fauteuil_source,
        vitesse_source_kmh,
        geom,

        ROUND(ST_X(ST_StartPoint(geom)) * 100)::bigint AS x1,
        ROUND(ST_Y(ST_StartPoint(geom)) * 100)::bigint AS y1,

        ROUND(ST_X(ST_EndPoint(geom)) * 100)::bigint AS x2,
        ROUND(ST_Y(ST_EndPoint(geom)) * 100)::bigint AS y2

    FROM segments
),

-- ÉTAPE 3 : Création des identifiants des nœuds
noeuds AS (
    SELECT
        x,
        y,
        ROW_NUMBER() OVER (ORDER BY x, y)::bigint AS node_id

    FROM (
        SELECT x1 AS x, y1 AS y FROM coords

        UNION

        SELECT x2 AS x, y2 AS y FROM coords
    ) n
),

-- ÉTAPE 4 : Construction du graphe et règles PMR
reseau AS (
    SELECT
        c.id,
        c.osm_gid,
        c.id_netex,

        s.node_id AS source,
        t.node_id AS target,

        c.typtronco,
        'osm'::text AS reseau,
        'osm'::text AS origine,

        c.access_fauteuil_source,
        c.vitesse_source_kmh,

        ST_Length(c.geom)::double precision AS longueur_m,

        (
            LOWER(COALESCE(c.typtronco, '')) = 'steps'
        ) AS est_escalier,

        -- Classification des tronçons
        CASE
            WHEN c.access_fauteuil_source = 'INACCESSIBLE'
              OR LOWER(COALESCE(c.typtronco, '')) = 'steps'
                THEN 'Non conforme'

            WHEN c.access_fauteuil_source = 'DIFFICILE'
                THEN 'Non conforme'

            WHEN c.access_fauteuil_source = 'ACCESSIBLE_CONFIRME'
                THEN 'Conforme'

            ELSE 'Inconnu'
        END::text AS classe_pmr,

        -- Vitesse retenue pour la simulation
        CASE
            WHEN c.access_fauteuil_source = 'INACCESSIBLE'
              OR LOWER(COALESCE(c.typtronco, '')) = 'steps'
                THEN NULL::integer

            WHEN c.access_fauteuil_source = 'DIFFICILE'
                THEN 3

            ELSE 6
        END AS vitesse_kmh,

        c.geom

    FROM coords c

    JOIN noeuds s
        ON s.x = c.x1 AND s.y = c.y1

    JOIN noeuds t
        ON t.x = c.x2 AND t.y = c.y2
)

-- ÉTAPE 5 : Calcul des coûts de déplacement
SELECT
    id,
    osm_gid,
    id_netex,
    source,
    target,
    typtronco,
    reseau,
    origine,
    access_fauteuil_source,
    vitesse_source_kmh,
    longueur_m,
    est_escalier,
    classe_pmr,

    CASE
        WHEN classe_pmr = 'Conforme'
            THEN 'Accessible selon les attributs OSM ; validation terrain nécessaire'

        WHEN classe_pmr = 'Non conforme'
            THEN 'Difficulté ou inaccessibilité signalée par OSM'

        ELSE 'Accessibilité estimée selon OSM ; caractéristiques PMR à vérifier'
    END AS motifs,

    CASE
        WHEN classe_pmr = 'Inconnu'
            THEN 'Pente, dévers, largeur et obstacles non vérifiés par le modèle OSM'

        ELSE 'Conformité PMR non vérifiée sur le terrain'
    END AS informations_manquantes,

    vitesse_kmh,

    -- Coût aller (secondes)
    CASE
        WHEN vitesse_kmh IS NULL THEN -1.0
        ELSE longueur_m * 3.6 / vitesse_kmh
    END::double precision AS cost,

    -- Coût retour (secondes)
    CASE
        WHEN vitesse_kmh IS NULL THEN -1.0
        ELSE longueur_m * 3.6 / vitesse_kmh
    END::double precision AS reverse_cost,

    geom,
    NOW() AS date_calcul

FROM reseau;
