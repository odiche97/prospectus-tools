source("damagefunc-lib.R")

### The code:

library(pracma)
library(rstan)
library(ggplot2)
library(reshape2)
library(xtable)

rstan_options(auto_write = TRUE)
options(mc.cores = parallel::detectCores())

estimate.scc <- function(filetemplate, prefix, tascol, get.impact, initial.temperature, ggaddon, scc.scale, include.climadapt=F, include.intercept=F, include.beta2prior=T) {
    yys <- c()
    XXs <- matrix(NA, 0, 5) # T, T^2, D[avgT], D[avgT^2], gdppc

    for (rcp in c('rcp45', 'rcp85')) {
        for (ssp in paste0('SSP', 1:5)) {
            filepath <- gsub("SSP", ssp, gsub("RCP", rcp, filetemplate))
            if (!file.exists(filepath))
                next

            print(c(rcp, ssp))
            damages <- read.csv(filepath)

            for (gcm in unique(damages$gcm)) {
                for (mod in unique(damages$mod)) {
                    subdmg <- damages[damages$gcm == gcm & damages$mod == mod,]
                    if (nrow(subdmg) == 0)
                        next
                    ## Drop any GCMs with exactly 0 temps
                    if (any(subdmg[, tascol] == 0)) {
                        print(c("Skipping", gcm, subdmg$year[subdmg[, tascol] == 0]))
                        next
                    }

                    if (is.na(initial.temperature)) { # if initial.temperature is NA, rebase temperature
                        baseline <- mean(subdmg[subdmg$year >= 1996 & subdmg$year <= 2015, tascol], na.rm=T)
                        temps <- c(rep(0, 30), subdmg[, tascol] - baseline)
                    } else
                        temps <- c(rep(initial.temperature, 30), subdmg[, tascol])
                    temps2 <- temps ^ 2

                    ## Drop the last value, so resulting predictor is 1 year delayed
                    avgtemps <- movavg(temps[-length(temps)], 30, 'w')
                    avgtemps2 <- movavg(temps2[-length(temps)], 30, 'w')

                    loggdppc <- lgfuns[[paste(mod, ssp, sep='-')]](subdmg$year)

                    XXs <- rbind(XXs, cbind(tail(temps, nrow(subdmg)),
                                            tail(temps2, nrow(subdmg)),
                                            tail(avgtemps, nrow(subdmg)),
                                            tail(avgtemps2, nrow(subdmg)), loggdppc))
                    yys <- c(yys, get.impact(subdmg))
                }
            }
        }
    }

    ggaddon(ggplot(data.frame(yys, xxs=XXs[, 1], loggdppc=XXs[, 5]), aes(xxs, yys, colour=loggdppc)) +
            geom_point() + geom_smooth() +
            theme_minimal() + scale_colour_continuous(name="Log GDP pc"))
    ggsave(paste0("graphs/", prefix, "-data.pdf"), width=8, height=6)

    ## Fit a Bayesian model

    if (include.climadapt) {
        if (include.intercept) {
            stan.model <- "
data {
    int<lower=0> I;
    vector[I] T;
    vector[I] T2;
    vector[I] DavgT;
    vector[I] DavgT2;
    vector[I] logGDPpc;
    vector[I] y;
}
parameters {
    real alpha;
    real beta1;
    real<lower=0, upper=.05> beta2; // strong assumption, but need for convergence
    real<lower=0, upper=1> adapt;
    real<lower=-3, upper=0> gamma; // assumptions: doubling -> >12.5% of impact
    real<lower=0> epsilon;
}
model {
    y ~ normal(alpha + (beta1 * (T - adapt * DavgT) + beta2 * (T2 - adapt * DavgT2)) .* exp(gamma * logGDPpc), epsilon);
}"
        } else {
            stan.model <- "
data {
    int<lower=0> I;
    vector[I] T;
    vector[I] T2;
    vector[I] DavgT;
    vector[I] DavgT2;
    vector[I] logGDPpc;
    vector[I] y;
}
parameters {
    real beta1;
    real<lower=0, upper=.05> beta2; // strong assumption, but need for convergence
    real<lower=0, upper=1> adapt;
    real<lower=-3, upper=0> gamma; // assumptions: doubling -> >12.5% of impact
    real<lower=0> epsilon;
}
model {
    y ~ normal((beta1 * (T - adapt * DavgT) + beta2 * (T2 - adapt * DavgT2)) .* exp(gamma * logGDPpc), epsilon);
}"
        }
    } else {
        ## No climate adaptation estimation
        if (include.intercept) {
            stan.model <- "
data {
    int<lower=0> I;
    vector[I] DavgT;
    vector[I] DavgT2;
    vector[I] logGDPpc;
    vector[I] y;
}
parameters {
    real alpha;
    real beta1;
    real<lower=0, upper=.05> beta2; // strong assumption, but need for convergence
    real<lower=-3, upper=0> gamma; // assumptions: doubling -> >12.5% of impact
    real<lower=0> epsilon;
}
model {
    y ~ normal(alpha + (beta1 * DavgT + beta2 * DavgT2) .* exp(gamma * logGDPpc), epsilon);
}"
        } else {
            stan.model <- "
data {
    int<lower=0> I;
    vector[I] DavgT;
    vector[I] DavgT2;
    vector[I] logGDPpc;
    vector[I] y;
}
parameters {
    real beta1;
    real<lower=0, upper=.05> beta2; // strong assumption, but need for convergence
    real<lower=-3, upper=0> gamma; // assumptions: doubling -> >12.5% of impact
    real<lower=0> epsilon;
}
model {
    y ~ normal((beta1 * DavgT + beta2 * DavgT2) .* exp(gamma * logGDPpc), epsilon);
}"
        }
    }

    if (!include.beta2prior)
        stan.model <- gsub("real<lower=0, upper=.05> beta2; // strong assumption, but need for convergence", "real beta2;", stan.model)

    inc <- !is.na(yys)
    stan.data <- list(I = sum(inc), T = XXs[inc, 1], T2 = XXs[inc, 2], DavgT = XXs[inc, 3], DavgT2 = XXs[inc, 4], logGDPpc = XXs[inc, 5] - min(XXs[, 5]), y = yys[inc])

    fit <- stan(model_code=stan.model, data=stan.data, iter = 1000, chains = 10)

    la <- extract(fit, permute=T)

    ## Plot the parameters

    if (include.climadapt) {
        if (include.intercept) {
            plot <- ggplot(data.frame(x=c(la$alpha, la$beta1, la$beta2, la$adapt, la$gamma, la$epsilon),
                                      group=rep(c("alpha", "beta1", "beta2", "adapt", "gamma", "sigma"), each=length(la$alpha))),
                           aes(x)) +
                facet_wrap( ~ group, scales="free") + geom_density() + xlab("") + ylab("Density") + theme_bw()
        } else {
            plot <- ggplot(data.frame(x=c(la$beta1, la$beta2, la$adapt, la$gamma, la$epsilon),
                                      group=rep(c("beta1", "beta2", "adapt", "gamma", "sigma"), each=length(la$beta1))),
                           aes(x)) +
                facet_wrap( ~ group, scales="free") + geom_density() + xlab("") + ylab("Density") + theme_bw()
        }
    } else {
        if (include.intercept) {
            plot <- ggplot(data.frame(x=c(la$alpha, la$beta1, la$beta2, la$gamma, la$epsilon),
                                      group=rep(c("alpha", "beta1", "beta2", "gamma", "sigma"), each=length(la$alpha))),
                           aes(x)) +
                facet_wrap( ~ group, scales="free") + geom_density() + xlab("") + ylab("Density") + theme_bw()
        } else {
            plot <- ggplot(data.frame(x=c(la$beta1, la$beta2, la$gamma, la$epsilon),
                                      group=rep(c("beta1", "beta2", "gamma", "sigma"), each=length(la$beta1))),
                           aes(x)) +
                facet_wrap( ~ group, scales="free") + geom_density() + xlab("") + ylab("Density") + theme_bw()
        }
    }
    ggsave(paste0("graphs/", prefix, "-params.pdf"), width=8, height=6)

    ## Check that the least-squares optimum isn't far off

    if (include.climadapt) {
        objective <- function(params) {
            alpha <- params[1]
            beta1 <- params[2]
            beta2 <- params[3]
            adapt <- params[4]
            gamma <- params[5]

            if (adapt < 0)
                return(Inf)

            yypreds <- alpha + (beta1 * (XXs[, 1] - adapt * XXs[, 3]) + beta2 * (XXs[, 2] - adapt * XXs[, 4])) * exp(gamma * (XXs[, 5] - min(XXs[, 5])))
            sum((yys - yypreds)^2, na.rm=T)
        }

        if (include.intercept)
            params <- c(mean(la$alpha), mean(la$beta1), mean(la$beta2), mean(la$adapt), mean(la$gamma))
        else {
            params <- c(0, mean(la$beta1), mean(la$beta2), mean(la$adapt), mean(la$gamma))
            la$alpha <- rep(0, length(la$beta2))
        }
    } else {
        objective <- function(params) {
            alpha <- params[1]
            beta1 <- params[2]
            beta2 <- params[3]
            gamma <- params[4]

            yypreds <- alpha + (beta1 * XXs[, 3] + beta2 * XXs[, 4]) * exp(gamma * (XXs[, 5] - min(XXs[, 5])))
            sum((yys - yypreds)^2, na.rm=T)
        }

        if (include.intercept)
            params <- c(mean(la$alpha), mean(la$beta1), mean(la$beta2), mean(la$gamma))
        else {
            params <- c(0, mean(la$beta1), mean(la$beta2), mean(la$gamma))
            la$alpha <- rep(0, length(la$beta2))
        }
    }

    1 - objective(params) / objective(c(mean(yys, na.rm=T), rep(0, 4)))

    if (include.climadapt) {
        ## Report the damage function now under weather, now under climate, and income growth

        incomes <- lgfuns[[ssp]](seq(2000, 2100, length.out=100))
        temps <- seq(0, max(XXs[, 1]), length.out=100)
        weather.baseline <- matrix(NA, length(la$beta1), length(temps))
        climate.baseline <- matrix(NA, length(la$beta1), length(temps))
        climate.income <- matrix(NA, length(la$beta1), length(temps))

        for (ii in 1:length(la$beta1)) {
            weather.baseline[ii,] <- la$alpha[ii] + (la$beta1[ii] * temps + la$beta2[ii] * temps^2)
            climate.baseline[ii,] <- la$alpha[ii] + (la$beta1[ii] * (1 - la$adapt[ii]) * temps + la$beta2[ii] * (1 - la$adapt[ii]) * temps^2)
            climate.income[ii,] <- la$alpha[ii] + (la$beta1[ii] * (1 - la$adapt[ii]) * temps + la$beta2[ii] * (1 - la$adapt[ii]) * temps^2) * exp(la$gamma[ii] * (incomes - min(XXs[, 5])))
        }

        ggaddon(ggplot(data.frame(temp=rep(temps, 3), damage=c(colMeans(weather.baseline), colMeans(climate.baseline), colMeans(climate.income)), cilo=c(apply(weather.baseline, 2, function(x) quantile(x, probs=.025)), apply(climate.baseline, 2, function(x) quantile(x, probs=.025)), apply(climate.income, 2, function(x) quantile(x, probs=.025))), cihi=c(apply(weather.baseline, 2, function(x) quantile(x, probs=.975)), apply(climate.baseline, 2, function(x) quantile(x, probs=.975)), apply(climate.income, 2, function(x) quantile(x, probs=.975))), group=rep(c('No adaptation', 'Climate adaptation', 'Climate and income adaptation'), each=length(temps))),
                       aes(temp, damage, colour=group)) +
                geom_line() + geom_ribbon(aes(ymin=cilo, ymax=cihi, fill=group), alpha=.5) +
                geom_hline(yintercept=0) + scale_x_continuous(expand=c(0, 0)) +
                theme_bw() + scale_colour_discrete(name=NULL) + scale_fill_discrete(name=NULL) +
                theme(legend.position=c(.01, .99), legend.justification=c(0, 1)))
        ggsave(paste0("graphs/", prefix, "-dmgfunc.pdf"), width=6, height=4)
    } else {
        ## Report the damage function now under climate, and income growth

        incomes <- lgfuns[[ssp]](seq(2000, 2100, length.out=100))
        temps <- seq(0, max(XXs[, 1]), length.out=100)
        climate.baseline <- matrix(NA, length(la$beta1), length(temps))
        climate.income <- matrix(NA, length(la$beta1), length(temps))

        for (ii in 1:length(la$beta1)) {
            climate.baseline[ii,] <- la$alpha[ii] + (la$beta1[ii] * temps + la$beta2[ii] * temps^2)
            climate.income[ii,] <- la$alpha[ii] + (la$beta1[ii] * temps + la$beta2[ii] * temps^2) * exp(la$gamma[ii] * (incomes - min(XXs[, 5])))
        }

        ggaddon(ggplot(data.frame(temp=rep(temps, 2), damage=c(colMeans(climate.baseline), colMeans(climate.income)), cilo=c(apply(climate.baseline, 2, function(x) quantile(x, probs=.025)), apply(climate.income, 2, function(x) quantile(x, probs=.025))), cihi=c(apply(climate.baseline, 2, function(x) quantile(x, probs=.975)), apply(climate.income, 2, function(x) quantile(x, probs=.975))), group=rep(c('Climate adaptation', 'Climate and income adaptation'), each=length(temps))),
                       aes(temp, damage, colour=group)) +
                geom_line() + geom_ribbon(aes(ymin=cilo, ymax=cihi, fill=group), alpha=.5) +
                geom_hline(yintercept=0) + scale_x_continuous(expand=c(0, 0)) +
                theme_bw() + scale_colour_discrete(name=NULL) + scale_fill_discrete(name=NULL) +
                theme(legend.position=c(.01, .99), legend.justification=c(0, 1)))
        ggsave(paste0("graphs/", prefix, "-dmgfunc.pdf"), width=6, height=4)
    }

    ## Calculate SCC

    ## Construct an impulse response function of CO2 and apply to damage function

    discountrate <- .03

    if (include.climadapt) {
        social.costs <- function(temps, avgtemps, lgfun) {
            costs <- c()
            for (tt in 2017:2316) {
                temp <- temps[tt - 1980] - baseline
                avgtemp <- avgtemps[tt - 1980] - baseline
                loggdppc <- lgfun(tt)
                costs <- c(costs, mean((la$beta1 * (temp - la$adapt * avgtemp) + la$beta2 * (temp^2 - la$adapt * avgtemp^2)) * exp(la$gamma * (loggdppc - min(XXs[, 5])))))
            }

            costs
        }
    } else {
        social.costs <- function(avgtemps, lgfun) {
            costs <- c()
            for (tt in 2017:2316) {
                avgtemp <- avgtemps[tt - 1980] - baseline
                loggdppc <- lgfun(tt)
                costs <- c(costs, mean((la$beta1 * avgtemp + la$beta2 * avgtemp^2) * exp(la$gamma * (loggdppc - min(XXs[, 5])))))
            }

            costs
        }
    }

    tempboost <- function(len) {
        (1 - exp(-(0:(len-1)) / 2.8)) * exp(-(0:(len-1)) / 400) * 9.3222e-13 / 0.96875 # Based on graphs.R
    }

    results <- data.frame(rcp=c(), ssp=c(), discountrate=c(), scc=c())

    for (rcp in c('rcp45', 'rcp85')) {
        for (ssp in paste0('SSP', 1:5)) {
            filepath <- gsub("SSP", ssp, gsub("RCP", rcp, filetemplate))
            if (!file.exists(filepath))
                next

            print(c(rcp, ssp))
            damages <- read.csv(filepath)

            temps <- c()
            for (year in 1981:2099)
                temps <- c(temps, mean(damages[damages$year == year, tascol]))
            baseline <- sum(temps[1:30] * (30:1) / sum(1:30))

            temps <- c(temps, rep(temps[length(temps)] - baseline, 300) * exp(-(0:299) / 400) + baseline)
            avgtemps <- movavg(temps, 30, 'w')

            if (include.climadapt) {
                costs1 <- social.costs(temps, avgtemps, lgfuns[[ssp]])
                costs2 <- social.costs(temps + tempboost(length(temps)), avgtemps + movavg(tempboost(length(temps)), 30, 'w'), lgfuns[[ssp]])
            } else {
                costs1 <- social.costs(avgtemps, lgfuns[[ssp]])
                costs2 <- social.costs(avgtemps + movavg(tempboost(length(temps)), 30, 'w'), lgfuns[[ssp]])
            }

            for (discountrate in seq(0, .07, by=.01)) {
                scc <- sum((costs2 - costs1) * exp(-(0:299) * discountrate)) * scc.scale
                results <- rbind(results, data.frame(rcp, ssp, discountrate, scc))
            }
        }
    }

    save(la, file=paste0("results/", prefix, "-fit.RData"))
    write.csv(results, paste0("results/", prefix, "-damagefunc-scc.csv"), row.names=F)

    print(xtable(dcast(results, rcp + ssp ~ discountrate)), include.rownames=F)
}

