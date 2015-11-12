This script creates a matrix of bandwidth tests between Grid'5000 sites.
- It reserves one node on each set of nodes
- It starts nuttcp in server mode
- It sequentially performs bandwith measurements

Example output: https://api.grid5000.fr/sid/sites/nancy/public/lnussbaum/bw.html
Includes:
- the best result ever obtained for a pair of nodes
- the latest result
- all results

The bandwidth column gives the bandwidth for the whole duration of the test (21s).
The "last 10s" column gives the bandwuidth for the last 10s of the test. This should exclude the lower bw during TCP slow start.

It can be run as a cron job:
38 * * * * cd /home/lnussbaum/bw-matrix && ./bwmatrix.rb -mr >log.$(date +\%s) 2>&1
