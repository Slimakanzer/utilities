#!/usr/bin/perl

my $usage = << "ENDOFUSAGE";
Usage: $0 -p /path-to-db/db.fdb.txt -o /path-to/db.patched.fdb.txt [options]

Assemble preconfigured winograd shaders.
    -p <file>       path to db fdb.txt
    -o <file>       path to patched db fdb.txt
    -c <file>       path to file with miopen applicable cases
    -h, --help      Print help

ENDOFUSAGE

use strict;
use warnings;
use File::Copy;
use File::Basename;
use File::Compare;
use autodie qw(:all);

my $db_path;
my $out_path;
my $cases_path;

while (scalar @ARGV) {
    my $str = shift @ARGV;
    if ($str =~ /^-./) {
        $db_path  = shift @ARGV if $str eq "-p";
        $out_path = shift @ARGV if $str eq "-o";
        $cases_path = shift @ARGV if $str eq "-c";
        die $usage             if $str eq "-h" || $str eq "--help";
        next;
    }
}

my $total_count      = 0;
my $applicable_count = 0;

die "$usage\nERROR: No input db file specified. use -p option.\n" unless defined $db_path;

open(my $handle, "<$db_path") || die "Unable to read db file($db_path): $!\n";
open(my $handle_out, ">$out_path") || die "Unable to read db file($out_path): $!\n";
open(my $handle_cases, ">$cases_path") || die "Unable to write db file($cases_path): $!\n";

print $handle_cases "-W -H -c -n -k -x -y -q -p -v -u -j -l -F\n";

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

        # MIOpen's case serialization
        my $case_serialization = "${C}x${H}x${W}x${fil_h}x${fil_w}x${K}x${out_h}x${out_w}x${N}x${layout}x${dtype}x${pad_h}x${pad_w}x${ostride_h}x${ostride_w}x${dstride_h}x${dstride_w}x1x${dir}";

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

        my $type_val = "fp16";
        if ($dtype eq "FP16") {
            $type_val = "fp16";
        }
        
        my ($is_valid, $solver_type, $solver_name, $time, $workspace_sz, $msg) = check_case($C, $H, $W, $fil_h, $fil_w, $K, $out_h, $out_w, $N, $pad_h, $pad_w, $ostride_h, $ostride_w, $dstride_h, $dstride_w, $layout, $dtype, $dir);

        if ($is_valid) {
            my $ultra_record = "$solver_type:$solver_name,$time,$workspace_sz,$solver_type,$case_serialization";

            if ($record =~ /$solver_type/) {
                $record =~ s/$solver_type:[\w\d]+,\d+.\d+,\d+,$solver_type,$case_serialization;?//;
            }
            $record =~ s/-$dir=/-$dir=$ultra_record;/;
            
            print $handle_cases "$W $H $C $N $K $fil_w $fil_h $pad_w $pad_h $ostride_w $ostride_h $dstride_w $dstride_h $dir_val\n";
            $applicable_count++;
        }
    }

    print $handle_out $record;
}
close($handle_cases);
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

    return (0, "", $solver_name, 0, 0, "Layout and data type: (layout: $layout, dtype: $dtype)") unless $layout eq "NCHW";
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
        return (0, "", $solver_name, 0, 0, "Don't fit to Winograd Ultra v1_1_3 applicability");
    }

    my $group_size   = 64;
    my $workspace_sz = 4 * $N * round_up_mul(ceil($out_h, $o_tile_step_H) * ceil($out_w, $o_tile_step_W), $group_size);

    return (1, $solver_type, $solver_name, $patched_time, $workspace_sz, "None");
}

sub ceil {
    my ($v, $f) = (@_);
    return ($v + $f - 1) / $f;
}

sub round_up_mul
{
    my ($v, $f) = (@_);
    return ceil($v, $f) * $f;
}