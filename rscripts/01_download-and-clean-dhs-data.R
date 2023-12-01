library(tidyverse)
library(rdhs)
library(haven)

# The current script uses rdhs package to download raw DHS data (requires registration at https://dhsprogram.com/).
# Alternatively, the raw DHS data can be downloaded with the same registration here:
# https://dhsprogram.com/data/  

# rdhs uses the DHS Data API:
# The DHS Program Indicator Data API, The Demographic and Health Surveys (DHS) Program. ICF International. Funded by the United States Agency for International Development (USAID). Available from api.dhsprogram.com. [Accessed 12-01-2023]

# Use DHS login credentials for user_email and user_project.

set_rdhs_config(data_frame = "dplyr::as_tibble",
                email = user_email,
                project = user_project)


# Identify relevant survey files ------------------------------------------

# Use statcompt to identify all countries that have data on attitudes towards beating wife.

# indicators <- dhs_indicators()
indicators_id <- c("WE_AWBT_M_BFD", "WE_AWBT_W_BFD")

countries <- dhs_countries()
statcomp <- dhs_data(indicatorIds = indicators_id, 
                     countryIds = countries$DHS_CountryCode)

statcomp <- statcomp %>%
  mutate(FileType = ifelse(str_detect(Indicator, "Women"), "Individual Recode", "Men's Recode")) %>% 
  select(SurveyId, FileType)

# Identify relevant DHS datasets
datasets <- dhs_datasets()

datasets <- semi_join(datasets, statcomp) %>% 
  filter(str_detect(FileFormat, "dta"))

# avlbl <- get_available_datasets()
# 
# datasets %>% 
#   anti_join(avlbl %>% select(FileName))


# Download data -----------------------------------------------------------

vars <- c("caseid", "v000", "v005", "d005", "v007", "v012", 
          "v020", "v044", "v501", "v502", "v535",
          "v744a", "v744b", "v744c", "v744d", "v744e",
          "d105a", "d105b", "d105c", "d105d", "d105e", "d105f", "d105g", "d105j",
          "d105an", "d105bn", "d105cn", "d105dn", "d105en", "d105fn", "d105gn", "d105jn")

# Add men's version of varialbe names
vars <- c(vars, paste0("m", vars))

get_datasets_adj <- function(filename){
  get_datasets(filename, col_select = one_of(vars))
} 

datasets <- datasets %>%
  mutate(path = map(FileName, possibly(get_datasets_adj, NA_character_)))

datasets$path <- map_chr(datasets$path, unlist) 

# Women's data ---------------------------------------------------------------

fml_datasets <- datasets %>% 
  filter(FileType == "Individual Recode") %>% 
  mutate(data = map(path, ~as_tibble(read_rds(.))))


get_var_labs <- function(variable){
  label <- ifelse(is.null(attr(variable, "label")), NA_character_, attr(variable, "label"))
  value_labs <- attr(variable, "labels")
  if (is.null(value_labs)) value_labs <- c("miss" = NA_integer_)
  if (str_detect(label, "NA")) value_labs <- c("miss" = NA_integer_)
  out <- tibble(label = label, enframe(value_labs))
  out$value <- as.character(out$value)
  out
}

get_df_labs <- function(data){
  tibble(var = names(data), 
         labs = map(data, get_var_labs)) %>% 
    unnest(labs)
}

fml_datasets <- fml_datasets %>% 
  mutate(labs = map(data, get_df_labs))

fml_labels <- fml_datasets %>% 
  select(country = CountryName, year = SurveyYear, labs) %>% 
  unnest(labs) 

recode_d105_character <- function(data) {
  data %>% 
    mutate(across(matches("d105.$"), ~case_when(
      as_factor(.) %in% c("no", "never") ~ "no",
      as_factor(.) %in% c("not at all", 
                          "not in last 12 months", 
                          "yes, before last year",
                          "yes, but not in the last 12 months") ~ "ever",
      as_factor(.) %in% c("widowed", 
                          "yes, but currently a widow or timing missing",
                          "yes, but frequency in last 12 months missing",
                          "yes, but widow/frequency missing",
                          "yes, but widows",
                          "yes, but widows",
                          "yes, widow/divorce/separate/missing",
                          "yes, widow/frequency missing",
                          "yes/ not currently married/ frequency missing") ~ "ever 12m_miss",
      str_detect(as_factor(.), ":") ~ "ever 12m_miss",
      as_factor(.) %in% c("often", "often during last 12 months", 
                          "sometimes", "sometimes during last 12 months",
                          "yes, last year") ~ "last 12m",
      TRUE ~ NA_character_
      )))
}

fml_data <- fml_datasets %>% 
  mutate(data = map(data, recode_d105_character)) %>% 
  unnest(data)

fml_data <- fml_data %>% 
  rename(country = CountryName,
         year = SurveyYear,
         weight = v005,
         dm_weight = d005,
         ever_married_sample = v020, 
         age = v012, 
         selected_dm_module = v044,
         marit = v501,
         previos_marit = v502,
         ever_married = v535,
         beat_go_out = v744a,
         beat_chld_negl = v744b, 
         beat_argues = v744c, 
         beat_refuse_sex = v744d, 
         beat_burn_food = v744e, 
         dvp_push = d105a, 
         dvp_slap = d105b, 
         dvp_twist = d105j, 
         dvp_punch = d105c, 
         n_dvp_push = d105an, 
         n_dvp_slap = d105bn, 
         n_dvp_twist = d105jn, 
         n_dvp_punch = d105cn) 


fml_data <- fml_data %>% 
  mutate(phase = str_sub(path, -8, -7))


fml_data <- fml_data %>%
  mutate(weight = weight/1000000,
         dm_weight = dm_weight/1000000,
         dm_weight = ifelse(is.na(dm_weight), weight, dm_weight))

# Recode ever married population to subset
fml_data <- fml_data %>% 
  mutate(
    ever_married = case_when(
      is.na(ever_married)& marit == 0 ~ 0,
      is.na(ever_married)& marit == 2 ~ 2,
      is.na(ever_married)& marit %in% c(1, 3, 4) ~ 1,
      ever_married_sample == 1 ~ 1,
      ever_married == 9 ~ NA,
      TRUE ~ ever_married
    ))

fml_data <- fml_data %>% 
  mutate(across(starts_with("beat_"), ~ifelse(. == 9, NA, .)),
         across(starts_with("beat_"), ~ifelse(. == 8, 1, .))) %>%  
  mutate(beat_any = case_when(
    rowSums(select(., starts_with("beat_"))) > 0 ~ 1, 
    rowSums(select(., starts_with("beat_"))) == 0 ~ 0
  )) 

fml_labels_j <- fml_labels %>% 
  filter(var == "d105j" & !str_detect(label, "twist") & name != "miss") %>% 
  mutate(special_j = "d105j is not twist arm") %>% 
  distinct(country, year, special_j)

fml_labels_d <- fml_labels %>% 
  # Correct the label on slapped and twisted arm item in Congo
  # Based on the documentation https://dhsprogram.com/publications/publication-SR141-Summary-Reports-Key-Findings.cfm
  mutate(label = ifelse(str_detect(country, "Congo") & year == 2007 & var == "d105b",
                        "Spouse ever slapped or twisted",
                        label)) %>% 
  filter(var == "d105b" & str_detect(label, "twist") & name != "miss") %>% 
  mutate(special_d = "d105b combines slap with twist arm")  %>% 
  distinct(country, year, special_d)

fml_data <- fml_data %>% 
  left_join(fml_labels_j) %>% 
  left_join(fml_labels_d) %>% 
  mutate(dvp_twist = ifelse(special_j %in% "d105j is not twist arm", NA, dvp_twist))

fml_data <- fml_data %>% 
  mutate(across(starts_with("dvp"), list(ever = ~case_when(
    . == "no" ~ 0,
    . %in% c("last 12m", "ever", "ever 12m_miss") ~ 1,
    TRUE ~ NA
  )))) %>% 
  # Twist arm item is usually combined with slap, sometimes with push (Zimbabwe 2005)
  mutate(dvp_twist_ever = ifelse(is.na(dvp_twist_ever), dvp_slap_ever, dvp_twist_ever)) %>% 
  mutate(dvp_any_ever = ifelse(rowSums(select(., dvp_slap_ever, dvp_push_ever, dvp_punch_ever, dvp_twist_ever)) > 0, 1, 0)) 

fml_data <- fml_data %>% 
  mutate(
    dvp_slap = case_when(
      n_dvp_slap %in% 0 ~ "ever", 
      n_dvp_slap > 0 & n_dvp_slap < 95 ~ "last 12m",
      TRUE ~ dvp_slap),
    dvp_push = case_when(
      n_dvp_push %in% 0 ~ "ever", 
      n_dvp_push > 0 & n_dvp_push < 95 ~ "last 12m",
      TRUE ~ dvp_push),
    dvp_punch = case_when(
      n_dvp_punch %in% 0 ~ "ever", 
      n_dvp_punch > 0 & n_dvp_punch < 95 ~ "last 12m",
      TRUE ~ dvp_punch)) %>% 
  mutate(
    across(dvp_push:dvp_twist, list(`12m` = ~case_when(
      . == "last 12m" ~ 1,
      . %in% c("no", "ever") ~ 0,
      TRUE ~ NA
    )))) %>% 
  mutate(dvp_twist_12m = ifelse(is.na(dvp_twist_12m), dvp_slap_12m, dvp_twist_12m)) %>% 
  mutate(dvp_any_12m = ifelse(rowSums(select(., dvp_slap_12m, dvp_push_12m, dvp_punch_12m, dvp_twist_12m)) > 0, 1, 0)) 


beat_att_aggr <- fml_data %>% 
  filter(ever_married == 1, age > 14, age < 50) %>% 
  group_by(country, year) %>% 
  summarise(across(starts_with("beat"), ~weighted.mean(., weight, na.rm = TRUE)))

dvp_aggr <- fml_data %>% 
  mutate(special_d = ifelse(is.na(special_d), "none", special_d)) %>% 
  filter(ever_married == 1, age > 14, age < 50, selected_dm_module == 1) %>% 
  group_by(country, year, special_d) %>% 
  summarise(across(starts_with("dvp_any"), ~weighted.mean(., dm_weight, na.rm = TRUE))) %>% 
  drop_na(dvp_any_ever) %>%
  # Only countries with n_time >= 2 to estimate change
  group_by(country) %>% 
  filter(n_distinct(year) > 1) 


beat_att_long <- beat_att_aggr %>% 
  drop_na(beat_any) %>% 
  pivot_longer(starts_with("beat"), 
               names_to = "item", 
               values_to = "value") %>% 
  mutate(sample = "women",
         type = "attitudes")


dvp_long <- dvp_aggr %>% 
  mutate(dvp_any_12m = ifelse(dvp_any_12m == 0, NA, dvp_any_12m)) %>% 
  pivot_longer(starts_with("dvp"), 
               names_to = "item", 
               values_to = "value") %>% 
  drop_na(value) %>% 
  bind_rows(dvp_aggr %>% 
              filter(special_d != "d105b combines slap with twist arm") %>% 
              select(country, year, special_d, value = dvp_any_12m) %>% 
              mutate(item = "dvp_consistend_12m")) %>% 
  mutate(sample = "women",
         type = "experience") %>% 
  group_by(item, country) %>% 
  filter(n_distinct(year) > 1) %>% 
  ungroup()

fml_aggr <- bind_rows(beat_att_long, dvp_long)


# Men's data ---------------------------------------------------------------


ml_datasets <- datasets %>% 
  filter(FileType == "Men's Recode") %>% 
  mutate(data = map(path, ~as_tibble(select(read_rds(.), one_of(str_c("m", vars))))))

ml_data <- ml_datasets %>% 
  unnest(data)

ml_data <- ml_data %>% 
  rename(country = CountryName,
         year = SurveyYear,
         weight = mv005,
         ever_married_sample = mv020, 
         age = mv012, 
         type_residence = mv102, 
         edu = mv106, 
         edu_yrs = mv133, 
         n_child = mv201, 
         marit = mv501,
         decide_health = mv743a,
         decide_purchase = mv743b,
         previos_marit = mv502,
         ever_married = mv535,
         beat_go_out = mv744a,
         beat_chld_negl = mv744b, 
         beat_argues = mv744c, 
         beat_refuse_sex = mv744d, 
         beat_burn_food = mv744e) 


ml_data <- ml_data %>%
  mutate(weight = weight/1000000)

# Recode ever married population to subset
ml_data <- ml_data %>% 
  mutate(ever_married = case_when(
    is.na(ever_married) & marit == 0 ~ 0,
    is.na(ever_married) & marit == 2 ~ 2,
    is.na(ever_married) & marit %in% c(1, 3, 4) ~ 1,
    ever_married_sample == 1 ~ 1,
    ever_married == 9 ~ NA,
    ever_married == 3 ~ 1,
    TRUE ~ ever_married
  ))

ml_data <- ml_data %>% 
  mutate(across(starts_with("beat_"), ~ifelse(. == 9, NA, .)),
         across(starts_with("beat_"), ~ifelse(. == 8, 1, .))) %>%  
  mutate(beat_any = ifelse(rowSums(select(., starts_with("beat_"))) > 0, 1, 0)) 


ml_beat_att_aggr <- ml_data %>% 
  filter(ever_married == 1, age < 50) %>% 
  group_by(country, year) %>% 
  summarise(across(starts_with("beat"), ~weighted.mean(., weight, na.rm = TRUE)))


ml_aggr <- ml_beat_att_aggr %>% 
  drop_na(beat_any) %>% 
  pivot_longer(starts_with("beat"), 
               names_to = "item", 
               values_to = "value") %>% 
  ungroup() %>% 
  mutate(sample = "men",
         type = "attitudes")


# Combine women's and men's data ------------------------------------------


final_data <- bind_rows(fml_aggr, ml_aggr)
final_data <- final_data %>% 
  mutate(year = as.numeric(year))

# Remove attitudes data for Nepal 2011

# The index on women’s attitudes toward wife beating used as an indicator of women’s empowerment in the 2006 NDHS
# was not used in the 2011 NDHS since information was collected differently in the two surveys. Specifically, instead of
# asking women directly whether a husband was justified in beating his wife under specific scenarios, as was done in the 2006
# NDHS, the 2011 NDHS initially asked women whether they agreed with wife beating for any reason. Only if they answered
# ‘yes’ to this question were they asked the questions about wife beating in specific scenarios. Because less than 1 percent of
# women responded `yes’ to the filter question, the data on women’s responses to questions on specific scenarios cannot be
# meaningfully used. 
# https://dhsprogram.com/pubs/pdf/FR257/FR257[13April2012].pdf


final_data <- final_data %>% 
  ungroup() %>% 
  filter(!(country == "Nepal" & year == 2011 & str_detect(item, "beat")))

write_rds(final_data, "data/aggr-data-clean.rds")


# Number of participants --------------------------------------------------

fml_data <- fml_data %>% 
  mutate(beat_any = ifelse(country == "Nepal" & year == 2011, NA, beat_any))
ml_data <- ml_data %>% 
  mutate(beat_any = ifelse(country == "Nepal" & year == 2011, NA, beat_any))

n_att <- fml_data %>% 
  filter(ever_married == 1, age > 14, age < 50, !is.na(beat_any)) %>% 
  group_by(country, year) %>% 
  summarise(n_att = n())

n_exp <- fml_data %>% 
  semi_join(dvp_long) %>% 
  filter(ever_married == 1, age > 14, age < 50, !is.na(dvp_any_12m)) %>% 
  group_by(country, year) %>% 
  summarise(n_exp = n())

n_both <- fml_data %>% 
  left_join(dvp_long) %>% 
  filter(ever_married == 1, age > 14, age < 50, (is.na(value)&!is.na(beat_any))|(!is.na(value)&(!is.na(beat_any)|!is.na(dvp_any_12m)))) %>% 
  group_by(country, year) %>% 
  summarise(n_both = n())

n_ml <- ml_data %>% 
  filter(ever_married == 1, age < 50, !is.na(beat_any)) %>% 
  group_by(country, year) %>% 
  summarise(n_men = n())


left_join(n_both, n_att) %>% 
  left_join(n_exp) %>% 
  full_join(n_ml) %>% 
  ungroup() %>% 
  write_rds("data/sample-size.rds")

