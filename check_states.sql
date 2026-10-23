-- Which state values in the claims data have no match in ref.dim_state?
SELECT COALESCE(NULLIF(s.state_abbr, ''), '(blank)') AS state_value,
       count(*)                                      AS claims,
       min(s.date_of_loss)                           AS earliest_loss,
       max(s.date_of_loss)                           AS latest_loss,
       count(DISTINCT s.county_fips)                 AS distinct_counties
  FROM nfip_stg.claims s
  LEFT JOIN ref.dim_state d ON d.state_abbr = s.state_abbr
 WHERE d.state_fips IS NULL
 GROUP BY 1
 ORDER BY claims DESC;
