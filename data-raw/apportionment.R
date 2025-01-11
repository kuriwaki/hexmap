# SK

library(dplyr)
cds_per_state <- readxl::read_excel("data-raw/apportionment.xlsx", sheet = "CDs") |>
    inner_join(ccesMRPprep::states_key) |>
    relocate(st:division, .after = state)

usethis::use_data(cds_per_state, overwrite = TRUE)
