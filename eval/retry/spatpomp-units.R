# spatPomp 1.1.0: does vec_rmeasure() take each unit's state from the right
# place? With a measurement error close to zero, a simulated measurement is
# the state it was drawn around, so the answer can be read off the output.
library(spatPomp)
cat("spatPomp", format(packageVersion("spatPomp")), "\n")
set.seed(2)
m <- bm(U = 2, N = 2)

p <- coef(m)
p["tau"] <- 1e-9
dim(p) <- c(length(p), 1)
dimnames(p) <- list(param = names(coef(m)))

# Two units and two particles. Particle 1 has the states 10 and 20,
# particle 2 has 3000 and 4000.
x <- array(c(10, 20, 3000, 4000), dim = c(2, 2, 1))
dimnames(x) <- list(variable = c("X1", "X2"), rep = NULL)
cat("\nstates, one column per particle\n")
print(x[, , 1])

cat("\nrunit_measure(), unit 1\n")
print(runit_measure(m, x = x, unit = 1, time = 1, params = p), digits = 15)
cat("\nrunit_measure(), unit 2\n")
print(runit_measure(m, x = x, unit = 2, time = 1, params = p), digits = 15)

cat("\nvec_rmeasure(), one row per unit and one column per particle\n")
print(vec_rmeasure(m, x = x, times = 1, params = p), digits = 15)
