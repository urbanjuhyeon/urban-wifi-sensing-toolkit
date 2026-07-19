# 0-6-unist20-extract.R ========================================================
# SQLite → 1-sec parquet (DuckDB, per-file resume)
# Input:  D:/Experiments/2020_Three/unist20/WiFi/<sensor>/*.sqlite3
# Output: workflow/unist20_source/<sensor>/<file>.parquet
# ==============================================================================

# Setup ----

## Load Packages ----
pacman::p_load(tidyverse, lubridate, DBI, duckdb, arrow)

## Define Paths ----
base_dir    <- normalizePath(file.path(dirname(
  rstudioapi::getSourceEditorContext()$path), ".."), winslash = "/")
sqlite_root <- "D:/Experiments/2020_Three/unist20/WiFi"
raw_dir     <- file.path(base_dir, "workflow/unist20_source")

## Set Parameters ----
date_start <- "2020-07-09"
date_end   <- "2020-07-19"
rssi_min   <- -80
rssi_max   <- -30

## SQL Template ----
SQL_TEMPLATE <- "
  SELECT
    CAST(source_address AS VARCHAR) AS source_address,
    date_trunc('second', CAST(CAST(timestamp AS VARCHAR) AS TIMESTAMP)) AS timestamp,
    median(CAST(CAST(strength AS VARCHAR) AS DOUBLE)) AS rssi,
    count(*) AS n
  FROM sqlite_scan('%s', 'packets')
  WHERE CAST(subtype AS VARCHAR) NOT IN ('beacon', 'probe-response')
    AND CAST(CAST(strength AS VARCHAR) AS INTEGER) BETWEEN %d AND %d
    AND CAST(timestamp AS VARCHAR) >= '%s'
    AND CAST(timestamp AS VARCHAR) < '%s'
  GROUP BY
    CAST(source_address AS VARCHAR),
    date_trunc('second', CAST(CAST(timestamp AS VARCHAR) AS TIMESTAMP))
"

## Install Extension ----
tmp <- dbConnect(duckdb())
dbExecute(tmp, "INSTALL sqlite")
dbDisconnect(tmp, shutdown = TRUE); rm(tmp)

# Map Sensors ----

# Bus stop only — indoor sensors (student union, cafeteria, cafe) excluded
all_folders <- c("unist_01")

tasks <- tibble(folder = all_folders) |>
  mutate(
    sensor_name = folder,
    db_paths = map(folder, \(f) list.files(
      file.path(sqlite_root, f), "\\.sqlite3$", full.names = TRUE)),
    n_files  = map_int(db_paths, length),
    sensor_dir = file.path(raw_dir, sensor_name)
  ) |>
  filter(n_files > 0)

cat("Sensors:", nrow(tasks), "| Files:", sum(tasks$n_files), "\n")

# Extract SQLite ----

ts_start <- paste0(date_start, "T00:00:00")
ts_end   <- paste0(as.Date(date_end) + 1, "T00:00:00")
t0 <- Sys.time()

## Process Sensors ----
progress <- tasks |>
  pmap(\(sensor_name, folder, db_paths, n_files, sensor_dir) {
    dir.create(sensor_dir, recursive = TRUE, showWarnings = FALSE)

    t_sensor <- Sys.time()
    conn <- dbConnect(duckdb())
    on.exit(dbDisconnect(conn, shutdown = TRUE), add = TRUE)
    dbExecute(conn, "LOAD sqlite")

    n_done <- 0L; n_skip <- 0L; total_rows <- 0L

    for (p in db_paths) {
      out_name <- str_replace(basename(p), "\\.sqlite3$", ".parquet")
      out_path <- file.path(sensor_dir, out_name)

      # Resume: skip existing parquets
      if (file.exists(out_path)) {
        n_skip <- n_skip + 1L
        total_rows <- total_rows + nrow(read_parquet(out_path))
        next
      }

      sql <- sprintf(SQL_TEMPLATE, gsub("\\\\", "/", p),
                     rssi_min, rssi_max, ts_start, ts_end)

      result <- tryCatch(
        dbGetQuery(conn, sql) |> as_tibble(),
        error = function(e) {
          warning(sprintf("[%s] %s: %s", sensor_name, basename(p), conditionMessage(e)))
          NULL
        }
      )

      if (!is.null(result) && nrow(result) > 0) {
        result <- result |> mutate(sensor_name = sensor_name)
        write_parquet(result, out_path)
        total_rows <- total_rows + nrow(result)
        n_done <- n_done + 1L
      }
    }

    cat(sprintf("[%-12s] done (%d new + %d skip)\n", sensor_name, n_done, n_skip))

    tibble(sensor = sensor_name,
           files_done = n_done, files_skip = n_skip,
           rows = total_rows,
           secs = round(as.numeric(difftime(Sys.time(), t_sensor, units = "secs"))))
  }) |>
  bind_rows()

# Print Summary ----

progress |>
  mutate(label = sprintf("[%-12s] %s rows | %d new + %d skip | %d sec",
                         sensor, format(rows, big.mark = ","),
                         files_done, files_skip, secs)) |>
  pull(label) |>
  walk(\(x) cat(x, "\n"))

cat("\nTotal:", round(difftime(Sys.time(), t0, units = "mins"), 1), "min\n")
cat("Output:", raw_dir, "\n")
