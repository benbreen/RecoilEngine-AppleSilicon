# Reference results

The `.bin` files are the authoritative bit-exact references the sync-test
gate compares against (one per architecture/SIMD mode). The `.txt` files
beside them are not redundant: `compare_results.py` reads them to annotate
any diverging test ID with its category and operation, so a gate failure
reports *which* libm function drifted instead of a bare index. Regenerate
both together with `streflop-float-test <prefix>` on the reference machine.
