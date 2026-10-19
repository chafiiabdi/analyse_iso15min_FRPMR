SELECT
    v.route_short_name AS ligne,
    v.trip_headsign AS direction,
    v.nom_acces AS acces_prioritaire,
    v.stop_name AS arret,

    TO_CHAR(
        COALESCE(p.prevue, p.estimee - p.retard * INTERVAL '1 second')
        AT TIME ZONE 'Europe/Paris', 'HH24:MI:SS'
    ) AS heure_prevue,

    TO_CHAR(
        p.estimee AT TIME ZONE 'Europe/Paris', 'HH24:MI:SS'
    ) AS heure_estimee,

    ROUND(p.retard / 60.0, 1) AS retard_min,

    TO_CHAR(
        v.source_timestamp AT TIME ZONE 'Europe/Paris', 'HH24:MI:SS'
    ) AS derniere_maj_flux,

    ROUND(EXTRACT(EPOCH FROM (NOW() - v.source_timestamp)))
        AS age_flux_secondes

FROM transport.v_prochains_passages_quais_prio v

CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN v.retard_arrivee_secondes > 0
             AND v.arrivee_estimee IS NOT NULL
            THEN v.arrivee_estimee ELSE v.depart_estime
        END AS estimee,

        CASE
            WHEN v.retard_arrivee_secondes > 0
             AND v.arrivee_estimee IS NOT NULL
            THEN v.arrivee_prevue ELSE v.depart_prevu
        END AS prevue,

        CASE
            WHEN v.retard_arrivee_secondes > 0
             AND v.arrivee_estimee IS NOT NULL
            THEN v.retard_arrivee_secondes
            ELSE v.retard_depart_secondes
        END AS retard
) p

WHERE p.retard > 0
  AND p.estimee BETWEEN NOW() AND NOW() + INTERVAL '2 hours'
  AND v.source_timestamp BETWEEN NOW() - INTERVAL '3 minutes'
                             AND NOW() + INTERVAL '30 seconds'

ORDER BY p.retard DESC, p.estimee ASC;
