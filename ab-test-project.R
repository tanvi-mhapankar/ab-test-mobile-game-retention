# Setup: download cookie_cats.csv from Kaggle into the same folder as this script
# Packages: install.packages(c("DBI", "RSQLite", "ggplot2", "scales"))

# Cookie Cats A/B Test: Should the first gate move from level 30 to level 40?
library(DBI)
library(RSQLite)
library(ggplot2)
df <- read.csv("cookie_cats.csv")
str(df)

# Make retention columns numeric (1 = retained, 0 = not), whether the file stores them as TRUE/FALSE or "True"/"False"
for (col in c("retention_1", "retention_7")) {
  df[[col]] <- as.integer(df[[col]] %in% c(TRUE, "TRUE", "True", "true"))
}
str(df)
colSums(is.na(df))

# ---- 2. SQL: group sizes and retention by version ----
con <- dbConnect(RSQLite::SQLite(), ":memory:")
dbWriteTable(con, "players", df)

summary_tbl <- dbGetQuery(con, "
  SELECT version,
         COUNT(*)            AS players,
         AVG(retention_1)    AS ret_1day,
         AVG(retention_7)    AS ret_7day,
         AVG(sum_gamerounds) AS avg_rounds
  FROM players
  GROUP BY version
  ORDER BY version
")
print(summary_tbl)

# ---- 3. SQL: check for outliers in game rounds ----
outliers <- dbGetQuery(con, "
  SELECT userid, version, sum_gamerounds
  FROM players
  ORDER BY sum_gamerounds DESC
  LIMIT 5
")
print(outliers)
# Average rounds without the extreme outlier
print(mean(df$sum_gamerounds[df$version == "gate_30" & df$sum_gamerounds < 10000]))
print(mean(df$sum_gamerounds[df$version == "gate_40"]))

# Check group sizes against a 50/50 split
print(chisq.test(table(df$version), p = c(0.5, 0.5)))
# Decide: does one extreme player affect the comparison? # One extreme player doesn't affect retention (yes/no per player), but it inflates average rounds in gate_30

# ---- 4. Test: is the difference in retention statistically significant? ----
compare <- function(metric) {
  a <- df[df$version == "gate_30", metric]
  b <- df[df$version == "gate_40", metric]
  test <- prop.test(c(sum(b), sum(a)), c(length(b), length(a)), correct = FALSE)
  # prop.test reports the difference as (gate_40 - gate_30) with a 95% CI
  cat(sprintf("%s: gate_30=%.4f, gate_40=%.4f, diff=%+.4f, 95%% CI=(%+.4f, %+.4f), p=%.4f\n",
              metric, mean(a), mean(b), mean(b) - mean(a),
              test$conf.int[1], test$conf.int[2], test$p.value))
  invisible(test$p.value)
}

p1 <- compare("retention_1")
p7 <- compare("retention_7")

# ---- 5. Multiple comparisons: we tested 2 metrics, so use a Bonferroni-adjusted
# threshold of 0.05 / 2 = 0.025 instead of 0.05. ----
alpha <- 0.05 / 2
cat("1-day significant at adjusted alpha?", p1 < alpha, "\n")
cat("7-day significant at adjusted alpha?", p7 < alpha, "\n")

metric_labels <- c(retention_1 = "1-day retention", retention_7 = "7-day retention")

# ---- Chart 1: retention rates by version, shown as percentages with 95% CIs ----
rows <- list()
for (metric in names(metric_labels)) {
  for (v in c("gate_30", "gate_40")) {
    x <- df[df$version == v, metric]
    ci <- prop.test(sum(x), length(x), correct = FALSE)$conf.int
    rows[[length(rows) + 1]] <- data.frame(metric = metric_labels[[metric]], version = v,
                                           rate = mean(x), lo = ci[1], hi = ci[2])
  }
}
rates <- do.call(rbind, rows)

p1 <- ggplot(rates, aes(version, rate, fill = version)) +
  geom_col(width = 0.6) +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0.15) +
  geom_text(aes(label = sprintf("%.1f%%", rate * 100)), vjust = 2.2, color = "white", fontface = "bold") +
  facet_wrap(~ metric, scales = "free_y") +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(x = NULL, y = "Share of players retained",
       title = "Retention by gate position",
       subtitle = "Bars show retention rate; error bars show 95% confidence intervals") +
  theme_minimal(base_size = 12) + theme(legend.position = "none")
ggsave("retention_chart.png", p1, width = 7, height = 4, dpi = 150)

# ---- Chart 2: the difference (gate_40 minus gate_30) with 95% CIs ----
diff_rows <- list()
for (metric in names(metric_labels)) {
  a <- df[df$version == "gate_30", metric]
  b <- df[df$version == "gate_40", metric]
  t <- prop.test(c(sum(b), sum(a)), c(length(b), length(a)), correct = FALSE)
  diff_rows[[length(diff_rows) + 1]] <- data.frame(metric = metric_labels[[metric]],
                                                   diff = (mean(b) - mean(a)) * 100, lo = t$conf.int[1] * 100, hi = t$conf.int[2] * 100)
}
diffs <- do.call(rbind, diff_rows)

p2 <- ggplot(diffs, aes(diff, metric)) +
  geom_vline(xintercept = 0, linetype = "dashed", color = "grey40") +
  geom_pointrange(aes(xmin = lo, xmax = hi), size = 0.8) +
  labs(x = "Change in retention with gate at 40 (percentage points)", y = NULL,
       title = "Effect of moving the gate from level 30 to 40",
       subtitle = "Intervals that cross zero are not statistically distinguishable from no change") +
  theme_minimal(base_size = 12)
ggsave("difference_chart.png", p2, width = 7, height = 3, dpi = 150)

print(p1)
print(p2)