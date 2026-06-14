#=============================================================================
# questa_cov.do -- merge all saved UCDBs and write the coverage reports.
#
# Usage (after questa_regress.do, cwd = sim/):
#   do questa_cov.do
#
# Outputs:
#   coverage/merged.ucdb
#   coverage/html/index.html   <- open in a browser, screenshot for resume
#   coverage/coverage.txt
#=============================================================================

set ucdbs [glob -nocomplain ../coverage/*.ucdb]
set ucdbs [lsearch -all -inline -not $ucdbs ../coverage/merged.ucdb]
if {[llength $ucdbs] == 0} {
  puts "No UCDB files in coverage/ -- run questa_regress.do first."
  return
}
puts "Merging [llength $ucdbs] UCDB files..."

if {[catch {
  exec vcover merge ../coverage/merged.ucdb {*}$ucdbs
  exec vcover report -html ../coverage/merged.ucdb -output ../coverage/html
  exec vcover report ../coverage/merged.ucdb -output ../coverage/coverage.txt
} err]} {
  puts "exec vcover failed ($err)."
  puts "Run these from a DOS/PowerShell window in the sim/ folder instead:"
  puts "  vcover merge ../coverage/merged.ucdb ../coverage/*.ucdb"
  puts "  vcover report -html ../coverage/merged.ucdb -output ../coverage/html"
  puts "  vcover report ../coverage/merged.ucdb -output ../coverage/coverage.txt"
} else {
  puts "=============================================================="
  puts " Merged coverage written:"
  puts "   coverage/html/index.html  (open in browser)"
  puts "   coverage/coverage.txt"
  puts "=============================================================="
}
