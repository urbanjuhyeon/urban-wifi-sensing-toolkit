# Attach UTC timezone metadata to an existing Parquet timestamp column without
# changing its physical epoch values. DuckDB writes TIMESTAMP without timezone;
# the analysis contract requires timestamp[us, tz=UTC].

attach_utc_timestamp_metadata <- function(path, column = "timestamp") {
  table <- arrow::read_parquet(path, as_data_frame = FALSE)
  index <- match(column, names(table)) - 1L
  if (is.na(index)) stop("Timestamp column not found: ", column)

  utc_type <- arrow::timestamp("us", timezone = "UTC")
  utc_column <- table$GetColumnByName(column)$cast(utc_type)
  table_utc <- table$SetColumn(
    index,
    arrow::field(column, utc_type),
    utc_column
  )

  temp_path <- paste0(path, ".utc.tmp.parquet")
  if (file.exists(temp_path)) unlink(temp_path)
  arrow::write_parquet(table_utc, temp_path, compression = "zstd")

  check <- arrow::read_parquet(temp_path, col_select = tidyselect::all_of(column))
  if (!identical(attr(check[[column]], "tzone"), "UTC")) {
    unlink(temp_path)
    stop("Failed to attach UTC timestamp metadata: ", path)
  }

  unlink(path)
  if (!file.rename(temp_path, path)) {
    stop("Failed to replace Parquet after UTC metadata update: ", path)
  }
  invisible(path)
}
