
-- ============================================================
-- ANALYSE OSM : CHEMINEMENTS ATTEIGNABLES À 5, 10 ET 15 MIN
-- ============================================================

-- 1. CRÉATION DE LA TABLE DES PORTIONS

CREATE TABLE iso15min.simulation_osm_portions (
    gid BIGINT PRIMARY KEY,
    acces_id INTEGER NOT NULL,
    reseau TEXT NOT NULL,
    duree_s INTEGER NOT NULL,
    troncon_id BIGINT NOT NULL,
    fraction_debut DOUBLE PRECISION NOT NULL,
    fraction_fin DOUBLE PRECISION NOT NULL,
    longueur_atteinte_m DOUBLE PRECISION NOT NULL,
    date_calcul TIMESTAMPTZ NOT NULL
);

CREATE INDEX simulation_osm_portions_filtre
ON iso15min.simulation_osm_portions (acces_id, duree_s);


-- ============================================================
-- 2. CALCUL DES CHEMINEMENTS AVEC PGROUTING
-- ============================================================

WITH d AS MATERIALIZED (
    SELECT *
    FROM iso15min.v_simulation_osm_departs
    WHERE calculable
),

-- Temps pour atteindre les deux nœuds du tronçon de départ
seeds AS MATERIALIZED (
    SELECT acces_id, node, MIN(t) AS t
    FROM (
        SELECT
            acces_id,
            source AS node,
            temps_raccord_s
              + fraction_depart * reverse_cost AS t
        FROM d

        UNION ALL

        SELECT
            acces_id,
            target AS node,
            temps_raccord_s
              + (1 - fraction_depart) * cost AS t
        FROM d
    ) v
    GROUP BY acces_id, node
),

-- Calcul des nœuds atteignables jusqu'à 900 secondes
pgr AS MATERIALIZED (
    SELECT z.from_v, z.node, z.agg_cost
    FROM public.pgr_drivingDistance(
        'SELECT id, source, target, cost, reverse_cost
         FROM iso15min.mv_simulation_osm_reseau
         WHERE cost >= 0',
        ARRAY(
            SELECT DISTINCT node::bigint
            FROM seeds
            ORDER BY node::bigint
        ),
        900::float8,
        true,
        false
    ) z
),

-- Temps minimal depuis chaque accès prioritaire
temps AS MATERIALIZED (
    SELECT
        s.acces_id,
        p.node,
        MIN(s.t + p.agg_cost) AS t
    FROM pgr p
    JOIN seeds s ON s.node = p.from_v
    WHERE s.t + p.agg_cost <= 900
    GROUP BY s.acces_id, p.node
),

-- Calcul des fractions de tronçons atteignables
intervalles AS (

    -- Depuis le nœud source
    SELECT
        t.acces_id,
        b.sec,
        e.id AS edge,
        0::float8 AS f0,
        LEAST(
            1::float8,
            (b.sec - t.t) / e.cost
        ) AS f1
    FROM temps t
    JOIN iso15min.mv_simulation_osm_reseau e
        ON e.source = t.node
    CROSS JOIN (VALUES (300), (600), (900)) b(sec)
    WHERE t.t < b.sec
      AND e.cost > 0

    UNION ALL

    -- Depuis le nœud target
    SELECT
        t.acces_id,
        b.sec,
        e.id,
        GREATEST(
            0::float8,
            1::float8 - (b.sec - t.t) / e.reverse_cost
        ),
        1::float8
    FROM temps t
    JOIN iso15min.mv_simulation_osm_reseau e
        ON e.target = t.node
    CROSS JOIN (VALUES (300), (600), (900)) b(sec)
    WHERE t.t < b.sec
      AND e.reverse_cost > 0

    UNION ALL

    -- Depuis la position exacte de l'accès prioritaire
    SELECT
        d.acces_id,
        b.sec,
        d.troncon_depart_id,
        GREATEST(
            0::float8,
            d.fraction_depart
              - (b.sec - d.temps_raccord_s)
              / d.reverse_cost
        ),
        LEAST(
            1::float8,
            d.fraction_depart
              + (b.sec - d.temps_raccord_s)
              / d.cost
        )
    FROM d
    CROSS JOIN (VALUES (300), (600), (900)) b(sec)
    WHERE b.sec > d.temps_raccord_s
      AND d.cost > 0
      AND d.reverse_cost > 0
),

-- Regroupement des portions qui se chevauchent
ranges AS (
    SELECT
        acces_id,
        sec,
        edge,
        range_agg(
            numrange(f0::numeric, f1::numeric, '[]')
        ) AS rr
    FROM intervalles
    WHERE f1 > f0
    GROUP BY acces_id, sec, edge
),

-- Extraction des fractions finales
parts AS (
    SELECT
        a.acces_id,
        a.sec,
        a.edge,
        lower(x.r)::float8 AS f0,
        upper(x.r)::float8 AS f1
    FROM ranges a
    CROSS JOIN LATERAL unnest(a.rr) x(r)
)

-- Enregistrement des résultats
INSERT INTO iso15min.simulation_osm_portions (
    gid,
    acces_id,
    reseau,
    duree_s,
    troncon_id,
    fraction_debut,
    fraction_fin,
    longueur_atteinte_m,
    date_calcul
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY p.acces_id, p.sec, p.edge, p.f0
    )::bigint,
    p.acces_id,
    'osm',
    p.sec,
    p.edge,
    p.f0,
    p.f1,
    (p.f1 - p.f0) * e.longueur_m,
    NOW()
FROM parts p
JOIN iso15min.mv_simulation_osm_reseau e
    ON e.id = p.edge
WHERE p.f1 > p.f0;


-- ============================================================
-- 3. VUE GÉOGRAPHIQUE DES RÉSULTATS
-- ============================================================

CREATE VIEW iso15min.v_simulation_osm_isochrones AS
SELECT
    p.gid,
    p.acces_id,
    d.nom AS nom_acces,
    p.reseau,
    p.duree_s,
    p.troncon_id,
    r.id_netex,
    r.osm_gid,
    r.typtronco,
    r.origine,
    r.classe_pmr,
    r.motifs,
    r.informations_manquantes,
    r.vitesse_kmh,
    r.access_fauteuil_source,
    r.vitesse_source_kmh,
    p.fraction_debut,
    p.fraction_fin,
    p.longueur_atteinte_m,
    d.statut_raccord,
    p.date_calcul,
    ST_LineSubstring(
        r.geom,
        p.fraction_debut,
        p.fraction_fin
    )::geometry(LineString, 3943) AS geom
FROM iso15min.simulation_osm_portions p
JOIN iso15min.mv_simulation_osm_reseau r
    ON r.id = p.troncon_id
JOIN iso15min.v_simulation_osm_departs d
    ON d.acces_id = p.acces_id;


-- ============================================================
-- 4. CRÉATION DES VUES 300, 600 ET 900 SECONDES
-- ============================================================

-- 5 minutes
CREATE VIEW iso15min.v_simulation_osm_300s AS
SELECT *
FROM iso15min.v_simulation_osm_isochrones
WHERE duree_s = 300;

-- 10 minutes
CREATE VIEW iso15min.v_simulation_osm_600s AS
SELECT *
FROM iso15min.v_simulation_osm_isochrones
WHERE duree_s = 600;

-- 15 minutes
CREATE VIEW iso15min.v_simulation_osm_900s AS
SELECT *
FROM iso15min.v_simulation_osm_isochrones
WHERE duree_s = 900;


-- ============================================================
-- 5. VÉRIFICATION DES RÉSULTATS
-- ============================================================

SELECT
    duree_s,
    COUNT(*) AS nombre_portions,
    COUNT(DISTINCT acces_id) AS nombre_acces,
    ROUND(
        SUM(longueur_atteinte_m)::numeric, 1
    ) AS longueur_totale_m
FROM iso15min.simulation_osm_portions
GROUP BY duree_s
ORDER BY duree_s;
