WITH chantiers AS (
    SELECT
        c.id,
        c.geom,

        CASE
            WHEN c.date_debut ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
                THEN TO_DATE(c.date_debut, 'DD/MM/YYYY')
            WHEN c.date_debut ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                THEN c.date_debut::date
        END AS debut,

        CASE
            WHEN c.date_fin ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
                THEN TO_DATE(c.date_fin, 'DD/MM/YYYY')
            WHEN c.date_fin ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                THEN c.date_fin::date
        END AS fin

    FROM travaux.chantier c
),

candidats AS (

    -- Tronçons touchés
    SELECT
        c.id AS id_chantier,
        t.id AS id_troncon,
        NULL::integer AS id_noeud,
        c.debut,
        c.fin
    FROM chantiers c
    JOIN geo_standards." troncon_cheminement_(conforme)" t
        ON ST_Intersects(
            ST_Transform(c.geom, 3943),
            t.geom
        )
    WHERE c.debut IS NOT NULL
      AND c.fin IS NOT NULL

    UNION ALL

    -- Nœuds touchés
    SELECT
        c.id,
        NULL::integer,
        n.id,
        c.debut,
        c.fin
    FROM chantiers c
    JOIN geo_standards.noeud_cheminement n
        ON ST_Intersects(
            ST_Transform(c.geom, 3943),
            n.geom
        )
    WHERE c.debut IS NOT NULL
      AND c.fin IS NOT NULL
),

ajouts AS (

    INSERT INTO travaux.impact_chantier (
        id_chantier,
        id_troncon,
        id_noeud,
        id_etat_reseau,
        etat_reseau,
        date_debut,
        date_fin,
        largeur_restante,
        commentaire
    )

    SELECT
        ca.id_chantier,
        ca.id_troncon,
        ca.id_noeud,
        4,
        'Inconnu'::travaux.etat_reseau_choix,
        ca.debut,
        ca.fin,
        NULL,
        'Intersection spatiale automatique : état du passage et largeur restante à vérifier manuellement.'

    FROM candidats ca

    WHERE NOT EXISTS (
        SELECT 1
        FROM travaux.impact_chantier ic
        WHERE ic.id_chantier = ca.id_chantier
          AND ic.id_troncon IS NOT DISTINCT FROM ca.id_troncon
          AND ic.id_noeud IS NOT DISTINCT FROM ca.id_noeud
    )

    ON CONFLICT DO NOTHING

    RETURNING id_troncon, id_noeud
)

SELECT
    CASE
        WHEN COUNT(*) > 0 THEN
            'Intégration terminée : '
            || COUNT(*) || ' nouvelle(s) association(s) ajoutée(s) dans travaux.impact_chantier, dont '
            || COUNT(*) FILTER (WHERE id_troncon IS NOT NULL)
            || ' tronçon(s) et '
            || COUNT(*) FILTER (WHERE id_noeud IS NOT NULL)
            || ' nœud(s). Les états du passage et les largeurs restantes doivent être complétés manuellement.'

        ELSE
            'Aucune nouvelle association à ajouter. Les tronçons et nœuds détectés sont déjà pris en compte dans travaux.impact_chantier. Vérifiez les états du passage et les largeurs restantes non renseignés.'
    END AS message_confirmation

FROM ajouts;
