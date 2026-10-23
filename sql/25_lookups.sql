-- 25_lookups.sql
-- Code lookup tables, transcribed from FEMA's own published field definitions
-- (OpenFEMA DataSetFields API, dataset NfipClaims v3).
--
--   psql -d portfolio -v ON_ERROR_STOP=1 -f sql/25_lookups.sql
--
-- These live in nfip_stg rather than nfip_mart because they are source-system
-- code lists, not analytical dimensions. The mart builds its dimensions from
-- them, adding the groupings that analysis actually uses.
--
-- Safe to re-run.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS nfip_stg;

-- ---------------------------------------------------------------------------
-- Cause of damage
-- ---------------------------------------------------------------------------
-- Observed in the data: 0,1,2,3,4,7,8,9,A,B,C,D as published, plus 5, 6, @, N
-- and Z (25 rows between them) that are not in FEMA's list, plus ~37,700 blanks.
-- Codes B/C/D describe the ADJUSTMENT PROCESS rather than a physical cause,
-- which matters: they are not perils and should not be charted alongside them.

DROP TABLE IF EXISTS nfip_stg.lk_cause_of_damage CASCADE;
CREATE TABLE nfip_stg.lk_cause_of_damage (
    cause_code        text PRIMARY KEY,
    cause_description text NOT NULL,
    cause_group       text NOT NULL,   -- peril | process | unknown
    is_published_code boolean NOT NULL
);
COMMENT ON TABLE nfip_stg.lk_cause_of_damage IS
  'Cause of damage codes per FEMA. cause_group separates physical perils from claim-handling process codes.';
COMMENT ON COLUMN nfip_stg.lk_cause_of_damage.cause_group IS
  'peril = a physical cause of loss; process = describes how the claim was adjusted, not what happened; unknown = blank or undocumented value.';

INSERT INTO nfip_stg.lk_cause_of_damage VALUES
 ('0','Other causes',                                              'peril',   true),
 ('1','Tidal water overflow',                                      'peril',   true),
 ('2','Stream, river, or lake overflow',                           'peril',   true),
 ('3','Alluvial fan overflow',                                     'peril',   true),
 ('4','Accumulation of rainfall or snowmelt',                      'peril',   true),
 ('7','Erosion-demolition',                                        'peril',   true),
 ('8','Erosion-removal',                                           'peril',   true),
 ('9','Earth movement, landslide, subsidence, sinkholes',          'peril',   true),
 ('A','Closed basin lake',                                         'peril',   true),
 ('B','Expedited claim handling, no site inspection',              'process', true),
 ('C','Expedited claim handling, follow-up site inspection',       'process', true),
 ('D','Expedited claim handling, remote adjustment pilot',         'process', true),
 ('5','Undocumented code present in data',                         'unknown', false),
 ('6','Undocumented code present in data',                         'unknown', false),
 ('@','Undocumented code present in data',                         'unknown', false),
 ('N','Undocumented code present in data',                         'unknown', false),
 ('Z','Undocumented code present in data',                         'unknown', false),
 ('(blank)','Not recorded',                                        'unknown', false);

-- Codes 7 and 8 are only valid for losses before 1995-09-23 under the Upton
-- Jones Amendment. Recorded here rather than in a comment so a test can check it.
COMMENT ON COLUMN nfip_stg.lk_cause_of_damage.is_published_code IS
  'False where the value appears in the data but not in FEMA''s published code list. Erosion codes 7 and 8 are valid only for losses before 1995-09-23.';


-- ---------------------------------------------------------------------------
-- Occupancy type
-- ---------------------------------------------------------------------------
-- Two generations of codes coexist: single-digit legacy codes and two-digit
-- Risk Rating 2.0 codes introduced later. Charting them as separate categories
-- splits what is really the same thing - code 1 and code 11 are both single
-- family. occupancy_group collapses them.

DROP TABLE IF EXISTS nfip_stg.lk_occupancy_type CASCADE;
CREATE TABLE nfip_stg.lk_occupancy_type (
    occupancy_code        text PRIMARY KEY,
    occupancy_description text NOT NULL,
    occupancy_group       text NOT NULL,   -- single family | multi family | mobile home | non-residential | unknown
    is_residential        boolean,
    code_generation       text NOT NULL    -- legacy | risk rating 2.0 | unknown
);
COMMENT ON TABLE nfip_stg.lk_occupancy_type IS
  'Occupancy codes per FEMA. Single-digit codes are legacy; two-digit codes are Risk Rating 2.0. occupancy_group collapses both generations so they can be analysed together.';

INSERT INTO nfip_stg.lk_occupancy_type VALUES
 ('1', 'Single family residence',                                  'single family',   true,  'legacy'),
 ('2', 'Residential building, 2 to 4 units',                       'multi family',    true,  'legacy'),
 ('3', 'Residential building, more than 4 units',                  'multi family',    true,  'legacy'),
 ('4', 'Non-residential building',                                 'non-residential', false, 'legacy'),
 ('6', 'Non-residential, business',                                'non-residential', false, 'legacy'),
 ('11','Single family residential building',                       'single family',   true,  'risk rating 2.0'),
 ('12','Residential non-condo building, 2 to 4 units',             'multi family',    true,  'risk rating 2.0'),
 ('13','Residential non-condo building, 5 or more units',          'multi family',    true,  'risk rating 2.0'),
 ('14','Residential mobile or manufactured home',                  'mobile home',     true,  'risk rating 2.0'),
 ('15','Residential condo association, one or more units',         'multi family',    true,  'risk rating 2.0'),
 ('16','Single residential unit within a multi-unit building',     'single family',   true,  'risk rating 2.0'),
 ('17','Non-residential mobile or manufactured home',              'mobile home',     false, 'risk rating 2.0'),
 ('18','Non-residential building',                                 'non-residential', false, 'risk rating 2.0'),
 ('19','Non-residential unit within a multi-unit building',        'non-residential', false, 'risk rating 2.0'),
 ('(blank)','Not recorded',                                        'unknown',         NULL,  'unknown');


-- ---------------------------------------------------------------------------
-- Non-payment reason
-- ---------------------------------------------------------------------------
-- This is the field that makes a null payment interpretable. Roughly 78% of
-- rows are blank, which mostly corresponds to claims that DID pay.

DROP TABLE IF EXISTS nfip_stg.lk_non_payment_reason CASCADE;
CREATE TABLE nfip_stg.lk_non_payment_reason (
    reason_code        text PRIMARY KEY,
    reason_description text NOT NULL,
    reason_group       text NOT NULL   -- not covered | below deductible | not pursued | admin | other
);
COMMENT ON TABLE nfip_stg.lk_non_payment_reason IS
  'Why a claim closed without payment (TRRP: Claim Closed Without Payment Reason). reason_group separates genuine coverage outcomes from administrative corrections.';
COMMENT ON COLUMN nfip_stg.lk_non_payment_reason.reason_group IS
  'admin rows (98, 99) are data corrections, not real claim outcomes - exclude them from denial-rate metrics.';

INSERT INTO nfip_stg.lk_non_payment_reason VALUES
 ('01','Claim less than deductible',                    'below deductible'),
 ('02','Seepage',                                       'not covered'),
 ('03','Backup drains',                                 'not covered'),
 ('04','Shrubs not covered',                            'not covered'),
 ('05','Sea wall',                                      'not covered'),
 ('06','Not an actual flood',                           'not covered'),
 ('07','Loss in progress',                              'not covered'),
 ('08','Failure to pursue claim',                       'not pursued'),
 ('09','Debris removal only',                           'not covered'),
 ('10','Fire',                                          'not covered'),
 ('11','Fence damage',                                  'not covered'),
 ('12','Hydrostatic pressure',                          'not covered'),
 ('13','Drainage clogged',                              'not covered'),
 ('14','Boat piers',                                    'not covered'),
 ('15','Not insured, damage before policy inception',   'not covered'),
 ('16','Not insured, wind damage',                      'not covered'),
 ('17','Erosion outside the definition of flood',       'not covered'),
 ('18','Landslide',                                     'not covered'),
 ('19','Mudflow outside the definition of flood',       'not covered'),
 ('20','No demonstrable damage',                        'not covered'),
 ('97','Other',                                         'other'),
 ('98','Error - delete claim (no assignment)',          'admin'),
 ('99','Erroneous assignment',                          'admin');


-- ---------------------------------------------------------------------------
-- Flood zone
-- ---------------------------------------------------------------------------
-- rated_flood_zone has ~70 distinct values, but the meaning is carried by the
-- leading letter plus whether a Base Flood Elevation is present. Grouping on
-- the first character is correct; grouping on the full code produces a long
-- tail of near-identical categories.

DROP TABLE IF EXISTS nfip_stg.lk_flood_zone_group CASCADE;
CREATE TABLE nfip_stg.lk_flood_zone_group (
    zone_letter      text PRIMARY KEY,
    zone_group       text NOT NULL,
    zone_description text NOT NULL,
    is_special_flood_hazard_area boolean NOT NULL
);
COMMENT ON TABLE nfip_stg.lk_flood_zone_group IS
  'Flood zone families keyed on the leading letter of rated_flood_zone. SFHA = the 100-year floodplain, where flood insurance is mandatory for federally backed mortgages.';

INSERT INTO nfip_stg.lk_flood_zone_group VALUES
 ('A','A - Special Flood Hazard',  'Special flood hazard area, 1% annual chance. AE/A1-A30 carry a Base Flood Elevation; bare A does not.', true),
 ('V','V - Coastal High Hazard',   'Special flood hazard area with wave action. The most severe rating class.',                              true),
 ('B','B - Moderate Hazard',       'Moderate flood hazard, between the 100- and 500-year floodplain. Superseded by X on maps after 1986.',   false),
 ('C','C - Minimal Hazard',        'Minimal flood hazard. Superseded by X on maps after 1986.',                                              false),
 ('X','X - Outside SFHA',          'Outside the 100-year floodplain. Replaced B and C from January 1986.',                                   false),
 ('D','D - Undetermined',          'Possible but undetermined flood hazard; no analysis has been performed.',                                false),
 ('(blank)','Unknown',             'Zone not recorded.',                                                                                     false);


ANALYZE nfip_stg.lk_cause_of_damage;
ANALYZE nfip_stg.lk_occupancy_type;
ANALYZE nfip_stg.lk_non_payment_reason;
ANALYZE nfip_stg.lk_flood_zone_group;

\echo 'Lookup tables created.'
SELECT 'lk_cause_of_damage'    AS lookup, count(*) FROM nfip_stg.lk_cause_of_damage
UNION ALL SELECT 'lk_occupancy_type',      count(*) FROM nfip_stg.lk_occupancy_type
UNION ALL SELECT 'lk_non_payment_reason',  count(*) FROM nfip_stg.lk_non_payment_reason
UNION ALL SELECT 'lk_flood_zone_group',    count(*) FROM nfip_stg.lk_flood_zone_group
ORDER BY 1;
