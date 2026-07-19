# Audit aggregate disclosure-risk indicators in the isolated historical v4
# candidates. The script never writes source identifiers or trajectory strings.

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

LOCAL_TIMEZONE <- "Asia/Seoul"
UTC_OFFSET_HOURS <- 9L
DEFAULT_CANDIDATE <- "historical-v4-candidate-1"

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(
  sub("^--file=", "", script_argument[[1L]]), winslash = "/", mustWork = TRUE
)
base_dir <- normalizePath(file.path(dirname(script_path), "../.."), winslash = "/")
tmp_root <- normalizePath(file.path(base_dir, "tmp"), winslash = "/", mustWork = TRUE)

parse_value <- function(name, default) {
  prefix <- paste0("--", name, "=")
  match <- grep(paste0("^", prefix), commandArgs(TRUE), value = TRUE)
  if (!length(match)) return(default)
  if (length(match) != 1L) stop("Duplicate option: --", name, call. = FALSE)
  sub(paste0("^", prefix), "", match[[1L]])
}

candidate_dir <- normalizePath(
  parse_value(
    "candidate-dir",
    file.path(tmp_root, "historical-v4-audit", DEFAULT_CANDIDATE)
  ),
  winslash = "/",
  mustWork = TRUE
)
output_dir <- normalizePath(
  parse_value(
    "output-dir",
    file.path(tmp_root, "public-release-privacy-audit", DEFAULT_CANDIDATE)
  ),
  winslash = "/",
  mustWork = FALSE
)

is_within <- function(path, parent) {
  path <- tolower(normalizePath(path, winslash = "/", mustWork = FALSE))
  parent <- tolower(normalizePath(parent, winslash = "/", mustWork = FALSE))
  identical(path, parent) || startsWith(path, paste0(parent, "/"))
}
if (!is_within(candidate_dir, tmp_root) || !is_within(output_dir, tmp_root)) {
  stop("Candidate and output directories must remain under tmp", call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

paths <- list(
  campus = file.path(candidate_dir, "wifi_unist19_20sec_v4-candidate.parquet"),
  district = file.path(candidate_dir, "wifi_uou20_20sec_v4-candidate.parquet")
)
missing <- names(paths)[!file.exists(unlist(paths))]
if (length(missing)) stop("Missing candidate(s): ", paste(missing, collapse = ", "))

sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = TRUE))
}
sql_literal <- function(value) gsub("'", "''", value, fixed = TRUE)

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "SET threads=1")
dbExecute(con, sprintf(
  "SET temp_directory='%s'",
  gsub("'", "''", file.path(output_dir, "duckdb-temp"), fixed = TRUE)
))

audit_site <- function(site, path, residential_pattern = "") {
  dbExecute(con, "DROP TABLE IF EXISTS release_rows")
  dbExecute(con, "DROP TABLE IF EXISTS per_identifier")
  dbExecute(con, "DROP TABLE IF EXISTS signature_sizes")
  dbExecute(con, "DROP TABLE IF EXISTS routine_signature_sizes")
  dbExecute(con, "DROP TABLE IF EXISTS per_identifier_day_sensor")
  dbExecute(con, "DROP TABLE IF EXISTS per_identifier_day")
  dbExecute(con, "DROP TABLE IF EXISTS daily_signature_sizes")

  dbExecute(con, sprintf(
    "CREATE TEMP TABLE release_rows AS
     SELECT
       CAST(source_address AS VARCHAR) AS source_address,
       CAST(sensor_name AS VARCHAR) AS sensor_name,
       make_timestamp(epoch_us(timestamp)) AS timestamp_utc,
       make_timestamp(epoch_us(timestamp)) + INTERVAL '%d hours' AS timestamp_local
     FROM read_parquet('%s')",
    UTC_OFFSET_HOURS, sql_path(path)
  ))

  residential_sql <- if (nzchar(residential_pattern)) {
    sprintf(
      "max(CASE WHEN regexp_matches(lower(sensor_name), '%s') THEN 1 ELSE 0 END)",
      sql_literal(residential_pattern)
    )
  } else {
    "CAST(0 AS INTEGER)"
  }
  residential_night_sql <- if (nzchar(residential_pattern)) {
    sprintf(
      paste0(
        "max(CASE WHEN regexp_matches(lower(sensor_name), '%s') ",
        "AND extract('hour' FROM timestamp_local) BETWEEN 0 AND 4 ",
        "THEN 1 ELSE 0 END)"
      ),
      sql_literal(residential_pattern)
    )
  } else {
    "CAST(0 AS INTEGER)"
  }

  dbExecute(con, sprintf(
    "CREATE TEMP TABLE per_identifier AS
     SELECT
       source_address,
       count(*) AS n_rows,
       count(DISTINCT sensor_name) AS n_sensors,
       count(DISTINCT CAST(timestamp_local AS DATE)) AS n_days,
       date_diff('second', min(timestamp_local), max(timestamp_local)) AS span_seconds,
       first(sensor_name ORDER BY timestamp_local, sensor_name) AS first_sensor,
       last(sensor_name ORDER BY timestamp_local, sensor_name) AS last_sensor,
       floor(epoch(min(timestamp_local)) / 1800) AS first_half_hour,
       floor(epoch(max(timestamp_local)) / 1800) AS last_half_hour,
       max(CASE WHEN extract('hour' FROM timestamp_local) BETWEEN 0 AND 4
                THEN 1 ELSE 0 END) AS has_night,
       %s AS has_residential,
       %s AS has_residential_night
     FROM release_rows
     GROUP BY source_address",
    residential_sql, residential_night_sql
  ))

  # This coarse signature uses only fields an observer could plausibly know:
  # first/last sensor and half-hour, days observed, sensors visited, and a
  # logarithmic row-count band. It is a diagnostic, not an anonymity test.
  dbExecute(con, "
    CREATE TEMP TABLE signature_sizes AS
    SELECT signature, count(*) AS group_size
    FROM (
      SELECT
        concat_ws('|', first_sensor, CAST(first_half_hour AS VARCHAR),
          last_sensor, CAST(last_half_hour AS VARCHAR), CAST(n_days AS VARCHAR),
          CAST(n_sensors AS VARCHAR),
          CAST(floor(log(2, greatest(n_rows, 1))) AS VARCHAR),
          CAST(has_night AS VARCHAR)) AS signature
      FROM per_identifier
    )
    GROUP BY signature
  ")

  # A second, less identifying diagnostic drops absolute dates and half-hour
  # indices. It retains only hour-of-day, endpoint sensors, and coarse bands.
  # This describes recurring-pattern distinctiveness rather than whether an
  # observer who already knows exact first/last times could match a record.
  dbExecute(con, "
    CREATE TEMP TABLE routine_signature_sizes AS
    SELECT signature, count(*) AS group_size
    FROM (
      SELECT
        concat_ws('|', first_sensor,
          CAST(CAST(first_half_hour AS BIGINT) % 48 AS VARCHAR),
          last_sensor,
          CAST(CAST(last_half_hour AS BIGINT) % 48 AS VARCHAR),
          CASE WHEN n_days = 1 THEN '1'
               WHEN n_days <= 3 THEN '2-3'
               WHEN n_days <= 7 THEN '4-7' ELSE '8+' END,
          CASE WHEN n_sensors = 1 THEN '1'
               WHEN n_sensors <= 3 THEN '2-3'
               WHEN n_sensors <= 7 THEN '4-7' ELSE '8+' END,
          CAST(floor(log(2, greatest(n_rows, 1))) AS VARCHAR),
          CAST(has_night AS VARCHAR)) AS signature
      FROM per_identifier
    )
    GROUP BY signature
  ")

  dbExecute(con, "
    CREATE TEMP TABLE per_identifier_day_sensor AS
    SELECT
      source_address,
      CAST(timestamp_local AS DATE) AS local_date,
      sensor_name,
      min(timestamp_local) AS first_seen
    FROM release_rows
    GROUP BY source_address, local_date, sensor_name
  ")
  dbExecute(con, "
    CREATE TEMP TABLE per_identifier_day AS
    SELECT
      source_address,
      local_date,
      string_agg(sensor_name, '>' ORDER BY first_seen, sensor_name) AS sensor_sequence,
      count(*) AS sensors_visited
    FROM per_identifier_day_sensor
    GROUP BY source_address, local_date
  ")
  dbExecute(con, "
    CREATE TEMP TABLE daily_signature_sizes AS
    SELECT
      local_date,
      sensor_sequence,
      sensors_visited,
      count(*) AS group_size
    FROM per_identifier_day
    GROUP BY local_date, sensor_sequence, sensors_visited
  ")

  overview <- dbGetQuery(con, "
    SELECT
      count(*) AS identifiers,
      sum(CASE WHEN n_rows = 1 THEN 1 ELSE 0 END) AS one_row_identifiers,
      sum(CASE WHEN n_rows < 5 THEN 1 ELSE 0 END) AS under_five_rows,
      sum(CASE WHEN n_rows < 10 THEN 1 ELSE 0 END) AS under_ten_rows,
      sum(CASE WHEN n_sensors = 1 THEN 1 ELSE 0 END) AS one_sensor_identifiers,
      sum(CASE WHEN n_days = 1 THEN 1 ELSE 0 END) AS one_day_identifiers,
      sum(CASE WHEN n_days >= 2 THEN 1 ELSE 0 END) AS multi_day_identifiers,
      sum(CASE WHEN span_seconds >= 604800 THEN 1 ELSE 0 END) AS span_at_least_7d,
      sum(has_night) AS identifiers_with_00_05_observation,
      sum(has_residential) AS identifiers_at_residential_sensor,
      sum(has_residential_night) AS identifiers_at_residential_sensor_00_05
    FROM per_identifier
  ")
  signature <- dbGetQuery(con, "
    SELECT
      sum(group_size) AS identifiers,
      sum(CASE WHEN group_size = 1 THEN group_size ELSE 0 END)
        AS identifiers_with_unique_coarse_signature,
      sum(CASE WHEN group_size < 5 THEN group_size ELSE 0 END)
        AS identifiers_in_signature_groups_under_5,
      max(group_size) AS largest_signature_group
    FROM signature_sizes
  ")
  routine_signature <- dbGetQuery(con, "
    SELECT
      sum(group_size) AS identifiers,
      sum(CASE WHEN group_size = 1 THEN group_size ELSE 0 END)
        AS identifiers_with_unique_routine_signature,
      sum(CASE WHEN group_size < 5 THEN group_size ELSE 0 END)
        AS identifiers_in_routine_signature_groups_under_5,
      max(group_size) AS largest_routine_signature_group
    FROM routine_signature_sizes
  ")
  daily <- dbGetQuery(con, "
    SELECT
      sum(group_size) AS identifier_days,
      sum(CASE WHEN group_size = 1 THEN group_size ELSE 0 END)
        AS identifier_days_with_unique_sensor_sequence,
      sum(CASE WHEN group_size < 5 THEN group_size ELSE 0 END)
        AS identifier_days_in_sequence_groups_under_5,
      max(group_size) AS largest_daily_sequence_group
    FROM daily_signature_sizes
  ")

  data.frame(
    site = site,
    timezone = LOCAL_TIMEZONE,
    metric = c(
      names(overview), names(signature)[-1L], names(routine_signature)[-1L],
      names(daily)
    ),
    value = as.numeric(c(
      overview[1, ], signature[1, -1L], routine_signature[1, -1L], daily[1, ]
    )),
    stringsAsFactors = FALSE
  )
}

results <- rbind(
  audit_site(
    "UNIST campus",
    paths$campus,
    residential_pattern = "dorm|residen|whitehouse|parking_dorm"
  ),
  audit_site("Commercial district", paths$district)
)

csv_path <- file.path(output_dir, "aggregate_disclosure_indicators.csv")
write.csv(results, csv_path, row.names = FALSE, na = "")

value_for <- function(site, metric) {
  result <- results$value[results$site == site & results$metric == metric]
  if (length(result) != 1L) stop("Missing report metric: ", site, " / ", metric)
  format(result, scientific = FALSE, trim = TRUE, big.mark = ",")
}
percent_for <- function(site, numerator, denominator) {
  n <- results$value[results$site == site & results$metric == numerator]
  d <- results$value[results$site == site & results$metric == denominator]
  if (length(n) != 1L || length(d) != 1L || d == 0) return("NA")
  sprintf("%.1f%%", 100 * n / d)
}

report <- c(
  "# Aggregate public-release disclosure-risk audit",
  "",
  paste0("Candidate: `", basename(candidate_dir), "`"),
  "",
  paste0(
    "This diagnostic reads the candidate 20-second files in true UTC and derives ",
    "Korean local calendar fields explicitly using `", LOCAL_TIMEZONE, "`. It writes ",
    "only aggregate counts: no identifier, timestamped trajectory, or sensor sequence ",
    "is exported."
  ),
  "",
  "## Results",
  "",
  paste0(
    "Here, unique means only that no other pseudonym in the same dataset has the ",
    "same constructed summary. The calculation uses no external data, personal ",
    "name, or identity label and is not a successful matching rate."
  ),
  "",
  paste0(
    "- UNIST campus: ", value_for("UNIST campus", "identifiers"),
    " pseudonyms; ",
    value_for("UNIST campus", "multi_day_identifiers"),
    " appear on two or more local days; ",
    value_for("UNIST campus", "span_at_least_7d"),
    " appear across a period of at least seven days."
  ),
  paste0(
    "- Commercial district: ", value_for("Commercial district", "identifiers"),
    " pseudonyms; ",
    value_for("Commercial district", "multi_day_identifiers"),
    " appear on two or more local days."
  ),
  paste0(
    "- Dataset-internal uniqueness of a time-specific first/last half-hour ",
    "summary: campus ",
    percent_for(
      "UNIST campus", "identifiers_with_unique_coarse_signature", "identifiers"
    ),
    "; district ",
    percent_for(
      "Commercial district", "identifiers_with_unique_coarse_signature", "identifiers"
    ), "."
  ),
  paste0(
    "- Dataset-internal uniqueness of a date-free summary using endpoint sensors, half-hour of ",
    "day, and coarse observation bands: campus ",
    percent_for(
      "UNIST campus", "identifiers_with_unique_routine_signature", "identifiers"
    ),
    "; district ",
    percent_for(
      "Commercial district", "identifiers_with_unique_routine_signature",
      "identifiers"
    ), "."
  ),
  paste0(
    "- Daily sensor sequences occurring for only one identifier-day: campus ",
    percent_for(
      "UNIST campus", "identifier_days_with_unique_sensor_sequence", "identifier_days"
    ),
    "; district ",
    percent_for(
      "Commercial district", "identifier_days_with_unique_sensor_sequence",
      "identifier_days"
    ), "."
  ),
  paste0(
    "- Campus identifiers observed at a residentially named sensor between 00:00 and ",
    "04:59 local time: ",
    value_for("UNIST campus", "identifiers_at_residential_sensor_00_05"), "."
  ),
  "",
  "## Interpretation boundary",
  "",
  paste0(
    "Release-specific keyed pseudonyms can prevent direct matching to the legacy ",
    "identifier values and can separate the two deployments. They do not remove the ",
    "linkability of a 20-second trajectory within a deployment. The counts above are ",
    "risk indicators, not a legal determination, not a measured re-identification ",
    "rate, and not proof that an individual can be named."
  ),
  "",
  paste0(
    "Changing identifiers is therefore one safeguard rather than a complete release ",
    "decision. These diagnostics do not decide whether open release is permissible. ",
    "They identify questions for the responsible institutional review: longitudinal ",
    "span, named-place sensitivity, auxiliary-information scenarios, applicable ",
    "approvals, and whether the proposed access model is proportionate to the scientific ",
    "need."
  )
)
writeLines(report, file.path(output_dir, "audit_report.md"), useBytes = TRUE)
cat("Public-release privacy audit completed: ", output_dir, "\n", sep = "")
