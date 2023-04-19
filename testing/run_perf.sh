#!/bin/bash

export MIOPEN_LOG_LEVEL=5
export MIOPEN_FIND_MODE=1
export MIOPEN_DEBUG_FIND_ONLY_SOLVER="ConvBinWinogradRxSf2x3g1;ConvBinWinogradRxSf3x2"

out_dir=testexample
rm -rf $out_dir
perl cross_cases.pl winograd_perf_cases.csv  | perl unique_cases.pl | perl run_cases.pl -o $out_dir -a "/git/MIOpen/build/bin/MIOpenDriver conv"  -- - -t 1 -i 1 -V 1 -F 3
perl cross_cases.pl winograd_perf_cases.csv  | perl unique_cases.pl | perl run_cases.pl -o $out_dir -a "/git/MIOpen/build/bin/MIOpenDriver convfp16"  -- - -t 1 -i 1 -V 1 -F 3
