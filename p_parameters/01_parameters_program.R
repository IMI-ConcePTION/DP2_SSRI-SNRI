#-----------------------------------
# general parameters of the program
#-----------------------------------


set_and_create_dir <- function(x) {
  x <- paste0(thisdir, x)
  dir.create(file.path(x), showWarnings = F)
  return(x)
}

###################################################################
# SET AND CREATE FOLDERS IF NECESSARY
###################################################################

diroutput <- set_and_create_dir("/g_output/")
dirtemp <- set_and_create_dir("/g_intermediate/")
dirconceptsets <- set_and_create_dir("/g_intermediate/concept_sets/")
direxp <- set_and_create_dir("/g_export/")
dirmacro <- set_and_create_dir("/p_macro/")
dirpargen <- set_and_create_dir("/g_parameters/")
#direvents <- set_and_create_dir("/g_intermediate/events/")
#dircomponents <- set_and_create_dir("/g_intermediate/components/")
#PathOutputFolder <- set_and_create_dir("/g_describeHTML")

dirsmallcountsremoved<- set_and_create_dir("/g_export_smallcountsremoved/")

rm(set_and_create_dir)

# load packages
read_library <- function(...) {
  x <- c(...)
  invisible(lapply(x, library, character.only = TRUE))
}

#list.of.packages <- c("MASS", "haven", "tidyverse", "lubridate", "AdhereR", "stringr", "purrr", "readr", "dplyr",
#                      "survival", "rmarkdown", "ggplot2", "data.table", "qpdf", "parallel", "readxl", "fst")

list.of.packages <- c("lubridate", "stringr", "readr", "purrr")

###################################################################
# RETRIEVE INFORMATION FROM CDM_SOURCE
###################################################################
if (!require("data.table")) install.packages("data.table")
library(data.table)


CDM_SOURCE<- fread(paste0(dirinput,"CDM_SOURCE.csv"))
thisdatasource <- as.character(CDM_SOURCE[1,3])


if (thisdatasource!="THL") {
  new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[, "Package"])]
  if (length(new.packages)) install.packages(new.packages)
  invisible(lapply(list.of.packages, require, character.only = T))
  
  rm(read_library, new.packages, list.of.packages)
}else{
  library(readr)
  library(stringr)
  library(purrr)
}

#----------------
extension = "rds"

instance_creation <- ymd(CDM_SOURCE[1,"date_creation"])
recommended_end_date <- ymd(CDM_SOURCE[1,"recommended_end_date"])
rm(CDM_SOURCE)

#--------------
# load macros

source(paste0(dirmacro,"CreateConceptSetDatasets_v20.R"))
source(paste0(dirmacro,"MergeFilterAndCollapse.R"))
source(paste0(dirmacro,"CreateSpells_v15.R"))
source(paste0(dirmacro,"CreateFlowChart.R"))
source(paste0(dirmacro,"Smart_load.R"))
source(paste0(dirmacro,"Smart_save.R"))
source(paste0(dirmacro,"DRE_Threshold.R"))
source(paste0(dirmacro,"launch_step.R"))
source(paste0(dirmacro,"CountPrevalence.R"))




###################################################################
# CREATE EMPTY FILES
###################################################################

files <- sub('\\.csv$', '', list.files(dirinput))

if (!any(str_detect(files,"^SURVEY_ID"))) {
  print("Creating empty SURVEY_ID since none were found")
  fwrite(data.table(person_id = character(0), survey_id = character(0), survey_date = character(0),
                    survey_meaning = character(0)),
         paste0(dirinput, "SURVEY_ID_empty", ".csv"))
}

if (!any(str_detect(files,"^SURVEY_OBSERVATIONS"))) {
  print("Creating empty SURVEY_OBSERVATIONS since none were found")
  fwrite(data.table(person_id = character(0), so_date = character(0), so_source_table = character(0),
                    so_source_column = character(0), so_source_value = character(0), so_unit = character(0),
                    survey_id = character(0)),
         paste0(dirinput, "SURVEY_OBSERVATIONS_empty", ".csv"))
}

if (!any(str_detect(files,"^MEDICINES"))) {
  print("Creating empty MEDICINES since none were found")
  fwrite(data.table(person_id = character(0), medicinal_product_id = integer(0),
                    medicinal_product_atc_code = character(0), date_dispensing = integer(0),
                    date_prescription = logical(0), disp_number_medicinal_product = numeric(0),
                    presc_quantity_per_day = logical(0), presc_quantity_unit = logical(0),
                    presc_duration_days = logical(0), product_lot_number = logical(0),
                    indication_code = logical(0), indication_code_vocabulary = logical(0),
                    meaning_of_drug_record = character(0), origin_of_drug_record = character(0),
                    prescriber_speciality = logical(0), prescriber_speciality_vocabulary = logical(0),
                    visit_occurrence_id = character(0)),
         paste0(dirinput, "MEDICINES_empty", ".csv"))
}

rm(files)

#############################################
#SAVE METADATA TO direxp
#############################################

file.copy(paste0(dirinput,'/METADATA.csv'), direxp, overwrite = T)
file.copy(paste0(dirinput,'/CDM_SOURCE.csv'), direxp, overwrite = T)
file.copy(paste0(dirinput,'/INSTANCE.csv'), direxp, overwrite = T)

#############################################
#SAVE to_run.R TO direxp
#############################################

file.copy(paste0(thisdir,'/to_run.R'), direxp, overwrite = T)

#############################################
#FUNCTION TO COMPUTE AGE
#############################################

age_fast = function(from, to) {
  from_lt = as.POSIXlt(from)
  to_lt = as.POSIXlt(to)
  
  age = to_lt$year - from_lt$year
  
  ifelse(to_lt$mon < from_lt$mon |
           (to_lt$mon == from_lt$mon & to_lt$mday < from_lt$mday),
         age - 1, age)
}

`%not in%` = Negate(`%in%`)

correct_difftime <- function(t1, t2, t_period = "days") {
  return(difftime(t1, t2, units = t_period) + 1)
}

calc_precise_week <- function(time_diff) {
  # correction in case a person exit the same date it enter
  time_diff <- fifelse(time_diff == 1, time_diff + 1, time_diff)
  weeks_frac <- time_length(time_diff - 1, "week")
  fifelse(weeks_frac%%1==0, weeks_frac, floor(weeks_frac) + 1)
}

join_and_replace <- function(df1, df2, join_cond, old_name) {
  temp <- merge(df1, df2, by.x = join_cond[1], by.y = join_cond[2])
  temp[, join_cond[1] := NULL]
  setnames(temp, old_name, join_cond[1])
}

read_CDM_tables <- function(x) {
  final_table <- data.table()
  for (file in files_ConcePTION_CDM_tables[[x]]) {
    temp <- fread(paste0(dirinput, file, ".csv"), colClasses = list(character = "person_id"))
    final_table <- rbind(final_table, temp, fill = T)
    rm(temp)
  }
  return(final_table)
}

smart_save <- function(df, folder, subpop = F, extension = "rds", override_name = F) {
  
  subpop_str <- if (isFALSE(subpop)) "" else suffix[[subpop]]
  df_name <- if (isFALSE(override_name)) deparse(substitute(df)) else override_name
  extension <- if (!grepl("\\.", extension)) paste0(".", extension)
  
  file_name <- paste0(folder, df_name, subpop_str, extension)
  
  if (extension == ".qs") {
    qs::qsave(df, file_name, preset = "high", nthreads = parallel::detectCores()/2)
  } else if (extension == ".fst") {
    fst::write.fst(df, file_name, compress = 100)
  } else {
    saveRDS(df, file_name)
  }
}

smart_load <- function(df, folder, subpop = F, extension = "rds", return = F) {
  
  subpop_str <- if (isFALSE(subpop)) "" else suffix[[subpop]]
  extension <- paste0(".", extension)
  
  file_name <- paste0(folder, df, subpop_str, extension)
  if (extension == ".qs") {
    tmp <- qs::qread(file_name, nthreads = parallel::detectCores()/2)
  } else if (extension == ".fst") {
    tmp <- fst::read.fst(file_name, as.data.table = T)
  } else if  (extension == ".rds") {
    tmp <- readRDS(file_name)
  } else {
    load(file_name, envir = .GlobalEnv, verbose = FALSE)
  }
  if (return) {
    return(tmp)
  } else {
    assign(df, tmp, envir = .GlobalEnv)
  }
}

better_foverlaps <- function(x, y, by.x = if (!is.null(key(x))) key(x) else key(y), 
                             by.y = key(y), maxgap = 0L, minoverlap = 1L,
                             type = c("any", "within", "start", "end", "equal"),
                             mult = c("all", "first", "last"), nomatch = getOption("datatable.nomatch", NA),
                             which = FALSE, verbose = getOption("datatable.verbose")) {
  
  duplicated_x <- by.x[duplicated(by.x)]
  if (length(duplicated_x) > 0) {
    new_col <- paste0(duplicated_x, "_copy")
    x[, (new_col) := get(duplicated_x)]
    by.x = c(unique(by.x), new_col)
    return(foverlaps(x = x, y = y, by.x = by.x, by.y = by.y, maxgap = maxgap, minoverlap = minoverlap, type = type,
                     mult = mult, nomatch = nomatch, which = which, verbose = verbose)[, (new_col) := NULL])
  }
  
  duplicated_y <- by.y[duplicated(by.y)]
  if (length(duplicated_y) > 0) {
    new_col <- paste0(duplicated_y, "_copy")
    y[, (new_col) := get(duplicated_y)]
    by.y = c(unique(by.y), new_col)
    setkeyv(y, by.y)
    return(foverlaps(x = x, y = y, by.x = by.x, by.y = by.y, maxgap = maxgap, minoverlap = minoverlap, type = type,
                     mult = mult, nomatch = nomatch, which = which, verbose = verbose)[, (new_col) := NULL])
  }
  
  return(foverlaps(x = x, y = y, by.x = by.x, by.y = by.y, maxgap = maxgap, minoverlap = minoverlap, type = type,
                   mult = mult, nomatch = nomatch, which = which, verbose = verbose))
}

set_names_components <- function(x) {
  cols_to_change <- names(x)[grepl("component", names(x))]
  new_cols_names <- lapply(strsplit(cols_to_change, "_"), function (y) {
    fifelse(is.na(y[5]), paste(y[1], y[3], y[4], y[2], sep = "_"), paste(y[1], y[3], y[5], y[4], y[2], sep = "_"))
  })
  setnames(x, cols_to_change, unlist(new_cols_names))
  return(x)
}

