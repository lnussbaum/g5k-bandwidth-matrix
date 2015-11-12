This script creates a matrix of bandwidth tests between Grid'5000 sites.
- It reserves one node on each set of nodes
- It starts nuttcp in server mode
- It sequentially performs bandwith measurements

Example output: https://api.grid5000.fr/sid/sites/nancy/public/lnussbaum/bw.html
Includes:
- the best result ever obtained for a pair of nodes
- the latest result
- all results

It can be run as a cron job:
38 * * * * cd /home/lnussbaum/bw-matrix && ./bwmatrix.rb -mr >log.$(date +\%s) 2>&1
