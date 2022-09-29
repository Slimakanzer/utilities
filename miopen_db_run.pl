#!/usr/bin/perl

my $usage = << "ENDOFUSAGE";
Usage: $0 -p /path-to-db/db.fdb.txt -o /path-to/verification.log [options]

Env:
    MIOPEN_DRIVER_PATH - path to MIOpenDriver app (REQUIRED)

Assemble preconfigured winograd shaders.
    -p <file>       path to db fdb.txt
    -s              strict, stop on first failure (default: 0)
    -a              extra params passed to app    (default: -V 1 -i 1 -t 1)
    --skip          skip first n applicable cases (default: 0)
    -h, --help      Print help

ENDOFUSAGE

use strict;
use warnings;
use File::Copy;
use File::Basename;
use File::Compare;
use autodie qw(:all);

my $strict = 0;
my $db_path;
my $extra_params = "-V 1 -i 1 -t 1";
my $skip_first = 0;
my $app = $ENV{'MIOPEN_DRIVER_PATH'};

while (scalar @ARGV) {
    my $str = shift @ARGV;
    if ($str =~ /^-./) {
        $strict       = 1           if $str eq "-s";
        $db_path      = shift @ARGV if $str eq "-p";
        $extra_params = shift @ARGV if $str eq "-a";
        $skip_first   = shift @ARGV if $str eq "--skip";
        die $usage             if $str eq "-h" || $str eq "--help";
        next;
    }
}

my $total_count      = 0;
my $applicable_count = 0;

die "$usage\nNo input db file specified. use -p option.\n" unless defined $db_path;
die "$usage\nUnable to execute app($app): $!\n" unless -e -X $app;

open(my $handle, "<$db_path") || die "Unable to read db file($db_path): $!\n";
open(my $handle_out, ">output.log") || die "Unable to read db file(output.log): $!\n";
open(my $handle_err, ">error.log") || die "Unable to read db file(error.log): $!\n";
while (<$handle>) {
    $total_count++;

    my $applicable = 1;
    my $record = $_;
    # format: C-H-W-yxx-k-oH-oW-N-pxq-uxv-lxj-bias-layout-datatype-dir
    if ($record =~ /(\d+)-(\d+)-(\d+)-(\d+)x(\d+)-(\d+)-(\d+)-(\d+)-(\d+)-(\d+)x(\d+)-(\d+)x(\d+)-(\d+)x(\d+)-0-(\w+)-(\w+)-(\w)/) {
        my $C     = $1;
        my $H     = $2;
        my $W     = $3;
        my $fil_h = $4;
        my $fil_w = $5;
        my $K     = $6;
        my $out_h = $7;
        my $out_w = $8;
        my $N     = $9;
        my $pad_h = $10;
        my $pad_w = $11;
        my $ostride_h = $12;
        my $ostride_w = $13;
        my $dstride_h = $14;
        my $dstride_w = $15;
        my $fstride_h = 1;
        my $fstride_w = 1;
        my $layout = $16;
        my $dtype  = $17;
        my $dir    = $18;

        my $dir_val = 1;
        if ($dir eq "B") {
            $dir_val = 2;
            # reverse due to genius MIOpeners reverses tensor in different places
            ($W, $out_w) = ($out_w, $W);
            ($H, $out_h) = ($out_h, $H);
            ($C, $K) = ($K, $C);
        }
        elsif ($dir eq "W") {
            $dir_val = 4;
            # reverse due to genius MIOpeners reverses tensor in different places
            ($W, $out_w) = ($out_w, $W);
            ($H, $out_h) = ($out_h, $H);
            ($C, $K) = ($K, $C);
        }

        my $type_val = "";
        if ($dtype eq "FP16") {
            $type_val = "fp16";
        }

        my ($is_valid, $solver_type, $solver_name, $time, $workspace_sz, $msg) = check_case($C, $H, $W, $fil_h, $fil_w, $K, $out_h, $out_w, $N, $pad_h, $pad_w, $ostride_h, $ostride_w, $dstride_h, $dstride_w, $layout, $dtype, $dir);

        if ($is_valid) {
            $applicable_count++;
            next if ($applicable_count <= $skip_first);
            
            my $case_params = "conv$type_val -c $C -H $W -W $W -y $fil_h -x $fil_w -k $K -n $N -p $pad_h -q $pad_w -u $ostride_h -v $ostride_w -l $dstride_h -j $dstride_w -F $dir_val";

            my $case = "Case $applicable_count\n$case_params\n";
            print $handle_out "$case";
            print "$case";

            my $log = qx "$app $case_params $extra_params 2>&1";
            
            my $is_verified = $log =~ /Verifies\s+OK\s+on\s+(CPU|GPU)/;
            my ($id, $solution) = ($log =~ m/Solution:\s+(\d+)\/(\w+)/);
            $solution = "Unknown" unless defined $solution;

            my $result = "Solution: $solution\nVerified: $is_verified\n";

            print $handle_err "$case\n$result\n$log\n" unless $is_verified;
            print $handle_out "$result\n";
            print "$result\n";

            die "Strict exit\n" if $is_verified == 0 and $strict;
        }
    }
}
close($handle_err);
close($handle_out);
close($handle);


print "Total: $total_count, applicable: $applicable_count\n";

sub check_case {
    my ($C, $H, $W, $fil_h, $fil_w, $K, $out_h, $out_w, $N, $pad_h, $pad_w, $ostride_h, $ostride_w, $dstride_h, $dstride_w, $layout, $dtype, $dir) = (@_);
    my ($fstride_h, $fstride_w) = (1, 1);
    my $patched_time = 0.0001;
    my $solver_name  = "ConvBinWinogradUltraRxSf2x3";
    my $solver_type  = "miopenConvolutionFwdAlgoWinograd";

    if ($dir eq "B") {
        $pad_w = $fil_w * $fstride_w - $pad_w - 1;
        $pad_h = $fil_h * $fstride_h - $pad_h - 1;
        ($W, $out_w) = ($out_w, $W);
        ($H, $out_h) = ($out_h, $H);
        ($dstride_w, $ostride_w) = ($ostride_w, $dstride_w);
        ($dstride_h, $ostride_h) = ($ostride_h, $dstride_h);
        ($C, $K) = ($K, $C);
        $solver_type = "miopenConvolutionBwdDataAlgoWinograd";
    }
    elsif ($dir eq "W") {
        ($fil_w, $out_w) = ($out_w, $fil_w);
        ($fil_h, $out_h) = ($out_h, $fil_h);
        ($fstride_w, $ostride_w) = ($ostride_w, $fstride_w);
        ($fstride_h, $ostride_h) = ($ostride_h, $fstride_h);
        ($C, $N) = ($N, $C);
        $solver_type = "miopenConvolutionBwdWeightsAlgoWinograd";
    }
    elsif ($dir ne "F") {
        return (0, "", $solver_name, 0, 0, "Unknown direction: (dir: $dir)");
    }

    return (0, "", $solver_name, 0, 0, "WRW") if $dir eq "W";
    return (0, "", $solver_name, 0, 0, "Layout and data type: (layout: $layout, dtype: $dtype)") unless $layout eq "NCHW" and ($dtype eq "FP16");
    return (0, "", $solver_name, 0, 0, "Stride or dilations must be equal to 1")                 unless $fstride_w == 1 and $fstride_h == 1 and $ostride_h == 1 and $ostride_w == 1 and $dstride_h == 1 and $dstride_w == 1;

    my $o_tile_step_W  = 2;
    my $o_tile_step_H  = 2;
    my $d_tile_step_W  = 2;
    my $d_tile_step_H  = 2;
    my $ELEM_SZ        = 2;
    my $D_W_PITCH      = $ELEM_SZ * 1;
    my $O_W_PITCH      = $ELEM_SZ * 1;
    my $D_H_PITCH      = $D_W_PITCH * $W;
    my $O_H_PITCH      = $O_W_PITCH * $out_w;
    my $D_C_PITCH      = $D_H_PITCH * $H;
    my $O_K_PITCH      = $O_H_PITCH * $out_h;
    my $D_N_PITCH      = $D_C_PITCH * $C;
    my $O_N_PITCH      = $O_K_PITCH * $K;
    my $TILES_N_ROW    = ($out_w + $o_tile_step_W - 1) / $o_tile_step_W;
    my $TILES_N_COLUMN = ($out_h + $o_tile_step_H - 1) / $o_tile_step_H;

    my $D_STEP_1_PITCH = $d_tile_step_H * $D_H_PITCH - $TILES_N_ROW * $d_tile_step_W * $D_W_PITCH;
    my $O_STEP_1_PITCH = $o_tile_step_H * $O_H_PITCH - $TILES_N_ROW * $o_tile_step_W * $O_W_PITCH;
    my $D_STEP_2_PITCH = $D_N_PITCH - $TILES_N_COLUMN * $d_tile_step_H * $D_H_PITCH;
    my $O_STEP_2_PITCH = $O_N_PITCH - $TILES_N_COLUMN * $o_tile_step_H * $O_H_PITCH;

    if (!( $C <= 240
        && $K <= 16
        && $fil_h <= 3
        && $fil_w <= 3
        && $D_H_PITCH < 2**16
        && $O_H_PITCH < 2**16
        && $D_C_PITCH < 2**30
        && $O_K_PITCH < 2**30
        && $D_STEP_1_PITCH < 2**18
        && $O_STEP_1_PITCH < 2**18
        && $D_STEP_2_PITCH < 2**30
        && $O_STEP_2_PITCH < 2**30)) {
        return (0, "", $solver_name, 0, 0, "Don't fit to Winograd Ultra v1_0_14 applicability");
    }

    my $group_size   = 64;
    my $workspace_sz; 
    
    if ($D_STEP_2_PITCH >= 2**23 or $O_STEP_2_PITCH >= 2**23) {
        $workspace_sz = 4 * $N * round_up_mul(ceil($out_h, $o_tile_step_H) * ceil($out_w, $o_tile_step_W), $group_size);
    } 
    else {
        $workspace_sz = 4 * round_up_mul($N * ceil($out_h, $o_tile_step_H) * ceil($out_w, $o_tile_step_W), $group_size);
    }

    return (1, $solver_type, $solver_name, $patched_time, $workspace_sz, "None");
}

sub ceil {
    my ($v, $f) = (@_);
    return int(($v + $f - 1) / $f);
}

sub round_up_mul
{
    my ($v, $f) = (@_);
    return ceil($v, $f) * $f;
}
